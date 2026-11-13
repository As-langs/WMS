package com.wms.assistant.data

import android.content.Context
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

class TaskStore(context: Context) {
    private val prefs = context.getSharedPreferences("wms_task_monitor", Context.MODE_PRIVATE)
    private val gson = Gson()
    private val listType = object : TypeToken<List<Map<String, Any?>>>() {}.type
    var records: List<TaskRecord> = loadSaved()
        private set
    var lastSync: Long = prefs.getLong("last_sync", 0L)
        private set

    private fun loadSaved(): List<TaskRecord> = runCatching {
        val rows: List<Map<String, Any?>> = gson.fromJson(prefs.getString("records", "[]"), listType)
        rows.mapIndexedNotNull { i, row -> row.toTask(i) }.sortedByDescending { it.createdAt }
    }.getOrDefault(emptyList())

    fun sync90Days(api: WmsApi) {
        val now = Date()
        val start = Calendar.getInstance().apply { time = now; add(Calendar.DAY_OF_YEAR, -90) }.time
        val fetched = mutableListOf<Map<String, Any?>>()
        var offset = 0
        while (true) {
            val page = api.fetchTasks(start, now, offset)
            fetched += page
            if (page.size < 100 || offset + page.size >= 5000) break
            offset += page.size
        }
        val filtered = fetched.filter { row ->
            val raw = row.firstValue("CreateDate", "CreateTime", "CreatedAt", "CreateDateTime")
            raw.isBlank() || (parseDate(raw)?.after(start) ?: true)
        }
        val backfillDone = prefs.getBoolean("initial_backfill_done", false)
        if (!backfillDone && filtered.isEmpty()) error("WMS 最近 90 天没有返回任务记录；未推进同步标记，下次仍会重试。")
        val merged = linkedMapOf<String, TaskRecord>()
        records.forEach { merged[it.id] = it }
        filtered.forEachIndexed { i, row -> row.toTask(i)?.let { merged[it.id] = it } }
        persist(merged.values.sortedByDescending { it.createdAt })
        lastSync = System.currentTimeMillis()
        prefs.edit().putLong("last_sync", lastSync).putBoolean("initial_backfill_done", true).apply()
    }

    fun checkNew(api: WmsApi): List<TaskRecord> {
        val since = if (lastSync > 0) Date(lastSync) else Date(System.currentTimeMillis() - 60_000)
        val fetched = mutableListOf<Map<String, Any?>>()
        var offset = 0
        while (true) {
            val page = api.fetchTasks(since, Date(), offset)
            fetched += page
            if (page.size < 100 || offset + page.size >= 5000) break
            offset += page.size
        }
        val oldIds = records.map { it.id }.toSet()
        val fresh = fetched.mapIndexedNotNull { i, row -> row.toTask(i) }.filter { task ->
            val parsed = parseDate(task.createdAt)
            parsed == null || !parsed.before(since)
        }
        val merged = linkedMapOf<String, TaskRecord>()
        records.forEach { merged[it.id] = it }
        fresh.forEach { merged[it.id] = it }
        persist(merged.values.sortedByDescending { it.createdAt })
        lastSync = System.currentTimeMillis()
        prefs.edit().putLong("last_sync", lastSync).apply()
        return fresh.filter { it.id !in oldIds }
    }

    fun queryRange(api: WmsApi, start: Date, end: Date) {
        val fetched = mutableListOf<Map<String, Any?>>()
        var offset = 0
        while (true) {
            val page = api.fetchTasks(start, end, offset, includeFutureBuffer = false)
            fetched += page
            if (page.size < 100 || offset + page.size >= 5000) break
            offset += page.size
        }
        val from = dayStart(start); val until = Calendar.getInstance().apply { time = dayStart(end); add(Calendar.DAY_OF_YEAR, 1) }.time
        val selected = fetched.filter { row -> parseDate(row.firstValue("CreateDate", "CreateTime", "CreatedAt", "CreateDateTime"))?.let { !it.before(from) && it.before(until) } == true }
        val merged = linkedMapOf<String, TaskRecord>()
        records.forEach { merged[it.id] = it }
        selected.forEachIndexed { i, row -> row.toTask(i)?.let { merged[it.id] = it } }
        persist(merged.values.sortedByDescending { it.createdAt })
    }

    fun persistDetails(recordId: String, details: List<Map<String, Any?>>) {
        val all = runCatching { gson.fromJson<Map<String, List<Map<String, Any?>>>>(prefs.getString("details", "{}"), object : TypeToken<Map<String, List<Map<String, Any?>>>>() {}.type) }.getOrNull()?.toMutableMap() ?: mutableMapOf()
        all[recordId] = details
        prefs.edit().putString("details", gson.toJson(all)).apply()
    }
    fun details(recordId: String): List<Map<String, Any?>>? = runCatching {
        val all = gson.fromJson<Map<String, List<Map<String, Any?>>>>(prefs.getString("details", "{}"), object : TypeToken<Map<String, List<Map<String, Any?>>>>() {}.type)
        all?.get(recordId)
    }.getOrNull()

    private fun persist(value: List<TaskRecord>) {
        records = value
        prefs.edit().putString("records", gson.toJson(value.map { it.raw })).apply()
    }
    private fun Map<String, Any?>.toTask(i: Int): TaskRecord? {
        fun v(vararg keys: String) = firstValue(*keys)
        val mainId = v("TaskMainId", "TaskId", "Id")
        val code = v("TaskCode", "TrayCode")
        val id = mainId.ifBlank { code.ifBlank { "row-$i" } }
        return TaskRecord(id, v("CreateDate", "CreateTime", "CreatedAt", "CreateDateTime"), code, mainId,
            v("TaskType", "TaskTypeName"), v("Status", "TaskStatus"), v("OutStation", "OutStationName"),
            v("TrayCode", "PalletCode", "ContainerCode"), v("StartLocation", "StartLoc", "FromLocation"), this)
    }
    private fun Map<String, Any?>.firstValue(vararg keys: String): String = keys.firstNotNullOfOrNull { this[it]?.toString()?.takeIf { v -> v.isNotBlank() && v != "null" } }.orEmpty()
    companion object {
        fun parseDate(s: String): Date? {
            val value = s.trim()
            if (value.startsWith("/Date(")) value.filter { it.isDigit() || it == '-' }.toLongOrNull()?.let { return Date(it) }
            val formats = listOf("yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd")
            return formats.firstNotNullOfOrNull { f -> runCatching { SimpleDateFormat(f, Locale.US).parse(value) }.getOrNull() }
        }
        private fun dayStart(d: Date) = Calendar.getInstance().apply { time = d; set(Calendar.HOUR_OF_DAY,0); set(Calendar.MINUTE,0); set(Calendar.SECOND,0); set(Calendar.MILLISECOND,0) }.time
        fun displayDate(s: String): String = parseDate(s)?.let { SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault()).format(it) } ?: s
        fun status(s: String): String = when (s.trim().lowercase()) {
            "3", "已完成", "完成", "completed", "complete", "finished", "success" -> "已完成"
            "待执行", "待开始", "pending", "waiting" -> "待执行"
            "执行中", "进行中", "运行中", "processing", "running", "inprogress", "in progress" -> "执行中"
            "已取消", "取消", "cancelled", "canceled" -> "已取消"
            "执行异常", "异常", "失败", "error", "failed", "failure" -> "执行异常"
            else -> if (s.trim().toIntOrNull() != null) "未知状态" else s.ifBlank { "状态未知" }
        }
    }
}
