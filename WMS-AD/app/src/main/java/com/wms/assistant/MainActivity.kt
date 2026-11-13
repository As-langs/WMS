package com.wms.assistant

import android.os.Bundle
import android.app.Activity
import android.widget.Toast
import android.provider.MediaStore
import android.os.Build
import android.net.Uri
import android.content.Intent
import android.content.ContentValues
import android.view.WindowManager
import android.util.Base64
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.app.DatePickerDialog
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.BackHandler
import androidx.core.view.WindowCompat
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.wms.assistant.data.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.math.BigDecimal
import java.math.RoundingMode
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.math.sin
import kotlin.math.cos

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 明确允许窗口随 Android 软键盘调整，避免输入区被 IME 覆盖。
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        setContent { WmsAppTheme { WmsApp() } }
    }
}

/**
 * WMS 助手主题：跟随 Android 系统的浅色 / 深色模式。
 * 配色参考 iOS 原版：蓝色强调色、浅色白卡片、深色黑底灰卡片。
 */
@Composable
private fun WmsAppTheme(content: @Composable () -> Unit) {
    val darkTheme = isSystemInDarkTheme()
    val view = LocalView.current
    val activity = view.context as? Activity

    // 浅色背景使用深色状态栏/导航栏图标；深色背景使用白色图标。
    // SideEffect 会在系统深浅色切换后同步更新，避免时间、信号和电池图标看不清。
    SideEffect {
        activity?.window?.let { window ->
            window.statusBarColor = if (darkTheme) android.graphics.Color.BLACK
            else android.graphics.Color.rgb(242, 242, 247)
            window.navigationBarColor = if (darkTheme) android.graphics.Color.BLACK
            else android.graphics.Color.rgb(242, 242, 247)

            val insetsController = WindowCompat.getInsetsController(window, view)
            insetsController.isAppearanceLightStatusBars = !darkTheme
            insetsController.isAppearanceLightNavigationBars = !darkTheme
        }
    }

    val colors = if (darkTheme) {
        darkColorScheme(
            primary = Color(0xFF0A84FF),
            onPrimary = Color.White,
            secondary = Color(0xFF0A84FF),
            onSecondary = Color.White,
            background = Color(0xFF000000),
            onBackground = Color(0xFFF5F5F7),
            surface = Color(0xFF1C1C1E),
            onSurface = Color(0xFFF5F5F7),
            surfaceVariant = Color(0xFF2C2C2E),
            onSurfaceVariant = Color(0xFFB8B8BD),
            outline = Color(0xFF48484A)
        )
    } else {
        lightColorScheme(
            primary = Color(0xFF007AFF),
            onPrimary = Color.White,
            secondary = Color(0xFF007AFF),
            onSecondary = Color.White,
            background = Color(0xFFF2F2F7),
            onBackground = Color(0xFF1C1C1E),
            surface = Color.White,
            onSurface = Color(0xFF1C1C1E),
            surfaceVariant = Color(0xFFE5E5EA),
            onSurfaceVariant = Color(0xFF6C6C70),
            outline = Color(0xFFC6C6C8)
        )
    }

    MaterialTheme(
        colorScheme = colors,
        content = content
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WmsApp() {
    val context = LocalContext.current
    val keyboardController = LocalSoftwareKeyboardController.current
    val inputFocusRequester = remember { FocusRequester() }
    val api = remember { WmsApi() }
    val store = remember { TaskStore(context) }
    val prefs = remember { context.getSharedPreferences("wms_config", 0) }
    var baseUrl by remember { mutableStateOf(prefs.getString("url", "http://10.118.7.200") ?: "http://10.118.7.200") }
    var username by remember { mutableStateOf(prefs.getString("username", "") ?: "") }
    var password by remember {
        mutableStateOf(
            SecureConfig.decrypt(
                prefs.getString("password_cipher", null),
                prefs.getString("password_iv", null)
            ).orEmpty()
        )
    }
    var pdaId by remember { mutableStateOf(prefs.getString("pda", "491786087098744832") ?: "491786087098744832") }
    var warehouse by remember { mutableStateOf(prefs.getString("warehouse", "9099134087921669") ?: "9099134087921669") }
    var connected by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf("尚未连接 WMS。请输入账号密码后连接。") }
    // 首次安装进入设置；已经保存过配置则默认进入助手主页。
    var tab by remember { mutableIntStateOf(if (prefs.getBoolean("configured", false)) 0 else 2) }
    var input by remember { mutableStateOf("") }
    var chat by remember { mutableStateOf(listOf(
        "助手：你好，我是 WMS 智能助手。你可以直接输入物料名称和出库重量，例如：氯化钠500kg，乳清粉20包。",
        "助手：我会按输入顺序逐个处理物料。请选择正确的物料后，再点击确认；重量对应的包数按物料规格向上取整，实际出库重量保持不变。"
    )) }
    var outboundRequirements by remember { mutableStateOf<List<ParsedMaterialRequest>>(emptyList()) }
    var outboundIndex by remember { mutableIntStateOf(0) }
    var materialCandidates by remember { mutableStateOf<List<MaterialItem>>(emptyList()) }
    var awaitingMaterialChoice by remember { mutableStateOf(false) }
    var awaitingOutboundConfirmation by remember { mutableStateOf(false) }
    var currentOutboundDraft by remember { mutableStateOf<OutboundDraft?>(null) }
    var completedOutboundSummaries by remember { mutableStateOf<List<String>>(emptyList()) }
    var outboundWorkflowBlocked by remember { mutableStateOf(false) }

    // PDA 托盘任务与实际出库数量：默认不勾选，必须由操作员明确选择。
    var activePdaTray by remember { mutableStateOf("") }
    var pdaTasks by remember { mutableStateOf<List<PdaTask>>(emptyList()) }
    var selectedPdaTaskIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var pdaActualQuantityInputs by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var showPdaOutboundConfirm by remember { mutableStateOf(false) }
    var pdaOutboundWriteBlocked by remember { mutableStateOf(false) }
    var tasks by remember { mutableStateOf(store.records) }
    var taskSearch by remember { mutableStateOf("") }
    var taskType by remember { mutableStateOf("全部") }
    var details by remember { mutableStateOf<Map<String, List<Map<String, Any?>>>>(emptyMap()) }
    var expanded by remember { mutableStateOf("") }
    var dateStart by remember { mutableStateOf(Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -6) }.time) }
    var dateEnd by remember { mutableStateOf(Date()) }
    var selectedDatePreset by remember { mutableStateOf("最近7天") }
    val scope = rememberCoroutineScope()
    val chatListState = rememberLazyListState()

    // 从任务记录或设置页按系统返回键，始终回到助手主页。
    BackHandler(enabled = tab != 0) {
        tab = 0
    }

    fun configure() { api.configure(WmsConfig(baseUrl, username, password, pdaId, warehouse)) }
    fun append(line: String) { chat = chat + line }

    fun startOfDay(value: Date): Date = Calendar.getInstance().apply {
        time = value
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }.time

    fun loadDateRange(start: Date, end: Date, label: String) {
        val from = minOf(start, end)
        val to = maxOf(start, end)
        dateStart = from
        dateEnd = to
        selectedDatePreset = label
        if (connected && !busy) {
            scope.launch {
                busy = true
                runCatching {
                    withContext(Dispatchers.IO) { store.queryRange(api, from, to) }
                    tasks = store.records
                }.onFailure { message = "日期查询失败：${it.message}" }
                busy = false
            }
        }
    }

    fun applyDatePreset(label: String, days: Int) {
        val end = Date()
        val start = Calendar.getInstance().apply {
            time = startOfDay(end)
            add(Calendar.DAY_OF_YEAR, -(days - 1))
        }.time
        loadDateRange(start, end, label)
    }

    fun chooseCustomDateRange() {
        val initialStart = Calendar.getInstance().apply { time = dateStart }
        DatePickerDialog(
            context,
            { _, year, month, day ->
                val chosenStart = Calendar.getInstance().apply {
                    set(year, month, day, 0, 0, 0)
                    set(Calendar.MILLISECOND, 0)
                }.time
                val initialEnd = Calendar.getInstance().apply { time = dateEnd }
                DatePickerDialog(
                    context,
                    { _, endYear, endMonth, endDay ->
                        val chosenEnd = Calendar.getInstance().apply {
                            set(endYear, endMonth, endDay, 0, 0, 0)
                            set(Calendar.MILLISECOND, 0)
                        }.time
                        loadDateRange(chosenStart, chosenEnd, "自定义")
                    },
                    initialEnd.get(Calendar.YEAR),
                    initialEnd.get(Calendar.MONTH),
                    initialEnd.get(Calendar.DAY_OF_MONTH)
                ).show()
            },
            initialStart.get(Calendar.YEAR),
            initialStart.get(Calendar.MONTH),
            initialStart.get(Calendar.DAY_OF_MONTH)
        ).show()
    }

    // 已保存配置的用户下次启动时自动恢复登录；首次安装不会执行。
    LaunchedEffect(Unit) {
        val hasSavedConfig = prefs.getBoolean("configured", false)
        if (hasSavedConfig && username.isNotBlank() && password.isNotBlank()) {
            busy = true
            message = "正在使用已保存配置连接 WMS…"
            runCatching {
                configure()
                withContext(Dispatchers.IO) { api.loginAndVerify() }
                connected = true
                message = "WMS 已连接，会话验证成功。"
            }.onFailure {
                connected = false
                message = "自动连接失败：${it.message}，请检查设置后重新连接。"
                tab = 2
            }
            busy = false
        } else if (!hasSavedConfig) {
            tab = 2
        }
    }

    suspend fun syncFull() {
        if (!api.connected) return
        withContext(Dispatchers.IO) { store.sync90Days(api) }
        tasks = store.records
    }

    suspend fun searchCurrentOutboundRequirement() {
        if (outboundIndex !in outboundRequirements.indices) {
            val summary = if (completedOutboundSummaries.isEmpty()) {
                "本次没有完成出库。"
            } else {
                "本次全部处理完成：\n" + completedOutboundSummaries.mapIndexed { i, item -> "${i + 1}. $item" }.joinToString("\n")
            }
            append("助手：$summary")
            outboundRequirements = emptyList()
            outboundIndex = 0
            materialCandidates = emptyList()
            awaitingMaterialChoice = false
            awaitingOutboundConfirmation = false
            currentOutboundDraft = null
            return
        }

        val requirement = outboundRequirements[outboundIndex]
        append("助手：正在查询第 ${outboundIndex + 1}/${outboundRequirements.size} 种物料：${requirement.materialName}")
        val found = withContext(Dispatchers.IO) { api.searchMaterials(requirement.materialName) }
        if (found.isEmpty()) {
            append("助手：没有找到“${requirement.materialName}”的候选物料。本次流程暂停，请检查名称后重新输入。")
            outboundWorkflowBlocked = true
            return
        }
        materialCandidates = found.take(10)
        awaitingMaterialChoice = true
        awaitingOutboundConfirmation = false
        currentOutboundDraft = null
        append("助手：已找到 ${materialCandidates.size} 个候选物料，请点击下方正确选项。")
    }

    fun chooseOutboundMaterial(index: Int) {
        if (!awaitingMaterialChoice || index !in materialCandidates.indices) return
        val requirement = outboundRequirements.getOrNull(outboundIndex) ?: return
        val material = materialCandidates[index]
        try {
            currentOutboundDraft = makeOutboundDraft(requirement, material)
            awaitingMaterialChoice = false
            awaitingOutboundConfirmation = true
            append("助手：已选择：${material.name}。请核对下方出库信息。")
        } catch (e: Exception) {
            append("助手：重量换算失败：${e.message}")
        }
    }

    suspend fun waitForStockOutStatus(
        stockOutId: String,
        accepted: Set<Int>,
        attempts: Int
    ): Int {
        var status = withContext(Dispatchers.IO) { api.fetchStockOutStatus(stockOutId) }
        if (status in accepted) return status
        repeat(attempts) { attempt ->
            delay(2_000)
            status = withContext(Dispatchers.IO) { api.fetchStockOutStatus(stockOutId) }
            if (status in accepted) return status
        }
        return status
    }

    suspend fun executeConfirmedOutbound() {
        val draft = currentOutboundDraft ?: return
        if (!awaitingOutboundConfirmation || outboundWorkflowBlocked) return
        awaitingOutboundConfirmation = false
        busy = true
        append("助手：已确认，开始处理：${draft.material.name} ${formatDecimal(draft.weightKg)}kg。")
        try {
            // 写操作只在用户点击“确认”后执行；任何不确定结果均暂停，不自动重试。
            val created = withContext(Dispatchers.IO) { api.createStockOut() }
            val stockOutId = created.first
            val stockOutNumber = created.second
            append("助手：出库单已创建：$stockOutNumber。正在添加物料明细……")

            withContext(Dispatchers.IO) {
                api.addStockOutDetail(
                    stockOutId,
                    draft.material.id,
                    formatDecimal(draft.weightKg)
                )
            }
            append("助手：物料明细添加成功。正在核对审核状态……")

            var status = withContext(Dispatchers.IO) { api.fetchStockOutStatus(stockOutId) }
            if (status == 5) {
                append("助手：WMS 显示该单据已完成分配，无需重复分配。")
            } else {
                if (status == 1) {
                    runCatching {
                        withContext(Dispatchers.IO) { api.auditStockOut(stockOutId) }
                    }.onFailure {
                        append("助手：审核接口未确认，正在只读核对状态，不会重复提交审核。")
                    }
                    status = waitForStockOutStatus(stockOutId, setOf(2, 5), 6)
                }

                if (status == 5) {
                    append("助手：WMS 已显示单据完成分配。")
                } else if (status == 2) {
                    runCatching {
                        withContext(Dispatchers.IO) { api.allotStockOut(stockOutId) }
                    }.onFailure {
                        append("助手：分配接口未确认，正在只读核对状态，不会重复提交分配。")
                    }
                    status = waitForStockOutStatus(stockOutId, setOf(5), 5)
                    check(status == 5) {
                        "分配状态尚未确认。请到 WMS 页面核对单据，不要直接重试。"
                    }
                } else {
                    error("当前单据状态为 $status，未确认审核完成，已停止自动分配。请在 WMS 页面检查。")
                }
            }

            var summary = "${draft.material.name}（编码 ${draft.material.code}）：${formatDecimal(draft.weightKg)}kg"
            draft.packageCount?.let { summary += "，${formatDecimal(it)}${draft.packageUnit}" }
            summary += "，出库单号 $stockOutNumber"
            completedOutboundSummaries = completedOutboundSummaries + summary
            append("助手：出库操作已完成。\n\n$summary")

            currentOutboundDraft = null
            materialCandidates = emptyList()
            outboundIndex += 1
            searchCurrentOutboundRequirement()
        } catch (e: Exception) {
            outboundWorkflowBlocked = true
            currentOutboundDraft = null
            awaitingMaterialChoice = false
            awaitingOutboundConfirmation = false
            append(
                "助手：本种物料流程已暂停：${e.message}\\n\\n" +
                    "由于创建单据或写入操作可能已经发生，程序不会自动重试。请先在 WMS 页面核对单据、明细和状态，再决定后续操作。"
            )
        } finally {
            busy = false
        }
    }

    fun cancelOutboundWorkflow() {
        outboundRequirements = emptyList()
        outboundIndex = 0
        materialCandidates = emptyList()
        awaitingMaterialChoice = false
        awaitingOutboundConfirmation = false
        currentOutboundDraft = null
        completedOutboundSummaries = emptyList()
        append("助手：已取消当前流程。尚未确认的物料不会执行出库。")
    }

    fun selectedPdaTasks(): List<PdaTask> = pdaTasks.filter { it.id in selectedPdaTaskIds }

    fun pdaActualQuantity(task: PdaTask): java.math.BigDecimal? =
        pdaActualQuantityInputs[task.id]?.trim()?.toBigDecimalOrNull()

    fun pdaQuantityIsValid(task: PdaTask): Boolean {
        val quantity = pdaActualQuantity(task) ?: return false
        return quantity > java.math.BigDecimal.ZERO && quantity.stripTrailingZeros().scale() <= 0
    }

    fun openPdaOutboundConfirmation() {
        val selected = selectedPdaTasks()
        if (selected.isEmpty()) {
            append("助手：请先勾选需要出库的物料任务。")
            return
        }
        val invalid = selected.firstOrNull { !pdaQuantityIsValid(it) }
        if (invalid != null) {
            append("助手：${invalid.materialName} 的实际出库数量无效，请输入大于 0 的整数。")
            return
        }
        showPdaOutboundConfirm = true
    }

    suspend fun executePdaOutboundConfirmation() {
        if (pdaOutboundWriteBlocked || busy) return
        val tray = activePdaTray
        val selected = selectedPdaTasks()
        if (tray.isBlank() || selected.isEmpty() || selected.any { !pdaQuantityIsValid(it) }) return

        val quantities = selected.associate { task -> task.id to requireNotNull(pdaActualQuantity(task)) }
        showPdaOutboundConfirm = false
        busy = true
        append("助手：已二次确认托盘 $tray 的 ${selected.size} 条物料，正在提交实际出库数量……")
        try {
            val response = withContext(Dispatchers.IO) { api.confirmPdaOutbound(tray, quantities) }
            check(api.pdaResponseIndicatesSuccess(response)) {
                "WMS 未明确返回出库成功。请到 WMS 核对托盘和任务状态，不要重复提交。"
            }

            val summary = selected.joinToString("；") { task ->
                val actual = requireNotNull(pdaActualQuantity(task)).stripTrailingZeros().toPlainString()
                val planned = task.quantity.toBigDecimalOrNull()?.stripTrailingZeros()?.toPlainString() ?: "未知"
                val different = task.quantity.toBigDecimalOrNull()?.compareTo(actual.toBigDecimal()) != 0
                val note = if (different) "（非任务数量，计划 $planned）" else ""
                "${task.materialName}（${task.materialNo}）：实际 $actual，计划 $planned$note"
            }
            append("助手：托盘出库确认成功。$summary")

            // 写操作成功后只做一次只读刷新；刷新失败不重发写请求。
            runCatching { withContext(Dispatchers.IO) { api.queryPdaTasks(tray) } }
                .onSuccess { refreshed ->
                    pdaTasks = refreshed
                    selectedPdaTaskIds = emptySet()
                    pdaActualQuantityInputs = refreshed.associate { it.id to it.quantity }
                    if (refreshed.isEmpty()) append("助手：托盘 $tray 已无待出库任务。")
                    else append("助手：托盘任务已刷新，剩余 ${refreshed.size} 条待处理任务。")
                }
                .onFailure { refreshError ->
                    pdaTasks = emptyList()
                    selectedPdaTaskIds = emptySet()
                    pdaActualQuantityInputs = emptyMap()
                    append("助手：出库已确认成功，但任务刷新失败：${refreshError.message}。请重新查询托盘核对剩余任务。")
                }
        } catch (e: Exception) {
            // 写请求一旦发出，结果不确定时禁止在当前界面再次提交，避免重复出库。
            pdaOutboundWriteBlocked = true
            append("助手：托盘出库结果未能确认：${e.message}。请先到 WMS 核对托盘、实际数量和任务状态；不要直接重复提交。重新查询托盘后再继续。")
        } finally {
            busy = false
        }
    }

    // 每当用户或助手追加消息，自动滚动到聊天列表最新一条，避免回复留在屏幕下方。
    LaunchedEffect(chat.size) {
        if (chat.isNotEmpty()) {
            chatListState.animateScrollToItem(chat.lastIndex)
        }
    }

    // The original iOS app refreshes the latest 90 days on opening and polls for new tasks every 30 seconds while foregrounded.
    LaunchedEffect(connected) {
        if (connected) {
            runCatching { withContext(Dispatchers.IO) { store.sync90Days(api) }; tasks = store.records }
            while (true) {
                delay(30_000)
                runCatching {
                    val fresh = withContext(Dispatchers.IO) { store.checkNew(api) }
                    tasks = store.records
                    if (fresh.isNotEmpty()) message = "发现新增 ${fresh.size} 条 WMS 任务：" + fresh.take(4).joinToString("；") { "${taskTypeName(it.taskType)} · ${it.trayCode.ifBlank { "托盘未知" }}" }
                }.onFailure { message = "任务增量同步失败：${it.message}" }
            }
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            Column(
                Modifier
                    .fillMaxWidth()
                    .background(MaterialTheme.colorScheme.background)
                    .statusBarsPadding()
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(58.dp)
                        .padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    IconButton(
                        onClick = { if (tab == 0) tab = 1 else tab = 0 },
                        modifier = Modifier.size(48.dp)
                    ) {
                        if (tab == 0) {
                            IosTaskListIcon(
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(29.dp)
                            )
                        } else {
                            Text(
                                "‹",
                                color = MaterialTheme.colorScheme.primary,
                                style = MaterialTheme.typography.headlineLarge
                            )
                        }
                    }

                    Box(
                        modifier = Modifier.weight(1f),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = "WMS 智能助手",
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onBackground
                        )
                    }

                    IconButton(
                        onClick = { tab = 2 },
                        modifier = Modifier.size(48.dp)
                    ) {
                        IosSettingsIcon(
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(30.dp)
                        )
                    }
                }

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 22.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center
                ) {
                    Box(
                        modifier = Modifier
                            .size(9.dp)
                            .background(
                                if (connected) Color(0xFF30D158) else Color(0xFFFF453A),
                                CircleShape
                            )
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        text = if (connected) {
                            "WMS 已连接，会话验证成功  ·  $baseUrl"
                        } else {
                            message
                        },
                        modifier = Modifier.weight(1f, fill = false),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyMedium,
                        maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                    )
                    if (busy) {
                        Spacer(Modifier.width(9.dp))
                        CircularProgressIndicator(
                            modifier = Modifier.size(15.dp),
                            strokeWidth = 2.dp,
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                }

                HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.35f))
            }
        }
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background)
                .padding(padding)
                .imePadding()
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            when (tab) {
                0 -> {
                    LazyColumn(
                        state = chatListState,
                        modifier = Modifier.weight(1f).fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        contentPadding = PaddingValues(top = 6.dp, bottom = 12.dp)
                    ) {
                        items(chat) { line ->
                            val isUser = line.startsWith("我：")
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start
                            ) {
                                Surface(
                                    modifier = Modifier.widthIn(max = 340.dp),
                                    shape = RoundedCornerShape(22.dp),
                                    color = if (isUser) MaterialTheme.colorScheme.primary
                                    else MaterialTheme.colorScheme.surfaceVariant
                                ) {
                                    Text(
                                        text = line
                                            .removePrefix("我：")
                                            .removePrefix("助手：")
                                            // 将业务流程消息中保存的字面量 \\n 转成真正换行，避免界面显示反斜杠和 n。
                                            .replace("""\\n""", "\n").replace("""\n""", "\n"),
                                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                                        color = if (isUser) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                                        style = MaterialTheme.typography.bodyLarge
                                    )
                                }
                            }
                        }
                    }

                    if (pdaTasks.isNotEmpty()) {
                        Card(
                            modifier = Modifier.fillMaxWidth(),
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
                        ) {
                            Column(
                                Modifier.padding(14.dp),
                                verticalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Text("托盘出库确认", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                                Text("托盘号：$activePdaTray · 共 ${pdaTasks.size} 条待出库任务", color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text(
                                    "勾选需要出库的物料，并填写实际数量。实际数量可以与任务计划数量不同。",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )

                                pdaTasks.forEach { task ->
                                    val selected = task.id in selectedPdaTaskIds
                                    val actualText = pdaActualQuantityInputs[task.id] ?: task.quantity
                                    val planned = task.quantity.toBigDecimalOrNull()
                                    val actual = actualText.trim().toBigDecimalOrNull()
                                    val isDifferent = actual != null && planned != null && actual.compareTo(planned) != 0

                                    Card(
                                        colors = CardDefaults.cardColors(
                                            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
                                        )
                                    ) {
                                        Column(
                                            Modifier.fillMaxWidth().padding(12.dp),
                                            verticalArrangement = Arrangement.spacedBy(7.dp)
                                        ) {
                                            Row(verticalAlignment = Alignment.CenterVertically) {
                                                Checkbox(
                                                    checked = selected,
                                                    onCheckedChange = { checked ->
                                                        selectedPdaTaskIds = if (checked) {
                                                            selectedPdaTaskIds + task.id
                                                        } else {
                                                            selectedPdaTaskIds - task.id
                                                        }
                                                    }
                                                )
                                                Column(Modifier.weight(1f)) {
                                                    Text(task.materialName, fontWeight = FontWeight.SemiBold)
                                                    Text(
                                                        "编码：${task.materialNo} · 规格：${task.specification}",
                                                        style = MaterialTheme.typography.bodySmall,
                                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                                    )
                                                }
                                            }
                                            Text("任务计划数量：${task.quantity}", style = MaterialTheme.typography.bodyMedium)
                                            OutlinedTextField(
                                                value = actualText,
                                                onValueChange = { value ->
                                                    // 仅允许数字输入；最终仍在提交前校验正整数。
                                                    if (value.isEmpty() || value.matches(Regex("^\\d*$"))) {
                                                        pdaActualQuantityInputs = pdaActualQuantityInputs + (task.id to value)
                                                    }
                                                },
                                                modifier = Modifier.fillMaxWidth(),
                                                label = { Text("实际出库数量") },
                                                suffix = { Text("数量") },
                                                singleLine = true,
                                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                                isError = selected && !pdaQuantityIsValid(task)
                                            )
                                            if (isDifferent) {
                                                Text(
                                                    "非任务数量：实际数量与计划数量不一致，请重点核对。",
                                                    color = MaterialTheme.colorScheme.error,
                                                    style = MaterialTheme.typography.bodySmall,
                                                    fontWeight = FontWeight.Medium
                                                )
                                            }
                                            Text("任务状态：${task.status}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        }
                                    }
                                }

                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    OutlinedButton(
                                        onClick = {
                                            selectedPdaTaskIds = if (selectedPdaTaskIds.size == pdaTasks.size) emptySet()
                                            else pdaTasks.map { it.id }.toSet()
                                        },
                                        modifier = Modifier.weight(1f)
                                    ) {
                                        Text(if (selectedPdaTaskIds.size == pdaTasks.size) "取消全选" else "全选任务")
                                    }
                                    Button(
                                        onClick = { openPdaOutboundConfirmation() },
                                        enabled = selectedPdaTaskIds.isNotEmpty() &&
                                            selectedPdaTasks().all { pdaQuantityIsValid(it) } &&
                                            !busy && !pdaOutboundWriteBlocked,
                                        modifier = Modifier.weight(1f)
                                    ) {
                                        Text("核对并确认出库")
                                    }
                                }
                                if (pdaOutboundWriteBlocked) {
                                    Text(
                                        "上次提交结果尚未确认。请先在 WMS 核对，不要重复提交；重新查询托盘后再操作。",
                                        color = MaterialTheme.colorScheme.error,
                                        style = MaterialTheme.typography.bodySmall
                                    )
                                }
                            }
                        }
                    }

                    if (awaitingMaterialChoice && materialCandidates.isNotEmpty()) {
                        Card(
                            modifier = Modifier.fillMaxWidth(),
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
                        ) {
                            Column(
                                Modifier.padding(14.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Text("请选择正确的物料", style = MaterialTheme.typography.titleMedium)
                                Text(
                                    "需求：${outboundRequirements.getOrNull(outboundIndex)?.let { "${it.materialName} ${it.quantity}${it.unit}" }.orEmpty()}",
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    style = MaterialTheme.typography.bodySmall
                                )
                                materialCandidates.forEachIndexed { index, material ->
                                    OutlinedButton(
                                        onClick = { chooseOutboundMaterial(index) },
                                        modifier = Modifier.fillMaxWidth(),
                                        shape = RoundedCornerShape(14.dp)
                                    ) {
                                        Column(
                                            Modifier.fillMaxWidth(),
                                            verticalArrangement = Arrangement.spacedBy(3.dp)
                                        ) {
                                            Text("${index + 1}. ${material.name}", fontWeight = FontWeight.SemiBold)
                                            Text(
                                                "编码：${material.code}  ·  规格：${material.specification}  ·  单位：${material.unit}",
                                                style = MaterialTheme.typography.bodySmall
                                            )
                                        }
                                    }
                                }
                                TextButton(
                                    onClick = { cancelOutboundWorkflow() },
                                    modifier = Modifier.fillMaxWidth()
                                ) { Text("取消本次处理", color = MaterialTheme.colorScheme.error) }
                            }
                        }
                    }

                    if (awaitingOutboundConfirmation && currentOutboundDraft != null) {
                        val draft = currentOutboundDraft!!
                        Card(
                            modifier = Modifier.fillMaxWidth(),
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
                        ) {
                            Column(
                                Modifier.padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(7.dp)
                            ) {
                                Text("请确认出库信息", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                                Text(draft.material.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                                Text("编码：${draft.material.code}")
                                Text("规格：${draft.material.specification}")
                                Text("单位：${draft.material.unit}")
                                Text("实际出库重量：${formatDecimal(draft.weightKg)} kg")
                                draft.packageCount?.let {
                                    Text("计算包数：${formatDecimal(it)} ${draft.packageUnit}")
                                }
                                Button(
                                    onClick = { scope.launch { executeConfirmedOutbound() } },
                                    enabled = !busy,
                                    modifier = Modifier.fillMaxWidth(),
                                    shape = RoundedCornerShape(14.dp)
                                ) {
                                    if (busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                                    else Text("确认")
                                }
                                TextButton(
                                    onClick = { cancelOutboundWorkflow() },
                                    enabled = !busy,
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Text("取消本次处理", color = MaterialTheme.colorScheme.error)
                                }
                            }
                        }
                    }

                    if (showPdaOutboundConfirm) {
                        val selected = selectedPdaTasks()
                        AlertDialog(
                            onDismissRequest = { if (!busy) showPdaOutboundConfirm = false },
                            title = { Text("请再次确认托盘出库") },
                            text = {
                                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text("托盘：$activePdaTray")
                                    selected.forEach { task ->
                                        val actual = pdaActualQuantity(task)?.stripTrailingZeros()?.toPlainString() ?: "无效"
                                        Text("${task.materialName}：计划 ${task.quantity}，实际 $actual")
                                    }
                                    Text(
                                        "实际数量与计划数量不一致时，将按实际数量提交。确认后会直接调用 WMS 出库确认接口。",
                                        color = MaterialTheme.colorScheme.error
                                    )
                                }
                            },
                            confirmButton = {
                                TextButton(
                                    onClick = { scope.launch { executePdaOutboundConfirmation() } },
                                    enabled = !busy
                                ) { Text("确认出库") }
                            },
                            dismissButton = {
                                TextButton(onClick = { showPdaOutboundConfirm = false }, enabled = !busy) {
                                    Text("返回修改")
                                }
                            }
                        )
                    }

                    // iOS 风格底部输入栏：输入框与圆形发送按钮同一行，固定在聊天列表下方。
                    HorizontalDivider(
                        color = MaterialTheme.colorScheme.outline.copy(alpha = 0.28f)
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .navigationBarsPadding()
                            .padding(start = 2.dp, end = 2.dp, top = 10.dp, bottom = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        OutlinedTextField(
                            value = input,
                            onValueChange = { input = it },
                            modifier = Modifier
                                .weight(1f)
                                .height(56.dp)
                                .focusRequester(inputFocusRequester)
                                .onFocusChanged { focusState ->
                                    if (focusState.isFocused) {
                                        keyboardController?.show()
                                    }
                                },
                            placeholder = {
                                Text(
                                    "输入物料名称和出库重量，或托盘号 A00...",
                                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.72f),
                                    maxLines = 1
                                )
                            },
                            shape = RoundedCornerShape(28.dp),
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(
                                keyboardType = KeyboardType.Text,
                                imeAction = ImeAction.Default,
                                autoCorrect = true
                            ),
                            textStyle = MaterialTheme.typography.bodyLarge,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                                unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                                disabledContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                                focusedBorderColor = Color.Transparent,
                                unfocusedBorderColor = Color.Transparent,
                                disabledBorderColor = Color.Transparent,
                                focusedTextColor = MaterialTheme.colorScheme.onSurface,
                                unfocusedTextColor = MaterialTheme.colorScheme.onSurface
                            )
                        )

                        Button(
                            enabled = connected && !busy && input.isNotBlank(),
                            onClick = {
                                val q = input.trim()
                                input = ""
                                keyboardController?.hide()
                                append("我：$q")
                                scope.launch {
                                    if (outboundWorkflowBlocked) {
                                        if (q in setOf("已核对", "核对完成", "我已核对")) {
                                            outboundWorkflowBlocked = false
                                            cancelOutboundWorkflow()
                                            append("助手：已解除流程暂停。请重新输入下一笔需求；如上一笔已创建单据，请勿重复提交。")
                                        } else {
                                            append("助手：上一笔流程已暂停。请先到 WMS 页面核对单据、明细和状态；核对完成后回复“已核对”。不要直接重复提交。")
                                        }
                                        return@launch
                                    }
                                    // 用户明确取消：结束当前未确认流程，不执行任何出库写操作。
                                    if (q in setOf("取消", "退出", "取消本次", "取消当前订单")) {
                                        if (
                                            awaitingMaterialChoice ||
                                            awaitingOutboundConfirmation ||
                                            currentOutboundDraft != null ||
                                            outboundRequirements.isNotEmpty()
                                        ) {
                                            cancelOutboundWorkflow()
                                        } else {
                                            append("助手：当前没有待取消的物料流程。")
                                        }
                                        return@launch
                                    }

                                    // 新消息到来时，自动结束上一笔尚未确认的流程，再处理新输入。
                                    // 已进入写操作不确定状态的流程由 outboundWorkflowBlocked 单独拦截，防止重复建单。
                                    val hasUnconfirmedWorkflow =
                                        awaitingMaterialChoice ||
                                        awaitingOutboundConfirmation ||
                                        currentOutboundDraft != null ||
                                        outboundRequirements.isNotEmpty()

                                    if (hasUnconfirmedWorkflow) {
                                        outboundRequirements = emptyList()
                                        outboundIndex = 0
                                        materialCandidates = emptyList()
                                        awaitingMaterialChoice = false
                                        awaitingOutboundConfirmation = false
                                        currentOutboundDraft = null
                                        completedOutboundSummaries = emptyList()
                                        append("助手：检测到新的输入，已自动结束上一笔未确认流程；上一笔未确认物料不会执行出库。")
                                    }

                                    busy = true
                                    try {
                                        val tray = Regex("^[A-Za-z]\\d{5,}$").matches(q)
                                        if (tray) {
                                            val normalizedTray = q.uppercase(Locale.ROOT)
                                            pdaTasks = emptyList()
                                            selectedPdaTaskIds = emptySet()
                                            pdaActualQuantityInputs = emptyMap()
                                            activePdaTray = normalizedTray
                                            val result = withContext(Dispatchers.IO) {
                                                api.queryPdaTasks(normalizedTray)
                                            }
                                            activePdaTray = normalizedTray
                                            pdaTasks = result
                                            selectedPdaTaskIds = emptySet()
                                            pdaActualQuantityInputs = result.associate { it.id to it.quantity }
                                            showPdaOutboundConfirm = false
                                            // 重新查询是只读操作；核对 WMS 最新状态后才可再次人工确认。
                                            pdaOutboundWriteBlocked = false
                                            append(
                                                if (result.isEmpty()) {
                                                    "助手：托盘 $normalizedTray 没有待出库任务。"
                                                } else {
                                                    "助手：托盘 $normalizedTray 查询成功，共找到 ${result.size} 条出库任务。请在下方勾选物料并填写实际出库数量。"
                                                }
                                            )
                                        } else {
                                            pdaTasks = emptyList()
                                            selectedPdaTaskIds = emptySet()
                                            pdaActualQuantityInputs = emptyMap()
                                            showPdaOutboundConfirm = false
                                            val parsed = parseMaterialRequests(q)
                                            if (parsed != null) {
                                                outboundRequirements = parsed
                                                outboundIndex = 0
                                                completedOutboundSummaries = emptyList()
                                                append("助手：识别到 ${parsed.size} 种物料，将按输入顺序逐个处理。")
                                                searchCurrentOutboundRequirement()
                                            } else {
                                                val result = withContext(Dispatchers.IO) {
                                                    api.searchMaterials(q)
                                                }
                                                append(
                                                    if (result.isEmpty()) {
                                                        "助手：没有找到匹配物料。"
                                                    } else {
                                                        "助手：找到 ${result.size} 个候选物料：\\n" +
                                                            result.mapIndexed { i, material ->
                                                                "${i + 1}. ${material.name}\\n编码：${material.code}\\n" +
                                                                    "规格：${material.specification}\\n单位：${material.unit}"
                                                            }.joinToString("\\n\\n")
                                                    }
                                                )
                                            }
                                        }
                                    } catch (_: Exception) {
                                        // 查询失败时只向用户显示简洁提示，不暴露 JSON、HTTP、重定向等内部错误。
                                        append("助手：查询失败，请重试。")
                                    } finally {
                                        busy = false
                                    }
                                }
                            },
                            modifier = Modifier.size(54.dp),
                            shape = CircleShape,
                            contentPadding = PaddingValues(0.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = Color(0xFF0A84FF),
                                disabledContainerColor = MaterialTheme.colorScheme.surfaceVariant
                            )
                        ) {
                            Text(
                                "↑",
                                color = if (connected && !busy && input.isNotBlank()) Color.White
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.headlineMedium,
                                fontWeight = FontWeight.Normal
                            )
                        }
                    }
                }
                1 -> {
                    Row(
                        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        listOf("全部", "生产领料出库", "拣货入库", "其他任务").forEach { type ->
                            FilterChip(
                                selected = taskType == type,
                                onClick = { taskType = type },
                                label = { Text(type) }
                            )
                        }
                    }
                    Text("按日期筛选", style = MaterialTheme.typography.labelMedium)
                    Row(
                        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        listOf("今天" to 1, "最近7天" to 7, "最近30天" to 30).forEach { (label, days) ->
                            FilterChip(
                                selected = selectedDatePreset == label,
                                onClick = { applyDatePreset(label, days) },
                                label = { Text(label) }
                            )
                        }
                        FilterChip(
                            selected = selectedDatePreset == "自定义",
                            onClick = { chooseCustomDateRange() },
                            label = { Text("自定义") }
                        )
                    }
                    val rangeStart = startOfDay(dateStart)
                    val rangeEndExclusive = Calendar.getInstance().apply {
                        time = startOfDay(dateEnd)
                        add(Calendar.DAY_OF_YEAR, 1)
                    }.time
                    val dateFilteredTasks = tasks.filter { task ->
                        val created = TaskStore.parseDate(task.createdAt)
                        created != null && !created.before(rangeStart) && created.before(rangeEndExclusive)
                    }
                    val visible = dateFilteredTasks.filter { task ->
                        val typeOk = when (taskType) {
                            "生产领料出库" -> task.taskType == "13" || task.taskType == "13.0" || task.taskType.contains("生产领料出库")
                            "拣货入库" -> task.taskType == "8" || task.taskType == "8.0" || task.taskType.contains("拣货入库")
                            "其他任务" -> task.taskType !in listOf("13", "13.0", "8", "8.0") &&
                                !task.taskType.contains("生产领料出库") && !task.taskType.contains("拣货入库")
                            else -> true
                        }
                        typeOk && listOf(
                            task.taskCode, task.taskMainId, task.trayCode,
                            task.startLocation, task.status, task.taskType
                        ).any { it.contains(taskSearch, true) }
                    }
                    Text(
                        "本地历史 ${tasks.size} 条 · 当前显示 ${visible.size} 条 · 最近同步 " +
                            if (store.lastSync == 0L) "尚无" else SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()).format(Date(store.lastSync)),
                        style = MaterialTheme.typography.bodySmall
                    )
                    LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(visible) { task ->
                            Card(Modifier.fillMaxWidth()) {
                                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Text("${task.taskCode.ifBlank { "任务" }} · ${TaskStore.status(task.status)}", style = MaterialTheme.typography.titleSmall)
                                    Text("创建：${TaskStore.displayDate(task.createdAt)}")
                                    Text("任务主编号：${task.taskMainId} · 类型：${taskTypeName(task.taskType)}")
                                    Text("站点：${task.outStation.ifBlank { "-" }} · 托盘：${task.trayCode.ifBlank { "-" }}")
                                    Text("起始库位：${task.startLocation.ifBlank { "-" }}")
                                    TextButton(onClick = {
                                        if (expanded == task.id) expanded = "" else {
                                            expanded = task.id
                                            if (details[task.id] == null && store.details(task.id) == null && task.taskMainId.isNotBlank()) scope.launch {
                                                runCatching { withContext(Dispatchers.IO) { api.fetchTaskDetails(task.taskMainId) } }
                                                    .onSuccess { details = details + (task.id to it); store.persistDetails(task.id, it) }
                                                    .onFailure { message = "读取明细失败：${it.message}" }
                                            } else store.details(task.id)?.let { details = details + (task.id to it) }
                                        }
                                    }) { Text(if (expanded == task.id) "收起物料明细" else "查看物料明细") }
                                    if (expanded == task.id) {
                                        val rows = details[task.id] ?: store.details(task.id).orEmpty()
                                        if (rows.isEmpty()) Text("暂无明细或尚未加载")
                                        rows.forEachIndexed { i, row ->
                                            Divider()
                                            Text("明细 ${i + 1}", style = MaterialTheme.typography.labelLarge)
                                            detailDisplayEntries(row).forEach { (label, value) ->
                                                Row(
                                                    Modifier.fillMaxWidth(),
                                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                                    verticalAlignment = Alignment.Top
                                                ) {
                                                    Text(
                                                        "$label：",
                                                        modifier = Modifier.width(88.dp),
                                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                        style = MaterialTheme.typography.bodySmall
                                                    )
                                                    Text(
                                                        value,
                                                        modifier = Modifier.weight(1f),
                                                        color = MaterialTheme.colorScheme.onSurface,
                                                        style = MaterialTheme.typography.bodySmall
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Button(
                        enabled = visible.isNotEmpty() && !busy,
                        modifier = Modifier.fillMaxWidth(),
                        onClick = {
                            scope.launch {
                                busy = true
                                try {
                                    val exportRows = visible.toList()
                                    for (task in exportRows) {
                                        if (store.details(task.id) == null && task.taskMainId.isNotBlank()) {
                                            val fetched = withContext(Dispatchers.IO) {
                                                api.fetchTaskDetails(task.taskMainId)
                                            }
                                            store.persistDetails(task.id, fetched)
                                        }
                                    }

                                    val fileName = "WMS任务列表_${SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())}.xls"
                                    val xlsContent = buildExcelXml(exportRows, store)
                                    val uri = withContext(Dispatchers.IO) {
                                        saveXlsToDownloads(context, fileName, xlsContent)
                                    }

                                    // 直接打开系统分享面板，用户可保存到“文件”、发送给电脑或用 Excel/WPS 打开。
                                    val shareIntent = Intent(Intent.ACTION_SEND).apply {
                                        type = "application/vnd.ms-excel"
                                        putExtra(Intent.EXTRA_STREAM, uri)
                                        putExtra(Intent.EXTRA_SUBJECT, fileName)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                        clipData = android.content.ClipData.newUri(
                                            context.contentResolver,
                                            fileName,
                                            uri
                                        )
                                    }
                                    context.startActivity(Intent.createChooser(shareIntent, "导出 WMS 任务 XLS"))
                                    message = "XLS 已保存到下载目录：$fileName"
                                    Toast.makeText(context, "已导出到“下载/WMS助手”", Toast.LENGTH_LONG).show()
                                } catch (e: Exception) {
                                    message = "XLS 导出失败：${e.message ?: "未知错误"}"
                                    Toast.makeText(context, message, Toast.LENGTH_LONG).show()
                                } finally {
                                    busy = false
                                }
                            }
                        }
                    ) {
                        Text(if (busy) "正在导出 XLS…" else "导出任务 XLS")
                    }
                }
                else -> {
                    Text("连接设置", style = MaterialTheme.typography.titleLarge)
                    OutlinedTextField(baseUrl, { baseUrl = it }, Modifier.fillMaxWidth(), label = { Text("WMS 地址") }, singleLine = true)
                    OutlinedTextField(username, { username = it }, Modifier.fillMaxWidth(), label = { Text("用户名") }, singleLine = true)
                    OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), label = { Text("密码（仅本次运行保留）") }, visualTransformation = PasswordVisualTransformation(), singleLine = true)
                    OutlinedTextField(pdaId, { pdaId = it }, Modifier.fillMaxWidth(), label = { Text("PDA UserName") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                    OutlinedTextField(warehouse, { warehouse = it }, Modifier.fillMaxWidth(), label = { Text("WarehouseOid") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                    Button(enabled = !busy && username.isNotBlank() && password.isNotBlank(), modifier = Modifier.fillMaxWidth(), onClick = {
                        scope.launch {
                            busy = true; message = "正在连接并验证 WMS 会话…"
                            try {
                                configure()
                                withContext(Dispatchers.IO) { api.loginAndVerify() }
                                connected = true
                                val editor = prefs.edit()
                                    .putString("url", baseUrl.trim())
                                    .putString("username", username.trim())
                                    .putString("pda", pdaId.trim())
                                    .putString("warehouse", warehouse.trim())
                                    .putBoolean("configured", true)
                                if (password.isNotBlank()) {
                                    val encrypted = SecureConfig.encrypt(password)
                                    editor.putString("password_cipher", encrypted.first)
                                    editor.putString("password_iv", encrypted.second)
                                }
                                editor.apply()
                                message = "WMS 已连接，会话验证成功，配置已安全保存。"
                                tab = 0
                            } catch (e: Exception) { connected = false; message = "连接失败：${e.message}" }
                            finally { busy = false }
                        }
                    }) { Text("连接并验证") }
                    Text("配置会保存在本机；密码使用 Android Keystore 加密保存。下次打开应用将自动恢复并尝试连接。", style = MaterialTheme.typography.bodySmall)
                    Text("原版默认 WMS 地址为内网 HTTP。Android 已为此项目开启明文 HTTP 访问；请仅在可信内网使用。", style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}

/**
 * iOS 风格任务记录图标：圆角方框内三条列表线。
 */
@Composable
private fun IosTaskListIcon(
    tint: Color,
    modifier: Modifier = Modifier
) {
    Canvas(modifier = modifier) {
        val stroke = 1.8.dp.toPx()
        val left = size.width * 0.08f
        val top = size.height * 0.10f
        val width = size.width * 0.84f
        val height = size.height * 0.80f

        drawRoundRect(
            color = tint,
            topLeft = Offset(left, top),
            size = Size(width, height),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(4.dp.toPx()),
            style = Stroke(width = stroke)
        )

        for (index in 0..2) {
            val y = top + height * (0.29f + index * 0.25f)
            drawCircle(
                color = tint,
                radius = stroke * 0.85f,
                center = Offset(left + width * 0.22f, y)
            )
            drawLine(
                color = tint,
                start = Offset(left + width * 0.38f, y),
                end = Offset(left + width * 0.80f, y),
                strokeWidth = stroke,
                cap = androidx.compose.ui.graphics.StrokeCap.Round
            )
        }
    }
}

/**
 * iOS 风格设置齿轮图标，使用 Canvas 绘制，不依赖额外图标库。
 */
@Composable
private fun IosSettingsIcon(
    tint: Color,
    modifier: Modifier = Modifier
) {
    Canvas(modifier = modifier) {
        val center = Offset(size.width / 2f, size.height / 2f)
        val outerRadius = size.minDimension * 0.39f
        val innerRadius = size.minDimension * 0.17f
        val stroke = 1.8.dp.toPx()

        drawCircle(
            color = tint,
            radius = outerRadius * 0.78f,
            center = center,
            style = Stroke(width = stroke)
        )

        for (index in 0 until 8) {
            val angle = (Math.PI * 2.0 * index / 8.0) - Math.PI / 2.0
            val startRadius = outerRadius * 0.78f
            val endRadius = outerRadius
            val start = Offset(
                center.x + cos(angle).toFloat() * startRadius,
                center.y + sin(angle).toFloat() * startRadius
            )
            val end = Offset(
                center.x + cos(angle).toFloat() * endRadius,
                center.y + sin(angle).toFloat() * endRadius
            )
            drawLine(
                color = tint,
                start = start,
                end = end,
                strokeWidth = stroke * 1.5f,
                cap = androidx.compose.ui.graphics.StrokeCap.Round
            )
        }

        drawCircle(
            color = tint,
            radius = innerRadius,
            center = center,
            style = Stroke(width = stroke)
        )
    }
}

/**
 * 将 WMS 明细接口字段转换为 iOS 版使用的中文标签。
 * 已知字段按业务顺序展示；未知字段仍保留，避免静默丢失数据。
 */
private fun detailDisplayEntries(row: Map<String, Any?>): List<Pair<String, String>> {
    val fields = listOf(
        "物料编码" to listOf("MaterialNo", "MaterialCode", "MaterialCodeNo", "GoodsCode", "ItemCode"),
        "物料名称" to listOf("MaterialName", "GoodsName", "ItemName"),
        "供应商" to listOf("SupplierName", "Supplier", "VendorName"),
        "规格型号" to listOf("Specification", "Spec", "Model", "MaterialSpec"),
        "批号" to listOf("BatchNo", "Batch", "LotNo"),
        "件数" to listOf("Qty", "Quantity", "PieceQty", "Count"),
        "重量" to listOf("Weight", "TotalWeight", "NetWeight"),
        "入库日期" to listOf("InDate", "StorageDate", "StockInDate"),
        "有效日期" to listOf("ExpireDate", "ExpiryDate", "ValidDate"),
        "是否坏包" to listOf("IsBadPack", "BadPack", "IsDamaged"),
        "生产日期" to listOf("ProductionDate", "ProduceDate", "ManufactureDate", "MfgDate"),
        "质检状态" to listOf("Qualified", "QualityStatus", "QCStatus", "CheckStatus")
    )
    val usedKeys = mutableSetOf<String>()
    val output = mutableListOf<Pair<String, String>>()
    val dateKeys = setOf(
        "InDate", "StorageDate", "StockInDate", "ExpireDate", "ExpiryDate",
        "ValidDate", "ProductionDate", "ProduceDate", "ManufactureDate", "MfgDate"
    )

    for ((label, aliases) in fields) {
        val key = aliases.firstOrNull { alias ->
            row[alias] != null && row[alias].toString().isNotBlank() && row[alias].toString() != "null"
        } ?: continue
        val raw = row[key]?.toString()?.trim().orEmpty()
        if (raw.isEmpty() || raw == "null") continue

        val display = when (label) {
            "是否坏包" -> when (raw.lowercase()) {
                "0", "false", "否" -> "否"
                "1", "true", "是" -> "是"
                else -> raw
            }
            "质检状态" -> when (raw.lowercase()) {
                "1", "true", "合格", "qualified" -> "合格"
                "0", "false", "不合格", "unqualified" -> "不合格"
                else -> raw
            }
            else -> if (key in dateKeys || raw.startsWith("/Date(")) {
                TaskStore.displayDate(raw)
            } else raw
        }
        output += label to display
        usedKeys += key
    }

    val hiddenKeys = setOf(
        "TaskDetailId", "TaskMainId", "Id", "MaterialId",
        "IsDel", "CreateDate", "UpdateDate"
    )
    row.keys.sorted().forEach { key ->
        if (key in usedKeys || key in hiddenKeys) return@forEach
        val raw = row[key]?.toString()?.trim().orEmpty()
        if (raw.isEmpty() || raw == "null") return@forEach
        val display = if (raw.startsWith("/Date(")) TaskStore.displayDate(raw) else raw
        output += key to display
    }
    return output
}

/**
 * 使用 Android Keystore AES-GCM 加密保存 WMS 密码。
 * SharedPreferences 只保存密文和随机 IV，不保存明文密码。
 */
private object SecureConfig {
    private const val KEY_ALIAS = "wms_assistant_config_key"

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore"
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return generator.generateKey()
    }

    fun encrypt(value: String): Pair<String, String> {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val encodedCipher = Base64.encodeToString(encrypted, Base64.NO_WRAP)
        val encodedIv = Base64.encodeToString(cipher.iv, Base64.NO_WRAP)
        return encodedCipher to encodedIv
    }

    fun decrypt(cipherText: String?, ivText: String?): String? {
        if (cipherText.isNullOrBlank() || ivText.isNullOrBlank()) return null
        return runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val iv = Base64.decode(ivText, Base64.NO_WRAP)
            val encrypted = Base64.decode(cipherText, Base64.NO_WRAP)
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(encrypted), Charsets.UTF_8)
        }.getOrNull()
    }
}

private data class ParsedMaterialRequest(
    val materialName: String,
    val quantity: String,
    val unit: String
)

private data class OutboundDraft(
    val requirement: ParsedMaterialRequest,
    val material: MaterialItem,
    val weightKg: BigDecimal,
    val packageCount: BigDecimal?,
    val packageUnit: String
)

private fun parseMaterialRequests(input: String): List<ParsedMaterialRequest>? {
    val separator = Regex("""[，,、；;\n]+|再领|另领|再来|并领|同时领|然后|再出|另外""")
    val segments = input.split(separator).map { it.trim() }.filter { it.isNotEmpty() }
    if (segments.isEmpty()) return null

    val nameFirst = Regex(
        """^(.+?)\s*(\d+(?:\.\d+)?)\s*(公斤|千克|kg|克|g|吨|t|包|袋|桶|件|个|瓶)$""",
        RegexOption.IGNORE_CASE
    )
    val quantityFirst = Regex(
        """^(\d+(?:\.\d+)?)\s*(公斤|千克|kg|克|g|吨|t|包|袋|桶|件|个|瓶)\s*(.+)$""",
        RegexOption.IGNORE_CASE
    )
    val output = mutableListOf<ParsedMaterialRequest>()

    for (raw in segments) {
        val segment = raw.replace(
            Regex("""^(请|帮我|我要|需要|领用|领料|出库|先出|再出|另外)+\s*"""),
            ""
        ).trim()

        val parsed = nameFirst.matchEntire(segment)?.let { match ->
            ParsedMaterialRequest(
                match.groupValues[1].trim(),
                match.groupValues[2],
                match.groupValues[3].lowercase(Locale.ROOT)
            )
        } ?: quantityFirst.matchEntire(segment)?.let { match ->
            ParsedMaterialRequest(
                match.groupValues[3].trim(),
                match.groupValues[1],
                match.groupValues[2].lowercase(Locale.ROOT)
            )
        }

        if (parsed == null || parsed.materialName.isBlank()) return null
        val amount = parsed.quantity.toBigDecimalOrNull() ?: return null
        if (amount <= BigDecimal.ZERO) return null
        output += parsed
    }
    return output
}

private fun specificationWeightKg(specification: String): BigDecimal? {
    val match = Regex(
        """(\d+(?:\.\d+)?)\s*(kg|公斤|千克|克|g)""",
        RegexOption.IGNORE_CASE
    ).find(specification) ?: return null
    val value = match.groupValues[1].toBigDecimalOrNull() ?: return null
    val unit = match.groupValues[2].lowercase(Locale.ROOT)
    return if (unit == "g" || unit == "克") value.divide(BigDecimal("1000")) else value
}

private fun makeOutboundDraft(
    requirement: ParsedMaterialRequest,
    material: MaterialItem
): OutboundDraft {
    val quantity = requirement.quantity.toBigDecimalOrNull()
        ?: error("输入数量无效")
    val unit = requirement.unit.lowercase(Locale.ROOT)
    val packageUnits = setOf("包", "袋", "桶", "件", "个", "瓶")

    val weightKg = when (unit) {
        "kg", "公斤", "千克" -> quantity
        "g", "克" -> quantity.divide(BigDecimal("1000"))
        "吨", "t" -> quantity.multiply(BigDecimal("1000"))
        in packageUnits -> {
            require(material.unit.trim() == unit) {
                "输入单位“$unit”与 WMS 物料单位“${material.unit}”不一致，不能自动换算。"
            }
            val perPackage = specificationWeightKg(material.specification)
                ?: error("物料规格“${material.specification}”无法识别单包装重量。")
            require(perPackage > BigDecimal.ZERO) { "单包装重量必须大于 0。" }
            quantity.multiply(perPackage)
        }
        else -> error("暂不支持数量单位：$unit")
    }

    require(weightKg > BigDecimal.ZERO) { "出库重量必须大于 0。" }
    val packageUnit = material.unit.trim()
    val perPackage = specificationWeightKg(material.specification)
    val packageCount = if (packageUnit in packageUnits && perPackage != null && perPackage > BigDecimal.ZERO) {
        weightKg.divide(perPackage, 0, RoundingMode.CEILING)
    } else null

    return OutboundDraft(requirement, material, weightKg, packageCount, packageUnit)
}

private fun formatDecimal(value: BigDecimal): String =
    value.stripTrailingZeros().toPlainString()

private fun taskTypeName(type: String) = when (type.trim()) { "13", "13.0" -> "生产领料出库"; "8", "8.0" -> "拣货入库"; else -> type.ifBlank { "未知" } }
private fun visibleCount(tasks: List<TaskRecord>, query: String, type: String) = tasks.count { (query.isBlank() || listOf(it.taskCode,it.taskMainId,it.trayCode,it.startLocation,it.status,it.taskType).any { s -> s.contains(query,true) }) }
private fun xmlEscape(value: String): String = value
    .replace("&", "&amp;")
    .replace("<", "&lt;")
    .replace(">", "&gt;")
    .replace("\"", "&quot;")
    .replace("'", "&apos;")

private fun excelCell(value: String, style: String? = null): String {
    val styleAttr = style?.let { " ss:StyleID=\"$it\"" }.orEmpty()
    return "<Cell$styleAttr><Data ss:Type=\"String\">${xmlEscape(value)}</Data></Cell>"
}

/**
 * 生成 Excel 2003 XML 工作簿，使用 .xls 扩展名。
 * 一条任务有多条物料明细时按明细拆成多行，任务字段重复写入，便于筛选和打印。
 */
private fun buildExcelXml(records: List<TaskRecord>, store: TaskStore): String {
    val detailRows = records.associate { task ->
        task.id to (store.details(task.id) ?: emptyList())
    }

    val standardDetailLabels = listOf(
        "物料编码", "物料名称", "供应商", "规格型号", "批号", "件数", "重量",
        "入库日期", "有效日期", "是否坏包", "生产日期", "质检状态"
    )
    val extraLabels = detailRows.values.flatten()
        .flatMap { detailDisplayEntries(it).map { pair -> pair.first } }
        .filter { it !in standardDetailLabels }
        .distinct()
        .sorted()
    val detailLabels = standardDetailLabels + extraLabels

    val headers = listOf(
        "创建时间", "任务编号", "任务主编号", "任务类型", "状态",
        "出库站点", "托盘号", "起始库位"
    ) + detailLabels

    val rows = mutableListOf<String>()
    for (task in records) {
        val details = detailRows[task.id].orEmpty()
        val actualDetails: List<Map<String, Any?>> = if (details.isEmpty()) {
            listOf(emptyMap())
        } else {
            details
        }

        for (detail in actualDetails) {
            val detailValues = detailDisplayEntries(detail).toMap()
            val values = listOf(
                TaskStore.displayDate(task.createdAt),
                task.taskCode,
                task.taskMainId,
                taskTypeName(task.taskType),
                TaskStore.status(task.status),
                task.outStation,
                task.trayCode,
                task.startLocation
            ) + detailLabels.map { detailValues[it].orEmpty() }

            rows += "<Row>" + values.joinToString("") { excelCell(it) } + "</Row>"
        }
    }

    val headerRow = "<Row>" + headers.joinToString("") { excelCell(it, "Header") } + "</Row>"
    val dataRows = rows.joinToString("\n")
    return """<?xml version="1.0" encoding="UTF-8"?>
<?mso-application progid="Excel.Sheet"?>
<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"
 xmlns:o="urn:schemas-microsoft-com:office:office"
 xmlns:x="urn:schemas-microsoft-com:office:excel"
 xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
 <DocumentProperties xmlns="urn:schemas-microsoft-com:office:office">
  <Author>WMS 智能助手</Author>
  <Title>WMS 任务列表</Title>
 </DocumentProperties>
 <Styles>
  <Style ss:ID="Header">
   <Font ss:Bold="1" ss:Color="#FFFFFF"/>
   <Interior ss:Color="#2878D0" ss:Pattern="Solid"/>
   <Alignment ss:Vertical="Center" ss:WrapText="1"/>
  </Style>
  <Style ss:ID="Default">
   <Alignment ss:Vertical="Center" ss:WrapText="1"/>
  </Style>
 </Styles>
 <Worksheet ss:Name="WMS任务列表">
  <Table>
   <Column ss:Width="145"/>
   <Column ss:Width="90"/>
   <Column ss:Width="145"/>
   <Column ss:Width="110"/>
   <Column ss:Width="75"/>
   <Column ss:Width="75"/>
   <Column ss:Width="90"/>
   <Column ss:Width="110"/>
   $headerRow
   $dataRows
  </Table>
  <WorksheetOptions xmlns="urn:schemas-microsoft-com:office:excel">
   <FreezePanes/>
   <FrozenNoSplit/>
   <SplitHorizontal>1</SplitHorizontal>
   <TopRowBottomPane>1</TopRowBottomPane>
   <ProtectObjects>False</ProtectObjects>
   <ProtectScenarios>False</ProtectScenarios>
  </WorksheetOptions>
 </Worksheet>
</Workbook>"""
}

/**
 * Android 10+ 通过 MediaStore 保存到公共 Download/WMS助手 目录。
 * 返回 content URI，后续通过系统 Sharesheet 交给用户选择 Excel、WPS 或文件应用。
 */
private fun saveXlsToDownloads(
    context: android.content.Context,
    fileName: String,
    content: String
): Uri {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
        throw IllegalStateException("当前 Android 版本暂不支持自动保存到下载目录，请升级系统后再导出。")
    }

    val values = ContentValues().apply {
        put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
        put(MediaStore.MediaColumns.MIME_TYPE, "application/vnd.ms-excel")
        put(MediaStore.MediaColumns.RELATIVE_PATH, "${android.os.Environment.DIRECTORY_DOWNLOADS}/WMS助手")
        put(MediaStore.MediaColumns.IS_PENDING, 1)
    }

    val resolver = context.contentResolver
    val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        ?: throw IllegalStateException("无法在下载目录创建 XLS 文件。")

    try {
        val stream = resolver.openOutputStream(uri, "w")
            ?: throw IllegalStateException("无法打开 XLS 文件写入流。")
        stream.use { output ->
            output.write(content.toByteArray(Charsets.UTF_8))
            output.flush()
        }
        val complete = ContentValues().apply {
            put(MediaStore.MediaColumns.IS_PENDING, 0)
        }
        resolver.update(uri, complete, null, null)
        return uri
    } catch (error: Exception) {
        resolver.delete(uri, null, null)
        throw error
    }
}
