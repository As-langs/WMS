package com.wms.assistant.data

import com.google.gson.Gson
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.net.URLEncoder
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.TimeUnit

private class WmsRedirectException(
    val statusCode: Int,
    val location: String,
    val responsePreview: String
) : IllegalStateException(
    "WMS HTTP $statusCode redirect to $location; response=$responsePreview"
)

class WmsApi {
    @Volatile private var config = WmsConfig()
    @Volatile var connected: Boolean = false
        private set

    private val cookieJar = object : CookieJar {
        private val lock = Any()
        private val cookiesByHost = mutableMapOf<String, MutableList<Cookie>>()

        override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
            synchronized(lock) {
                val now = System.currentTimeMillis()
                val stored = cookiesByHost.getOrPut(url.host) { mutableListOf() }
                stored.removeAll { it.expiresAt <= now }
                cookies.forEach { incoming ->
                    stored.removeAll {
                        it.name == incoming.name &&
                            it.domain == incoming.domain &&
                            it.path == incoming.path
                    }
                    if (incoming.expiresAt > now) stored.add(incoming)
                }
            }
        }

        override fun loadForRequest(url: HttpUrl): List<Cookie> = synchronized(lock) {
            val now = System.currentTimeMillis()
            val stored = cookiesByHost[url.host] ?: return@synchronized emptyList()
            stored.removeAll { it.expiresAt <= now }
            stored.filter { it.matches(url) }.toList()
        }

        fun clearHost(host: String) {
            synchronized(lock) {
                cookiesByHost.remove(host)
            }
        }
    }
    private val client = OkHttpClient.Builder()
        .cookieJar(cookieJar)
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .build()
    private val gson = Gson()

    fun configure(value: WmsConfig) {
        val defaultPdaUserId = "491786087098744832"
        val defaultWarehouseOid = "9099134087921669"
        val pda = value.pdaUserId.trim().takeIf { it.matches(Regex("^\\d+$")) }
            ?: defaultPdaUserId
        val warehouse = value.warehouseOid.trim().takeIf { it.matches(Regex("^\\d+$")) }
            ?: defaultWarehouseOid

        // 与 iOS WMSNetworkConfiguration 保持一致：PDA ID / OID 只接受纯数字。
        config = value.copy(
            baseUrl = value.baseUrl.trim().trimEnd('/'),
            pdaUserId = pda,
            warehouseOid = warehouse
        )
    }

    private fun url(path: String): String = config.baseUrl + path
    private fun form(values: Map<String, String>): okhttp3.RequestBody = FormBody.Builder(Charsets.UTF_8).apply {
        values.toSortedMap().forEach { (k, v) -> add(k, v) }
    }.build()

    private fun execute(request: Request): String {
        client.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (response.code in 300..399) {
                throw WmsRedirectException(
                    response.code,
                    response.header("Location") ?: "无 Location",
                    body.take(300)
                )
            }
            if (!response.isSuccessful) {
                throw IllegalStateException("WMS HTTP ${response.code}: ${body.take(400)}")
            }
            return body
        }
    }

    private fun clearSessionCookies() {
        cookieJar.clearHost(url("/").toHttpUrl().host)
    }

    fun loginAndVerify() {
        connected = false
        // 重新登录前清除同主机旧 Cookie，避免旧会话与新登录混用。
        clearSessionCookies()
        execute(Request.Builder().url(url("/Login/Index")).get().header("Accept", "application/json, text/plain, */*").build())
        val json = JSONObject().put("UserName", config.username).put("Password", config.password).toString()
        execute(Request.Builder().url(url("/Login/CheckLoginAsync")).post(json.toRequestBody("application/json".toMediaType()))
            .header("Referer", url("/Login/Index")).build())
        val verify = execute(Request.Builder().url(url("/Material/Search?text=" + enc("胆碱"))).get().header("Referer", url("/StockOut")).build())
        val parsed = org.json.JSONTokener(verify).nextValue()
        val valid = parsed is org.json.JSONArray || (parsed is JSONObject && (parsed.opt("rows") is org.json.JSONArray || parsed.has("MaterialId")))
        check(valid) { "WMS 登录请求已发送，但只读会话验证未通过。" }
        connected = true
    }

    fun searchMaterials(keyword: String): List<MaterialItem> {
        val body = execute(Request.Builder().url(url("/Material/Search?text=" + enc(keyword))).get().header("Referer", url("/StockOut")).build())
        val rows = extractRows(body)
        val query = normalize(keyword)
        return rows.mapNotNull { row ->
            val name = row.str("MaterialName")
            val id = row.str("MaterialId")
            if (name.isBlank() || id.isBlank()) null else MaterialItem(id, name, row.str("MaterialNo"), row.str("Specification"), row.str("Unit"), row)
        }.sortedByDescending { score(query, normalize(it.name)) }.take(10)
    }

    fun fetchTasks(from: Date, to: Date, offset: Int = 0, includeFutureBuffer: Boolean = true): List<Map<String, Any?>> {
        val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val toDate = Calendar.getInstance().apply { time = to; add(Calendar.DAY_OF_YEAR, if (includeFutureBuffer) 2 else 1) }.time
        val payload = mapOf("limit" to "100", "offset" to offset.toString(), "sort" to "CreateDate", "order" to "desc", "search" to "",
            "datemin" to sdf.format(from), "datemax" to sdf.format(toDate), "Status" to "", "TaskType" to "")
        val body = execute(Request.Builder().url(url("/Task/List")).post(form(payload)).header("Referer", url("/Task")).build())
        return extractRows(body)
    }

    fun fetchTaskDetails(taskId: String): List<Map<String, Any?>> {
        val body = execute(Request.Builder().url(url("/Task/ListDetail")).post(form(mapOf("pid" to taskId))).header("Referer", url("/Task")).build())
        return extractRows(body)
    }

    /**
     * PDA 查询为只读请求。若 WMS 返回登录重定向，重新登录并重试一次。
     * 自动重试仅用于 GetOutTask，不用于创建、审核、分配或确认出库等写操作。
     */
    @Synchronized
    fun queryPdaTasks(tray: String): List<PdaTask> {
        val normalizedTray = tray.trim().uppercase(Locale.ROOT)
        require(Regex("^[A-Z]\\d{5,}$").matches(normalizedTray)) {
            "托盘号格式不正确，请检查后重试。"
        }

        return try {
            parsePdaTasks(executePdaTaskRequest(normalizedTray))
        } catch (first: WmsRedirectException) {
            loginAndVerify()
            try {
                parsePdaTasks(executePdaTaskRequest(normalizedTray))
            } catch (second: Exception) {
                connected = false
                throw IllegalStateException(
                    "PDA 查询重新验证登录后仍失败，请检查 PDA 用户 ID、仓库 OID 或 WMS 服务状态。",
                    second
                )
            }
        }
    }

    private fun executePdaTaskRequest(tray: String): String {
        val values = mapOf(
            "args" to "$tray,",
            "UserName" to config.pdaUserId,
            "WarehouseOid" to config.warehouseOid
        )
        val query = values.toSortedMap().entries.joinToString("&") {
            "${enc(it.key)}=${enc(it.value)}"
        }
        return execute(
            Request.Builder()
                .url(url("/api/pda/GetOutTask?$query"))
                .post(form(values))
                .header("Content-Type", "application/x-www-form-urlencoded;charset=utf-8")
                .header("Accept", "application/json, text/plain, */*")
                .build()
        )
    }

    private fun parsePdaTasks(response: String): List<PdaTask> {
        val parsed = org.json.JSONTokener(response).nextValue()
        val rows = when (parsed) {
            is org.json.JSONArray -> parsed
            is JSONObject -> parsed.optJSONArray("rows")
                ?: parsed.optJSONArray("data")
                ?: parsed.optJSONArray("Data")
            else -> null
        } ?: throw IllegalStateException("PDA 接口返回格式不符合预期。")

        return (0 until rows.length()).map { index ->
            val item = rows.getJSONObject(index)
            val detailId = item.optString("TaskDetailId").trim()
            val quantity = item.optString("Qty").trim()
            require(
                detailId.isNotBlank() &&
                    quantity.toBigDecimalOrNull()?.let { it > java.math.BigDecimal.ZERO } == true
            ) {
                "PDA 返回的任务明细缺少有效编号或计划数量。"
            }
            PdaTask(
                detailId,
                item.optString("MaterialName"),
                item.optString("MaterialNo"),
                item.optString("Specification"),
                quantity,
                item.optString("Status")
            )
        }
    }

    /**
     * PDA 托盘出库确认。actualQuantities 的 key 是 GetOutTask 返回的 TaskDetailId，
     * value 是用户输入的实际出库数量。允许与任务计划数量不同，但必须为正整数。
     * 此接口是写操作，绝不自动重试。
     */
    fun confirmPdaOutbound(
        tray: String,
        actualQuantities: Map<String, java.math.BigDecimal>
    ): String {
        val normalizedTray = tray.trim().uppercase(Locale.ROOT)
        require(Regex("^[A-Z]\\d{5,}$").matches(normalizedTray)) {
            "托盘号格式不正确，请检查后重试。"
        }
        require(actualQuantities.isNotEmpty()) { "请至少选择一条物料任务。" }

        val detailString = buildString {
            actualQuantities.toSortedMap().forEach { (detailId, quantity) ->
                val normalizedQuantity = quantity.stripTrailingZeros()
                require(detailId.matches(Regex("^\\d+$"))) {
                    "任务明细编号无效，已取消提交。"
                }
                require(quantity > java.math.BigDecimal.ZERO && normalizedQuantity.scale() <= 0) {
                    "实际出库数量必须是大于 0 的整数。"
                }
                append(detailId)
                append('|')
                append(normalizedQuantity.toPlainString())
                append(';')
            }
        }

        // 与 iOS 原版 OutTaskConfirm 参数格式一致：托盘号,明细ID|实际数量;
        val values = mapOf(
            "args" to "$normalizedTray,$detailString",
            "UserName" to config.pdaUserId,
            "WarehouseOid" to config.warehouseOid
        )
        val query = values.toSortedMap().entries.joinToString("&") {
            "${enc(it.key)}=${enc(it.value)}"
        }
        return execute(
            Request.Builder()
                .url(url("/api/pda/OutTaskConfirm?$query"))
                .post(form(values))
                .header("Content-Type", "application/x-www-form-urlencoded;charset=utf-8")
                .header("Accept", "application/json, text/plain, */*")
                .build()
        )
    }

    /** 只解析写接口响应，不发起额外请求或重试。 */
    fun pdaResponseIndicatesSuccess(response: String): Boolean {
        val trimmed = response.trim()
        if (trimmed.equals("true", ignoreCase = true) || trimmed == "1") return true
        val firstToken = trimmed.split(',', '|', ';').firstOrNull()?.trim().orEmpty()
        if (firstToken.equals("true", ignoreCase = true) || firstToken == "1") return true
        val parsed = runCatching { org.json.JSONTokener(trimmed).nextValue() }.getOrNull()
        return when (parsed) {
            is org.json.JSONArray -> {
                if (parsed.length() == 0) false else {
                    val first = parsed.opt(0).toString()
                    first.equals("true", ignoreCase = true) || first == "1"
                }
            }
            is JSONObject -> {
                val value = parsed.opt("Item1") ?: parsed.opt("success") ?: parsed.opt("Success")
                val text = value?.toString()?.lowercase(Locale.ROOT)
                value == true || text == "true" || text == "1"
            }
            is Boolean -> parsed
            is Number -> parsed.toInt() == 1
            is String -> parsed.equals("true", ignoreCase = true) || parsed == "1"
            else -> false
        }
    }

    // Mutating endpoints intentionally require an explicit confirmation in the UI before calling them.
    fun createStockOut(): Pair<String, String> {
        val before = fetchStockOutList().map { it.first }.toSet()
        val response = execute(Request.Builder().url(url("/StockOut/AddOrUpdate")).post(form(mapOf("id" to "0", "CustomerId" to "", "StockOutType" to "503753018307510272", "OrderNo" to "", "Remark" to ""))).header("Referer", url("/StockOut")).build())
        requireBusinessSuccess(response)
        repeat(5) { attempt ->
            val created = fetchStockOutList().filter { it.first !in before && it.third == "503753018307510272" }
            if (created.size == 1) return created.first().let { it.first to it.second }
            check(created.size <= 1) { "创建后出现多张候选单据，已停止后续操作。" }
            if (attempt < 4) Thread.sleep(1000)
        }
        error("创建出库单后未能唯一确认 StockOutId，已停止后续操作。")
    }

    fun addStockOutDetail(stockOutId: String, materialId: String, weightKg: String) {
        val body = execute(Request.Builder().url(url("/StockOut/AddOrUpdateD")).post(form(mapOf("id" to "0", "StockOutId" to stockOutId,
            "MaterialId" to materialId, "PlanOutWeight" to weightKg, "Batch" to "", "Remark" to ""))).header("Referer", url("/StockOut")).build())
        requireBusinessSuccess(body)
    }
    fun auditStockOut(id: String) { requireBusinessSuccess(execute(Request.Builder().url(url("/StockOut/Auditin?id=${enc(id)}")).get().header("Referer", url("/StockOut")).build())) }
    fun allotStockOut(id: String) { requireBusinessSuccess(execute(Request.Builder().url(url("/StockOut/AllotAll?id=${enc(id)}&outStation=4")).get().header("Referer", url("/StockOut")).build())) }

    /**
     * 只读读取出库单状态。状态码按 iOS 原版流程使用：
     * 1=待审核，2=审核后待分配，5=已完成分配。
     */
    fun fetchStockOutStatus(stockOutId: String): Int {
        val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val from = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -120) }.time
        val to = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, 2) }.time
        val payload = mapOf(
            "limit" to "100",
            "offset" to "0",
            "sort" to "CreateDate",
            "order" to "desc",
            "search" to "",
            "datemin" to sdf.format(from),
            "datemax" to sdf.format(to),
            "StockOutStatus" to "",
            "StockOutType" to ""
        )
        val rows = extractRows(
            execute(
                Request.Builder()
                    .url(url("/StockOut/List"))
                    .post(form(payload))
                    .header("Referer", url("/StockOut"))
                    .build()
            )
        )
        val row = rows.firstOrNull { it["StockOutId"]?.toString() == stockOutId }
            ?: error("在 WMS 出库单列表中找不到单据 $stockOutId")
        return row["StockOutStatus"]?.toString()?.toDoubleOrNull()?.toInt()
            ?: error("无法读取出库单 $stockOutId 的状态")
    }

    private fun fetchStockOutList(): List<Triple<String, String, String>> {
        val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val from = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -120) }.time
        val to = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, 2) }.time
        val payload = mapOf("limit" to "100", "offset" to "0", "sort" to "CreateDate", "order" to "desc", "search" to "", "datemin" to sdf.format(from), "datemax" to sdf.format(to), "StockOutStatus" to "", "StockOutType" to "")
        val rows = extractRows(execute(Request.Builder().url(url("/StockOut/List")).post(form(payload)).header("Referer", url("/StockOut")).build()))
        return rows.mapNotNull { r -> r["StockOutId"]?.toString()?.let { Triple(it, r.str("StockOutNo"), r.str("StockOutTypeId")) } }
    }

    private fun requireBusinessSuccess(body: String) {
        val obj = JSONObject(body)
        val success = obj.opt("Item1").toString().lowercase() in setOf("true", "1")
        check(success) { "WMS 业务操作未成功：${obj.optString("Item2", body)}" }
    }
    private fun extractRows(body: String): List<Map<String, Any?>> {
        val parsed = org.json.JSONTokener(body).nextValue()
        val arr = when (parsed) {
            is org.json.JSONArray -> parsed
            is JSONObject -> parsed.optJSONArray("rows") ?: parsed.optJSONArray("data") ?: parsed.optJSONArray("Data")
                ?: if (parsed.has("MaterialId") || parsed.has("StockOutId") || parsed.has("TaskMainId")) org.json.JSONArray().put(parsed) else null
            else -> null
        } ?: throw IllegalStateException("WMS 响应缺少 rows 数组")
        return (0 until arr.length()).map { i ->
            val item = arr.getJSONObject(i)
            item.keys().asSequence().associateWith { key -> item.opt(key)?.let { if (it == JSONObject.NULL) null else it } }
        }
    }
    private fun enc(v: String) = java.net.URLEncoder.encode(v, "UTF-8")
    private fun Map<String, Any?>.str(key: String) = this[key]?.toString()?.takeUnless { it == "null" }.orEmpty()
    private fun normalize(s: String) = s.filterNot(Char::isWhitespace).lowercase()
    private fun score(a: String, b: String): Int = when { a == b -> 1000; a.contains(b) -> 900; b.contains(a) -> 960; else -> a.toSet().intersect(b.toSet()).size * 2 }
}
