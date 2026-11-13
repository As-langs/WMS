import SwiftUI
import Security
import UIKit

// MARK: - Configuration storage
@MainActor
final class WMSConfigStore: ObservableObject {
    @Published var wmsURL: String
    @Published var username: String
    @Published var idValue: String
    @Published var oid: String
    @Published var barkURL: String
    @Published var isConfigured: Bool

    private let defaults = UserDefaults.standard
    private let passwordKey = "com.wms.stockout.wms-password"

    init() {
        wmsURL = UserDefaults.standard.string(forKey: "wms.url") ?? ""
        username = UserDefaults.standard.string(forKey: "wms.username") ?? ""
        idValue = UserDefaults.standard.string(forKey: "wms.id") ?? ""
        oid = UserDefaults.standard.string(forKey: "wms.oid") ?? ""
        barkURL = UserDefaults.standard.string(forKey: "wms.barkURL") ?? ""
        isConfigured = UserDefaults.standard.bool(forKey: "wms.isConfigured")
    }

    var password: String {
        get { KeychainPassword.read(key: passwordKey) ?? "" }
        set { KeychainPassword.save(newValue, key: passwordKey) }
    }

    func save(wmsURL: String, username: String, password: String, idValue: String, oid: String, barkURL: String) {
        self.wmsURL = wmsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.idValue = idValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.oid = oid.trimmingCharacters(in: .whitespacesAndNewlines)
        self.barkURL = barkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password

        defaults.set(self.wmsURL, forKey: "wms.url")
        defaults.set(self.username, forKey: "wms.username")
        defaults.set(self.idValue, forKey: "wms.id")
        defaults.set(self.oid, forKey: "wms.oid")
        defaults.set(self.barkURL, forKey: "wms.barkURL")
        defaults.set(true, forKey: "wms.isConfigured")
        isConfigured = true
    }
}

private enum KeychainPassword {
    static func save(_ password: String, key: String) {
        guard let data = password.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - App root
struct ContentView: View {
    @StateObject private var config: WMSConfigStore
    @StateObject private var network: WMSNetworkManager

    @MainActor
    init() {
        let store = WMSConfigStore()

        _config = StateObject(wrappedValue: store)

        let networkConfig = WMSNetworkConfiguration(
            baseURL: URL(string: store.wmsURL)
                ?? WMSNetworkConfiguration.defaultBaseURL,
            username: store.username,
            password: store.password,
            pdaUserID: store.idValue,
            warehouseOID: store.oid,
            barkURL: store.barkURL.isEmpty
                ? nil : store.barkURL
        )

        _network = StateObject(
            wrappedValue: WMSNetworkManager(
                configuration: networkConfig
            )
        )
    }

    var body: some View {
        Group {
            if config.isConfigured {
                ChatHomeView(config: config, network: network)
            } else {
                ConfigurationView(config: config, isFirstSetup: true)
            }
        }
        .tint(Color(red: 0.13, green: 0.38, blue: 0.93))
    }
}

// MARK: - First setup / settings form
struct ConfigurationView: View {
    @ObservedObject var config: WMSConfigStore
    var isFirstSetup: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var wmsURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var idValue = ""
    @State private var oid = ""
    @State private var barkURL = ""
    @State private var showValidation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.blue)
                            .frame(width: 54, height: 54)
                            .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("WMS 智能助手").font(.title3.bold())
                            Text(isFirstSetup ? "首次使用，请完成系统配置" : "修改连接与仓库配置")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("内网连接") {
                    TextField("例如 http://10.118.7.200", text: $wmsURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("登录信息") {
                    TextField("请输入账号", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("请输入密码", text: $password)
                }

                Section("仓库参数") {
                    TextField("请输入 ID", text: $idValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("请输入 OID", text: $oid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("通知") {
                    TextField("请输入 Bark URL（选填）", text: $barkURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if showValidation {
                    Section {
                        Text("请填写 WMS 内网地址、账号、密码、ID 和 OID。")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        HStack {
                            Spacer()
                            Text(isFirstSetup ? "保存并进入" : "保存设置")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(isFirstSetup ? "首次配置" : "设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: loadCurrentValues)
            .toolbar {
                if !isFirstSetup {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { dismiss() }
                    }
                }
            }
        }
    }

    private func loadCurrentValues() {
        wmsURL = config.wmsURL
        username = config.username
        password = config.password
        idValue = config.idValue
        oid = config.oid
        barkURL = config.barkURL
    }

    private func save() {
        let cleanURL = wmsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let validURL = URL(string: cleanURL)?.scheme != nil
        guard validURL,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty,
              !idValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !oid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showValidation = true
            return
        }
        config.save(wmsURL: cleanURL, username: username, password: password,
                    idValue: idValue, oid: oid, barkURL: barkURL)
        if !isFirstSetup { dismiss() }
    }
}

// MARK: - Chat UI and outbound workflow
private struct ChatMessage: Identifiable {
    enum Sender { case user, assistant }
    let id = UUID()
    let text: String
    let sender: Sender
    let time = Date()
}

private struct OutboundRequirement: Identifiable {
    let id = UUID()
    let name: String
    let quantity: Decimal
    let unit: String
}

private struct OutboundDraft {
    let requirement: OutboundRequirement
    let material: WMSMaterial
    let weightKG: Decimal
    let packageCount: Decimal?
    let packageUnit: String
    let packageWeightKG: Decimal?
}

private enum OutboundInputError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

private enum WMSOutboundParser {
    static func parse(_ text: String) throws -> [OutboundRequirement] {
        let separators = #"[，,、；;\n]+|再领|另领|再来|并领|同时领|然后|再出|另外"#
        let separatorRegex = try! NSRegularExpression(pattern: separators, options: [.caseInsensitive])
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var segments: [String] = []
        var cursor = 0
        for match in separatorRegex.matches(in: text, range: fullRange) {
            segments.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
        }
        segments.append(source.substring(from: cursor))
        var result: [OutboundRequirement] = []

        for rawSegment in segments {
            var segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { continue }
            segment = segment.replacingOccurrences(
                of: #"^(请|帮我|我要|需要|领用|领料|出库|先出|再出|另外)+\s*"#,
                with: "",
                options: .regularExpression
            )

            let patternNameFirst = #"^(.+?)\s*(\d+(?:\.\d+)?)\s*(公斤|千克|kg|克|g|吨|t|包|袋|桶|件|个|瓶)$"#
            let patternQuantityFirst = #"^(\d+(?:\.\d+)?)\s*(公斤|千克|kg|克|g|吨|t|包|袋|桶|件|个|瓶)\s*(.+)$"#
            let nameFirst = try! NSRegularExpression(pattern: patternNameFirst, options: [.caseInsensitive])
            let quantityFirst = try! NSRegularExpression(pattern: patternQuantityFirst, options: [.caseInsensitive])
            let ns = segment as NSString
            let full = NSRange(location: 0, length: ns.length)

            var name = ""
            var quantityText = ""
            var unit = ""
            if let match = nameFirst.firstMatch(in: segment, range: full), match.numberOfRanges == 4 {
                name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                quantityText = ns.substring(with: match.range(at: 2))
                unit = ns.substring(with: match.range(at: 3)).lowercased()
            } else if let match = quantityFirst.firstMatch(in: segment, range: full), match.numberOfRanges == 4 {
                quantityText = ns.substring(with: match.range(at: 1))
                unit = ns.substring(with: match.range(at: 2)).lowercased()
                name = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
            } else {
                throw OutboundInputError.invalid("无法识别“\(segment)”中的物料数量。请使用“物料名称 + 重量/包数”，例如：氯化钠500kg，乳清粉20包。")
            }

            guard let quantity = Decimal(string: quantityText, locale: Locale(identifier: "en_US_POSIX")), quantity > 0, !name.isEmpty else {
                throw OutboundInputError.invalid("“\(segment)”中的数量无效，数量必须大于 0。")
            }
            result.append(OutboundRequirement(name: name, quantity: quantity, unit: unit))
        }

        guard !result.isEmpty else {
            throw OutboundInputError.invalid("没有识别到物料需求。请例如输入：氯化钠500kg，乳清粉20包。")
        }
        return result
    }
}

private enum WMSOutboundCalculator {
    private static let packageUnits: Set<String> = ["包", "袋", "桶", "件", "个", "瓶"]

    static func specificationWeightKG(_ specification: String) -> Decimal? {
        let pattern = #"(\d+(?:\.\d+)?)\s*(kg|公斤|千克|克|g)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = specification as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: specification, range: range),
              let value = Decimal(string: ns.substring(with: match.range(at: 1)), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let unit = ns.substring(with: match.range(at: 2)).lowercased()
        if unit == "g" || unit == "克" { return value / Decimal(1000) }
        return value
    }

    static func makeDraft(requirement: OutboundRequirement, material: WMSMaterial) throws -> OutboundDraft {
        let unit = requirement.unit.lowercased()
        let quantity = requirement.quantity
        let weightKG: Decimal

        switch unit {
        case "kg", "公斤", "千克": weightKG = quantity
        case "g", "克": weightKG = quantity / Decimal(1000)
        case "吨", "t": weightKG = quantity * Decimal(1000)
        case "包", "袋", "桶", "件", "个", "瓶":
            guard material.unit.trimmingCharacters(in: .whitespacesAndNewlines) == unit else {
                throw OutboundInputError.invalid("输入单位“\(unit)”与 WMS 物料单位“\(material.unit)”不一致，不能自动换算。")
            }
            guard let perPackage = specificationWeightKG(material.specification), perPackage > 0 else {
                throw OutboundInputError.invalid("物料规格“\(material.specification)”无法识别单包装重量，不能按包数换算。")
            }
            weightKG = quantity * perPackage
        default:
            throw OutboundInputError.invalid("暂不支持数量单位：\(unit)")
        }

        guard weightKG > 0 else { throw OutboundInputError.invalid("出库重量必须大于 0。") }
        let packageUnit = material.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let perPackage = specificationWeightKG(material.specification)
        var packageCount: Decimal? = nil

        if packageUnits.contains(packageUnit), let perPackage, perPackage > 0 {
            var quotient = weightKG / perPackage
            var rounded = Decimal()
            // 正数向上取整：26kg / 25kg/包 = 2包。
            NSDecimalRound(&rounded, &quotient, 0, .up)
            packageCount = rounded
        }

        return OutboundDraft(
            requirement: requirement,
            material: material,
            weightKG: weightKG,
            packageCount: packageCount,
            packageUnit: packageUnit,
            packageWeightKG: perPackage
        )
    }

    static func format(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        return number.stringValue
    }
}

struct ChatHomeView: View {
    @ObservedObject var config: WMSConfigStore
    @ObservedObject var network: WMSNetworkManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showTaskMonitor = false
    @StateObject private var taskMonitor = WMSTaskMonitorStore()
    @State private var connectionMessage = ""
    @State private var showNewTaskBanner = false
    @State private var newTaskBannerText = ""
    @State private var input = ""
    @State private var isSending = false
    @FocusState private var isInputFocused: Bool
    @State private var messages: [ChatMessage] = [
        ChatMessage(text: "你好，我是 WMS 智能助手。你可以直接输入物料名称和出库重量，例如：氯化钠500kg，乳清粉20包。", sender: .assistant),
        ChatMessage(text: "我会按输入顺序逐个处理物料。请选择正确的物料后，再点击确认；重量对应的包数按物料规格向上取整，实际出库重量保持不变。", sender: .assistant)
    ]

    @State private var requirements: [OutboundRequirement] = []
    @State private var currentIndex = 0
    @State private var candidates: [WMSMaterial] = []
    @State private var awaitingCandidate = false
    @State private var awaitingConfirmation = false
    @State private var currentDraft: OutboundDraft?
    @State private var selectedCandidateIndex: Int?
    @State private var completedSummaries: [String] = []
    @State private var workflowBlocked = false

    // MARK: PDA 出库确认流程状态
    /// 托盘 PDA 查询结果，用于驱动出库确认面板
    @State private var pdaTray: String = ""
    @State private var pdaTasks: [WMSPdaTask] = []
    /// 用户在面板中填写的实际数量（key = TaskDetailId）
    @State private var pdaActualQty: [String: String] = [:]
    /// 是否正在展示 PDA 出库确认面板（录入阶段）
    @State private var awaitingPdaQty = false
    /// 是否正在展示 PDA 二次确认面板（提交前预览）
    @State private var awaitingPdaSubmit = false

    private var statusColor: Color {
        if network.isConnected { return .green }
        if network.isBusy { return .orange }
        return .red
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(network.connectionMessage)
            Text("·")
            Text(config.wmsURL).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if network.isBusy {
                ProgressView().controlSize(.small)
            } else if !network.isConnected {
                Button("重连") { Task { await connectToWMS() } }
                    .font(.caption.weight(.semibold))
            }
        }
        .font(.caption)
        .foregroundStyle(Color.secondary)
        .padding(.horizontal).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var conversationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(messages) { message in
                        messageBubble(message).id(message.id)
                    }

                    if awaitingCandidate {
                        candidateSelectionPanel
                            .id("candidate-selection-panel")
                    }

                    if awaitingConfirmation, let draft = currentDraft {
                        confirmationPanel(for: draft)
                            .id("outbound-confirmation-panel")
                    }

                    if awaitingPdaQty || awaitingPdaSubmit {
                        pdaConfirmationPanel
                            .id("pda-confirmation-panel")
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                isInputFocused = false
            }
            .onChange(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: awaitingCandidate) { _, isShowing in
                if isShowing {
                    withAnimation { proxy.scrollTo("candidate-selection-panel", anchor: .bottom) }
                }
            }
            .onChange(of: awaitingConfirmation) { _, isShowing in
                if isShowing {
                    withAnimation { proxy.scrollTo("outbound-confirmation-panel", anchor: .bottom) }
                }
            }
            .onChange(of: awaitingPdaQty) { _, isShowing in
                if isShowing {
                    withAnimation { proxy.scrollTo("pda-confirmation-panel", anchor: .bottom) }
                }
            }
            .onChange(of: awaitingPdaSubmit) { _, isShowing in
                if isShowing {
                    withAnimation { proxy.scrollTo("pda-confirmation-panel", anchor: .bottom) }
                }
            }
        }
    }

    private var candidateSelectionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("请选择正确的物料")
                .font(.headline)

            ForEach(Array(candidates.enumerated()), id: \.offset) { index, material in
                let isSelected = selectedCandidateIndex == index

                Button {
                    chooseCandidate(at: index)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .font(.title2)
                            .foregroundStyle(isSelected ? Color.blue : Color.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(material.materialName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)

                            Text("编码 \(displayValue(material.materialNo))  ·  规格 \(displayValue(material.specification))  ·  单位 \(displayValue(material.unit))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isSelected ? Color.blue.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isSelected ? Color.blue : Color(uiColor: .separator).opacity(0.35),
                                    lineWidth: isSelected ? 1.5 : 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 20))
    }

    private func confirmationPanel(for draft: OutboundDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("请确认出库信息")
                .font(.headline)

            VStack(alignment: .leading, spacing: 7) {
                Text(draft.material.materialName)
                    .font(.body.weight(.semibold))
                Text("编码：\(displayValue(draft.material.materialNo))")
                Text("规格：\(displayValue(draft.material.specification))")
                Text("单位：\(displayValue(draft.material.unit))")
                Text("实际出库重量：\(WMSOutboundCalculator.format(draft.weightKG)) kg")
                if let packageCount = draft.packageCount {
                    Text("计算包数：\(WMSOutboundCalculator.format(packageCount)) \(draft.packageUnit)")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Button {
                isInputFocused = false
                Task { await executeCurrentItem() }
            } label: {
                HStack {
                    Spacer()
                    if isSending {
                        ProgressView().tint(.white)
                    } else {
                        Text("确认")
                            .font(.headline.weight(.semibold))
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.vertical, 14)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isSending)

            Button("取消本次处理", role: .destructive) {
                cancelCurrentWorkflow()
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .disabled(isSending)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20))
    }

    private var pdaConfirmationPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if awaitingPdaQty {
                // 第一阶段：录入实际出库数量
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                        .font(.title3)
                        .foregroundStyle(Color.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PDA 托盘实际出库确认")
                            .font(.headline)
                        Text("真实提交会修改 WMS 库存及任务状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(pdaTray)
                        .font(.caption.monospaced().bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.blue)
                }

                Divider()

                ForEach(pdaTasks) { task in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(task.materialName)
                                .font(.body.weight(.semibold))
                            Spacer()
                            Text(task.status.isEmpty ? "状态: 待出库" : "任务状态: \(task.status)")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            GridRow {
                                Text("物料编码：").font(.caption).foregroundStyle(.secondary)
                                Text(displayValue(task.materialNo)).font(.caption.monospaced())
                            }
                            GridRow {
                                Text("规格型号：").font(.caption).foregroundStyle(.secondary)
                                Text(displayValue(task.specification)).font(.caption)
                            }
                            GridRow {
                                Text("TaskDetailId：").font(.caption).foregroundStyle(.secondary)
                                Text(task.id).font(.caption.monospaced())
                            }
                            GridRow {
                                Text("计划数量：").font(.caption).foregroundStyle(.secondary)
                                Text(WMSOutboundCalculator.format(task.plannedQuantity)).font(.caption.weight(.semibold))
                            }
                        }

                        // 机器人实际取出数量录入
                        HStack(spacing: 12) {
                            Text("实际取出数量：")
                                .font(.subheadline.weight(.medium))

                            Spacer()

                            let planInt = NSDecimalNumber(decimal: task.plannedQuantity).intValue
                            let currentVal = Int(pdaActualQty[task.id] ?? "\(planInt)") ?? planInt

                            Button {
                                if currentVal > 1 {
                                    pdaActualQty[task.id] = "\(currentVal - 1)"
                                }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(currentVal > 1 ? Color.blue : Color.secondary.opacity(0.3))
                            }
                            .buttonStyle(.plain)
                            .disabled(currentVal <= 1)

                            TextField("数量", text: Binding(
                                get: { pdaActualQty[task.id] ?? "\(planInt)" },
                                set: { pdaActualQty[task.id] = $0 }
                            ))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .frame(width: 54)
                            .padding(.vertical, 4)
                            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))

                            Button {
                                if currentVal < planInt {
                                    pdaActualQty[task.id] = "\(currentVal + 1)"
                                }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(currentVal < planInt ? Color.blue : Color.secondary.opacity(0.3))
                            }
                            .buttonStyle(.plain)
                            .disabled(currentVal >= planInt)
                        }
                        .padding(.top, 4)
                    }
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    isInputFocused = false
                    var hasError = false
                    for task in pdaTasks {
                        let planInt = NSDecimalNumber(decimal: task.plannedQuantity).intValue
                        guard let val = Int(pdaActualQty[task.id] ?? ""), val > 0, val <= planInt else {
                            hasError = true
                            break
                        }
                    }
                    if hasError {
                        messages.append(ChatMessage(text: "请确保每个物料的实际取出数量为大于 0 且不超过计划数量的整数。", sender: .assistant))
                    } else {
                        awaitingPdaQty = false
                        awaitingPdaSubmit = true
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text("下一步：真实出库预览")
                            .font(.headline.weight(.semibold))
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 14)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
                }

                Button("取消本次处理", role: .destructive) {
                    cancelPdaWorkflow()
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)

            } else if awaitingPdaSubmit {
                // 第二阶段：真实出库确认预览
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.title3)
                        .foregroundStyle(Color.orange)
                    Text("真实出库确认预览")
                        .font(.headline)
                    Spacer()
                    Text("OutTaskConfirm")
                        .font(.caption2.monospaced().bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.orange)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("托盘：").foregroundStyle(.secondary)
                        Text(pdaTray).bold()
                    }
                    HStack {
                        Text("接口：").foregroundStyle(.secondary)
                        Text("OutTaskConfirm").monospaced()
                    }
                    HStack {
                        Text("参数1：").foregroundStyle(.secondary)
                        Text(pdaTray).monospaced()
                    }

                    let detailArg = pdaTasks.map { task in
                        let qty = pdaActualQty[task.id] ?? "0"
                        return "\(task.id)|\(qty);"
                    }.joined()

                    HStack(alignment: .top) {
                        Text("参数2：").foregroundStyle(.secondary)
                        Text(detailArg).monospaced().lineLimit(2)
                    }

                    Divider().padding(.vertical, 2)

                    let totalPlan = pdaTasks.reduce(0) { $0 + (NSDecimalNumber(decimal: $1.plannedQuantity).intValue) }
                    let totalActual = pdaTasks.reduce(0) { $0 + (Int(pdaActualQty[$1.id] ?? "0") ?? 0) }

                    HStack {
                        Text("计划数量：\(totalPlan)")
                        Spacer()
                        Text("实际数量：\(totalActual)")
                        Spacer()
                        Text("剩余数量：\(totalPlan - totalActual)")
                    }
                    .font(.subheadline.bold())
                }
                .font(.subheadline)
                .padding(12)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                // 警告提示
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                    Text("警告：下一步将修改真实 WMS 库存及任务状态。程序不会调用手动回库或上架接口，写操作不会自动重试。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                Button {
                    isInputFocused = false
                    Task { await submitPdaOutbound() }
                } label: {
                    HStack {
                        Spacer()
                        if isSending {
                            ProgressView().tint(.white)
                        } else {
                            Text("确认提交 (OutTaskConfirm)")
                                .font(.headline.weight(.semibold))
                        }
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 14)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isSending)

                HStack {
                    Button("返回修改数量") {
                        awaitingPdaSubmit = false
                        awaitingPdaQty = true
                    }
                    .font(.subheadline)
                    .disabled(isSending)

                    Spacer()

                    Button("取消提交", role: .destructive) {
                        cancelPdaWorkflow()
                    }
                    .font(.subheadline)
                    .disabled(isSending)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func displayValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "-" : value
    }

    private var messageComposer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入物料名称和出库重量，或托盘号 A00778…", text: $input, axis: .vertical)
                    .focused($isInputFocused)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 22))

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.blue, in: Circle())
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .accessibilityLabel("发送消息")
            }
            .padding(.horizontal).padding(.vertical, 10)
            .background(Color(uiColor: .systemBackground))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showNewTaskBanner {
                    HStack(spacing: 12) {
                        Image(systemName: "bell.badge.fill")
                            .foregroundStyle(.blue)
                        Text(newTaskBannerText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("查看") {
                            showNewTaskBanner = false
                            showTaskMonitor = true
                        }
                        .font(.subheadline.weight(.semibold))
                        Button {
                            showNewTaskBanner = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("关闭新增任务提示")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color.blue.opacity(0.09))
                }
                statusBar
                conversationList
                messageComposer
            }
            .navigationTitle("WMS 智能助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isInputFocused = false
                        showTaskMonitor = true
                    } label: {
                        Label("任务记录", systemImage: "list.bullet.rectangle")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("任务记录")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isInputFocused = false
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .sheet(isPresented: $showSettings) {
                ConfigurationView(config: config, isFirstSetup: false)
            }
            .sheet(isPresented: $showTaskMonitor) {
                WMSTaskMonitorView(store: taskMonitor, network: network)
            }
            .onChange(of: showSettings) { _, isPresented in
                if !isPresented { Task { await connectToWMS() } }
            }
            // 仅在 App 前台运行：打开时先同步最近 90 天历史/状态，
            // 随后每 30 秒增量检查新增任务；进入后台后 SwiftUI 会取消该 task。
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await refreshTaskRecords()

                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 30_000_000_000)
                    } catch {
                        return
                    }
                    guard scenePhase == .active else { return }
                    await checkForNewTasks()
                }
            }
            .onChange(of: taskMonitor.newTaskNoticeToken) { _, _ in
                guard !taskMonitor.latestNewTaskMessage.isEmpty else { return }
                newTaskBannerText = taskMonitor.latestNewTaskMessage
                showNewTaskBanner = true
            }
            .alert("WMS 连接状态", isPresented: Binding(
                get: { !connectionMessage.isEmpty },
                set: { if !$0 { connectionMessage = "" } }
            )) {
                Button("好", role: .cancel) { connectionMessage = "" }
            } message: {
                Text(connectionMessage)
            }
        }
    }

    @MainActor
    private func refreshTaskRecords() async {
        if !network.isConnected && !network.isBusy {
            await connectToWMS()
        }
        guard network.isConnected else { return }
        // 打开软件时执行一次完整同步：补录最近 90 天，并刷新已有任务状态。
        await taskMonitor.loadUpdates(using: network)
    }

    @MainActor
    private func checkForNewTasks() async {
        if !network.isConnected && !network.isBusy {
            await connectToWMS()
        }
        guard network.isConnected else { return }
        // 前台轮询只增量检查新任务，避免每 30 秒重复拉取 90 天全部历史。
        await taskMonitor.checkForNewTasks(using: network)
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.sender == .user { Spacer(minLength: 48) }
            Text(message.text)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .foregroundStyle(message.sender == .user ? Color.white : Color.primary)
                .background(
                    message.sender == .user ? Color.blue : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18)
                )
            if message.sender == .assistant { Spacer(minLength: 48) }
        }
    }

    @MainActor
    private func connectToWMS() async {
        let result = await network.loginAndVerify(
            baseURL: config.wmsURL,
            username: config.username,
            password: config.password
        )
        if !result.success {
            connectionMessage = result.message
        }
    }

    private func sendMessage() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        messages.append(ChatMessage(text: text, sender: .user))
        input = ""
        isInputFocused = false
        Task { await processMessage(text) }
    }

    @MainActor
    private func processMessage(_ text: String) async {
        guard network.isConnected else {
            messages.append(ChatMessage(text: "当前 WMS 尚未连接成功，请先点击顶部的“重连”。", sender: .assistant))
            return
        }

        isSending = true
        defer { isSending = false }

        // 处理 PDA 出库确认流程中的交互回复
        if awaitingPdaQty || awaitingPdaSubmit {
            let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["取消", "退出", "q", "quit", "n", "no"].contains(lower) {
                cancelPdaWorkflow()
                return
            } else if awaitingPdaSubmit && ["确认", "y", "yes", "confirm", "提交"].contains(lower) {
                await submitPdaOutbound()
                return
            } else if awaitingPdaQty, let qty = Int(lower), qty > 0, pdaTasks.count == 1, let firstTask = pdaTasks.first {
                let maxQty = NSDecimalNumber(decimal: firstTask.plannedQuantity).intValue
                if qty <= maxQty {
                    pdaActualQty[firstTask.id] = "\(qty)"
                    awaitingPdaQty = false
                    awaitingPdaSubmit = true
                    messages.append(ChatMessage(text: "已设置实际出库数量为 \(qty)。请核对下方预览并确认提交。", sender: .assistant))
                    return
                } else {
                    messages.append(ChatMessage(text: "实际出库数量（\(qty)）不能超过计划数量（\(maxQty)）。", sender: .assistant))
                    return
                }
            } else if awaitingPdaSubmit {
                messages.append(ChatMessage(text: "请点击上方“确认提交 (OutTaskConfirm)”按钮，或回复“取消”终止本次处理。", sender: .assistant))
                return
            } else {
                messages.append(ChatMessage(text: "请在上方卡片中调整数量并点击“下一步：真实出库预览”，或回复“取消”退出。", sender: .assistant))
                return
            }
        }

        // 托盘号输入（例如 A00778、A00412）优先走托盘任务查询，不进入物料名称/重量解析。
        if isTrayNumber(text) {
            await queryTrayTasks(text.uppercased())
            return
        }

        if workflowBlocked {
            let acknowledgement = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["已核对", "核对完成", "我已核对"].contains(acknowledgement) {
                workflowBlocked = false
                cancelCurrentWorkflow()
                messages.append(ChatMessage(text: "已解除流程暂停。请重新输入下一笔需求；如上一笔已创建单据，请勿重复提交相同物料。", sender: .assistant))
            } else {
                messages.append(ChatMessage(text: "上一笔流程已暂停。请先到 WMS 页面核对单据、明细和状态；核对完成后回复“已核对”，再开始新的需求。不要直接重复提交。", sender: .assistant))
            }
            return
        }

        if awaitingCandidate {
            if ["取消", "退出"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                cancelCurrentWorkflow()
            } else {
                messages.append(ChatMessage(text: "请直接点击上方正确的物料选项。", sender: .assistant))
            }
            return
        }

        if awaitingConfirmation {
            if ["取消", "退出"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                cancelCurrentWorkflow()
            } else {
                messages.append(ChatMessage(text: "物料已选好，请点击上方“确认”按钮继续。", sender: .assistant))
            }
            return
        }

        if currentDraft != nil || !requirements.isEmpty {
            messages.append(ChatMessage(text: "当前还有一笔物料流程未结束，请先完成当前物料，或回复“取消”终止本次处理。", sender: .assistant))
            return
        }

        do {
            requirements = try WMSOutboundParser.parse(text)
            currentIndex = 0
            completedSummaries = []
            messages.append(ChatMessage(text: "识别到 \(requirements.count) 种物料，将按输入顺序逐个处理。", sender: .assistant))
            await searchCurrentRequirement()
        } catch {
            await performReadOnlySearch(text)
        }
    }

    private func isTrayNumber(_ text: String) -> Bool {
        text.range(of: #"^[A-Z]\d{4,}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    @MainActor
    private func queryTrayTasks(_ tray: String) async {
        let cleanTray = tray.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        messages.append(ChatMessage(
            text: "正在查询托盘 \(cleanTray)，请稍候……",
            sender: .assistant
        ))

        do {
            let tasks = try await network.queryPdaOutboundTasks(tray: cleanTray)
            guard !tasks.isEmpty else {
                messages.append(ChatMessage(
                    text: "托盘 \(cleanTray) 没有查询到待出库任务。",
                    sender: .assistant
                ))
                return
            }

            let details = tasks.enumerated().map { index, task in
                "\(index + 1). \(task.materialName)\n编码：\(displayValue(task.materialNo))\n规格：\(displayValue(task.specification))\n计划数量：\(WMSOutboundCalculator.format(task.plannedQuantity))\n任务状态：\(displayValue(task.status))"
            }
            messages.append(ChatMessage(
                text: "托盘 \(cleanTray) 查询成功，共找到 \(tasks.count) 条出库任务：\n\n\(details.joined(separator: "\n\n"))",
                sender: .assistant
            ))

            // 启动 PDA 实际出库确认流程
            pdaTray = cleanTray
            pdaTasks = tasks
            pdaActualQty = [:]
            for t in tasks {
                let planInt = NSDecimalNumber(decimal: t.plannedQuantity).intValue
                pdaActualQty[t.id] = "\(max(1, planInt))"
            }
            awaitingPdaQty = true
            awaitingPdaSubmit = false
        } catch {
            messages.append(ChatMessage(
                text: "托盘 \(cleanTray) 查询失败：\(error.localizedDescription)",
                sender: .assistant
            ))
        }
    }

    private func cancelPdaWorkflow() {
        pdaTray = ""
        pdaTasks = []
        pdaActualQty = [:]
        awaitingPdaQty = false
        awaitingPdaSubmit = false
        messages.append(ChatMessage(text: "已取消 PDA 托盘出库确认。未发送任何出库请求。", sender: .assistant))
    }

    @MainActor
    private func submitPdaOutbound() async {
        guard !pdaTray.isEmpty, !pdaTasks.isEmpty else { return }
        awaitingPdaSubmit = false
        awaitingPdaQty = false
        isSending = true
        defer { isSending = false }

        var quantities: [String: Decimal] = [:]
        for task in pdaTasks {
            guard let rawStr = pdaActualQty[task.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let intVal = Int(rawStr),
                  intVal > 0 else {
                messages.append(ChatMessage(text: "物料【\(task.materialName)】的实际数量无效，出库确认已终止。", sender: .assistant))
                return
            }
            let planInt = NSDecimalNumber(decimal: task.plannedQuantity).intValue
            if intVal > planInt {
                messages.append(ChatMessage(text: "物料【\(task.materialName)】的实际出库数量（\(intVal)）不能超过计划数量（\(planInt)），出库确认已终止。", sender: .assistant))
                return
            }
            quantities[task.id] = Decimal(intVal)
        }

        messages.append(ChatMessage(
            text: "正在提交 OutTaskConfirm……",
            sender: .assistant
        ))

        let trayToConfirm = pdaTray
        do {
            let result = try await network.confirmPdaOutbound(tray: trayToConfirm, actualQuantities: quantities)

            let rawDescription: String
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
               let str = String(data: data, encoding: .utf8) {
                rawDescription = str
            } else if let arr = result as? [Any] {
                rawDescription = "\(arr)"
            } else {
                rawDescription = String(describing: result)
            }

            messages.append(ChatMessage(
                text: "服务器原始响应：\n\(rawDescription)",
                sender: .assistant
            ))

            if network.pdaResponseIndicatesSuccess(result) {
                messages.append(ChatMessage(
                    text: "✅ 服务器返回成功标志。请在 WMS 页面核对实际出库及剩余任务。",
                    sender: .assistant
                ))
                await taskMonitor.checkForNewTasks(using: network)
            } else {
                messages.append(ChatMessage(
                    text: "⚠️ 未能确认业务成功。请先核对 WMS 状态，不要直接重复提交。",
                    sender: .assistant
                ))
            }
        } catch {
            messages.append(ChatMessage(
                text: "❌ 提交异常：\(error.localizedDescription)\n如已发起提交，请先核对服务器状态，切勿盲目重试。",
                sender: .assistant
            ))
        }

        pdaTray = ""
        pdaTasks = []
        pdaActualQty = [:]
    }

    @MainActor
    private func performReadOnlySearch(_ keyword: String) async {
        messages.append(ChatMessage(text: "正在 WMS 中查询物料：\(keyword)", sender: .assistant))
        do {
            let materials = try await network.searchMaterials(keyword: keyword)
            guard !materials.isEmpty else {
                messages.append(ChatMessage(text: "物料查询完成，没有找到与“\(keyword)”匹配的物料。", sender: .assistant))
                return
            }

            let lines = materials.prefix(10).enumerated().map { index, material in
                "[\(index + 1)] 名称：\(material.materialName)\n编码：\(displayValue(material.materialNo))\n规格：\(displayValue(material.specification))\n单位：\(displayValue(material.unit))"
            }
            messages.append(ChatMessage(
                text: "物料查询成功，共找到 \(materials.count) 条结果：\n\n\(lines.joined(separator: "\n\n"))",
                sender: .assistant
            ))
        } catch {
            messages.append(ChatMessage(text: "物料查询失败：\(error.localizedDescription)", sender: .assistant))
        }
    }

    @MainActor
    private func searchCurrentRequirement() async {
        guard currentIndex < requirements.count else {
            let summary = completedSummaries.isEmpty
                ? "本次没有完成出库。"
                : "本次全部处理完成：\n" + completedSummaries.enumerated()
                    .map { "\($0.offset + 1). \($0.element)" }
                    .joined(separator: "\n")
            messages.append(ChatMessage(text: summary, sender: .assistant))
            requirements = []
            currentIndex = 0
            candidates = []
            selectedCandidateIndex = nil
            return
        }

        let requirement = requirements[currentIndex]
        messages.append(ChatMessage(
            text: "正在查询第 \(currentIndex + 1)/\(requirements.count) 种物料：\(requirement.name)",
            sender: .assistant
        ))

        do {
            let found = try await network.searchMaterials(keyword: requirement.name)
            guard !found.isEmpty else {
                messages.append(ChatMessage(text: "没有找到“\(requirement.name)”的候选物料。本次流程暂停，请检查名称后重新输入。", sender: .assistant))
                workflowBlocked = true
                return
            }

            candidates = Array(found.prefix(10))
            selectedCandidateIndex = nil
            awaitingCandidate = true
            messages.append(ChatMessage(
                text: "已找到 \(found.count) 个候选物料，请点击下方选项。",
                sender: .assistant
            ))
        } catch {
            messages.append(ChatMessage(text: "物料查询失败：\(error.localizedDescription)。本次流程已暂停。", sender: .assistant))
            workflowBlocked = true
        }
    }

    @MainActor
    private func chooseCandidate(at index: Int) {
        guard awaitingCandidate, candidates.indices.contains(index) else { return }

        do {
            let requirement = requirements[currentIndex]
            let material = candidates[index]
            let draft = try WMSOutboundCalculator.makeDraft(requirement: requirement, material: material)

            selectedCandidateIndex = index
            currentDraft = draft
            awaitingCandidate = false
            awaitingConfirmation = true
            messages.append(ChatMessage(
                text: "已选择：\(material.materialName)。请核对下方出库信息。",
                sender: .assistant
            ))
        } catch {
            messages.append(ChatMessage(text: "出库重量换算失败：\(error.localizedDescription)", sender: .assistant))
        }
    }

    @MainActor
    private func executeCurrentItem() async {
        guard let draft = currentDraft, awaitingConfirmation else { return }
        awaitingConfirmation = false
        isSending = true
        defer { isSending = false }

        messages.append(ChatMessage(
            text: "已确认，开始处理：\(draft.material.materialName) \(WMSOutboundCalculator.format(draft.weightKG))kg。",
            sender: .assistant
        ))

        do {
            // 每一种物料独立创建一张单据，避免不同物料混在同一执行步骤中。
            let stockOut = try await network.createStockOut()
            messages.append(ChatMessage(text: "出库单已创建：\(stockOut.number)。正在添加物料明细……", sender: .assistant))
            _ = try await network.addStockOutDetail(
                stockOutID: stockOut.id,
                materialID: draft.material.id,
                planOutWeightKG: draft.weightKG
            )
            messages.append(ChatMessage(text: "物料明细添加成功。正在核对审核状态……", sender: .assistant))

            var status = try await readStockOutStatus(id: stockOut.id)
            if status == 5 {
                messages.append(ChatMessage(text: "WMS 显示该单据已完成分配，无需重复分配。", sender: .assistant))
            } else {
                if status == 1 {
                    do {
                        _ = try await network.auditStockOut(stockOutID: stockOut.id)
                    } catch {
                        messages.append(ChatMessage(text: "自动审核接口未确认：\(error.localizedDescription)。正在只读核对单据状态，不会重复提交审核。", sender: .assistant))
                    }
                    status = try await waitForStatus(id: stockOut.id, accepted: [2, 5], attempts: 6)
                }

                if status == 5 {
                    messages.append(ChatMessage(text: "WMS 已显示单据完成分配。", sender: .assistant))
                } else if status == 2 {
                    do {
                        _ = try await network.allotStockOut(stockOutID: stockOut.id)
                    } catch {
                        messages.append(ChatMessage(text: "自动分配接口未确认：\(error.localizedDescription)。正在只读核对单据状态，不会重复提交分配。", sender: .assistant))
                    }
                    status = try await waitForStatus(id: stockOut.id, accepted: [5], attempts: 5)
                    guard status == 5 else {
                        throw OutboundInputError.invalid("分配状态尚未确认。请到 WMS 页面核对单据，不要直接重试。")
                    }
                } else {
                    throw OutboundInputError.invalid("当前单据状态为 \(status)，未确认审核完成，已停止自动分配。请在 WMS 页面检查。")
                }
            }

            var summary = "\(draft.material.materialName)（编码 \(draft.material.materialNo)）：\(WMSOutboundCalculator.format(draft.weightKG))kg"
            if let count = draft.packageCount {
                summary += "，\(WMSOutboundCalculator.format(count))\(draft.packageUnit)"
            }
            summary += "，出库单号 \(stockOut.number)"
            completedSummaries.append(summary)
            messages.append(ChatMessage(text: "出库操作已完成。\n\n\(summary)", sender: .assistant))

            currentDraft = nil
            candidates = []
            selectedCandidateIndex = nil
            currentIndex += 1
            await searchCurrentRequirement()
        } catch {
            workflowBlocked = true
            currentDraft = nil
            awaitingCandidate = false
            awaitingConfirmation = false
            messages.append(ChatMessage(
                text: "本种物料流程已暂停：\(error.localizedDescription)\n\n由于创建单据或写入操作可能已经发生，程序不会自动重试。请先在 WMS 页面核对单据、明细和状态，再决定后续操作。",
                sender: .assistant
            ))
        }
    }

    private func readStockOutStatus(id: String) async throws -> Int {
        let rows = try await network.fetchStockOutList()
        guard let row = rows.first(where: { $0.id == id }), let status = row.status else {
            throw OutboundInputError.invalid("无法从 StockOut/List 读取新单据状态。")
        }
        return status
    }

    private func waitForStatus(id: String, accepted: Set<Int>, attempts: Int) async throws -> Int {
        var lastStatus = try await readStockOutStatus(id: id)
        if accepted.contains(lastStatus) { return lastStatus }

        for attempt in 0..<attempts {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            lastStatus = try await readStockOutStatus(id: id)
            if accepted.contains(lastStatus) { return lastStatus }
            if attempt == attempts - 1 { break }
        }
        return lastStatus
    }

    private func cancelCurrentWorkflow() {
        requirements = []
        currentIndex = 0
        candidates = []
        currentDraft = nil
        selectedCandidateIndex = nil
        awaitingCandidate = false
        awaitingConfirmation = false
        completedSummaries = []
        messages.append(ChatMessage(text: "已取消当前流程。尚未确认的物料不会执行出库。", sender: .assistant))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}


// MARK: - Task monitor and Excel export

private enum TaskStatusFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case inProgress = "执行中"
    case pending = "待执行"
    case completed = "已完成"
    case abnormal = "异常/取消"

    var id: String { rawValue }

    func matches(status: String) -> Bool {
        let display = WMSTaskMonitorStore.statusDisplay(status)
        switch self {
        case .all:
            return true
        case .inProgress:
            return display == "执行中"
        case .pending:
            return display == "待执行"
        case .completed:
            return display == "已完成"
        case .abnormal:
            return display == "执行异常" || display == "已取消"
        }
    }
}

private enum TaskSortOption: String, CaseIterable, Identifiable {
    case newest = "时间最新"
    case oldest = "时间最早"
    case statusPriority = "状态优先"

    var id: String { rawValue }
}

private enum TaskDatePreset: String, CaseIterable, Identifiable {
    case today = "今天"
    case yesterday = "昨天"
    case last7Days = "最近 7 天"
    case last30Days = "最近 30 天"
    case custom = "自定义"

    var id: String { rawValue }
}

private enum TaskTypeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case productionIssue = "生产领料出库"
    case pickingPutaway = "拣货入库"
    case other = "其他任务"

    var id: String { rawValue }
}

private enum ExportFormat: String, CaseIterable, Identifiable {
    case xls = "Excel 工作表 (.xls)"
    case csv = "通用表格 (.csv)"

    var id: String { rawValue }
    var fileExtension: String { self == .xls ? "xls" : "csv" }
}

private enum ExportDetailMode: String, CaseIterable, Identifiable {
    case fullWithDetails = "完整导出（含物料明细）"
    case summaryOnly = "极速导出（仅任务列表）"

    var id: String { rawValue }
}

private enum ExportScope: String, CaseIterable, Identifiable {
    case filtered = "当前筛选结果"
    case allDate = "所选日期全部"

    var id: String { rawValue }
}

private struct ExportResult: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let totalRows: Int
    let failedDetailCount: Int
    let fileSizeString: String
    let format: ExportFormat
    let mode: ExportDetailMode
}

private struct WMSTaskRecord: Identifiable {
    let id: String
    let createdAt: String
    let taskCode: String
    let taskMainID: String
    let taskType: String
    let status: String
    let outStation: String
    let trayCode: String
    let startLocation: String
    let raw: [String: Any]

    init(_ row: [String: Any], index: Int) {
        func value(_ keys: [String]) -> String {
            for key in keys {
                if let item = row[key], !(item is NSNull) {
                    let text = String(describing: item)
                    if !text.isEmpty && text != "<null>" { return text }
                }
            }
            return ""
        }
        createdAt = value(["CreateDate", "CreateTime", "CreatedAt", "CreateDateTime"])
        taskCode = value(["TaskCode", "TrayCode"])
        taskMainID = value(["TaskMainId", "TaskId", "Id"])
        taskType = value(["TaskType", "TaskTypeName"])
        status = value(["Status", "TaskStatus"])
        outStation = value(["OutStation", "OutStationName"])
        trayCode = value(["TrayCode", "PalletCode", "ContainerCode"])
        startLocation = value(["StartLocation", "StartLoc", "FromLocation"])
        id = taskMainID.isEmpty ? (taskCode.isEmpty ? "row-\(index)" : taskCode) : taskMainID
        raw = row
    }

    var statusDisplay: String {
        WMSTaskMonitorStore.statusDisplay(status)
    }

    var taskTypeDisplay: String {
        WMSTaskMonitorStore.taskTypeTitle(taskType)
    }

    var createdDate: Date? {
        WMSTaskMonitorStore.parseRecordDate(createdAt)
    }
}

private final class WMSTaskMonitorStore: ObservableObject {
    @Published var records: [WMSTaskRecord] = []
    @Published var isLoading = false
    @Published var errorMessage = ""
    @Published var lastUpdated: Date?
    @Published var detailRows: [String: [[String: Any]]] = [:]
    @Published var detailLoadingIDs: Set<String> = []
    @Published var detailErrors: [String: String] = [:]
    @Published private(set) var latestNewTaskMessage = ""
    @Published private(set) var newTaskNoticeToken = UUID()

    private let lastSyncKey = "wms.taskMonitor.lastSuccessfulSync"
    private let recordsKey = "wms.taskMonitor.savedRecords"
    private let detailsKey = "wms.taskMonitor.savedDetails"
    private let initialBackfillCompletedKey = "wms.taskMonitor.initial90DayBackfillCompleted"
    private let initialBackfillDays = 90

    private var storageDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let subDir = dir.appendingPathComponent("WMSTasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        return subDir
    }

    private var recordsFileURL: URL {
        storageDirectory.appendingPathComponent("records.json")
    }

    private var detailsFileURL: URL {
        storageDirectory.appendingPathComponent("details.json")
    }

    init() {
        let defaults = UserDefaults.standard

        // 优先从文件加载历史记录，如无则回退 UserDefaults 并自动迁移
        if let data = try? Data(contentsOf: recordsFileURL),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            records = rows.enumerated().map { WMSTaskRecord($0.element, index: $0.offset) }
                .sorted { $0.createdAt > $1.createdAt }
        } else if let data = defaults.data(forKey: recordsKey),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            records = rows.enumerated().map { WMSTaskRecord($0.element, index: $0.offset) }
                .sorted { $0.createdAt > $1.createdAt }
            try? data.write(to: recordsFileURL, options: .atomic)
            defaults.removeObject(forKey: recordsKey)
        }

        // 优先从文件加载物料明细缓存
        if let data = try? Data(contentsOf: detailsFileURL),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] {
            detailRows = decoded
        } else if let data = defaults.data(forKey: detailsKey),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] {
            detailRows = decoded
            try? data.write(to: detailsFileURL, options: .atomic)
            defaults.removeObject(forKey: detailsKey)
        }

        lastUpdated = defaults.object(forKey: lastSyncKey) as? Date
    }

    private func saveRecordsToFile(_ recordsToSave: [WMSTaskRecord]) {
        let savedRows = recordsToSave.map { $0.raw }
        guard JSONSerialization.isValidJSONObject(savedRows),
              let data = try? JSONSerialization.data(withJSONObject: savedRows) else {
            return
        }
        try? data.write(to: recordsFileURL, options: .atomic)
    }

    @MainActor
    func loadUpdates(using network: WMSNetworkManager) async {
        guard network.isConnected, !isLoading else { return }
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        let defaults = UserDefaults.standard
        let initialBackfillCompleted = defaults.bool(forKey: initialBackfillCompletedKey)

        // 每次打开任务记录或手动刷新，都重新拉取最近 90 天的任务。
        // 不能只从上次同步时间开始查：旧任务可能从“执行中”变成“已完成”，
        // 只有重新读取旧任务行，才能把最新 Status 合并到本地记录。
        // 90 天以前的本地历史仍保留，但不会在本轮向 WMS 请求状态更新。
        let needsInitialBackfill = !initialBackfillCompleted
        let now = Date()
        let startDate = Calendar.current.date(
            byAdding: .day,
            value: -initialBackfillDays,
            to: now
        ) ?? now

        do {
            var allRows: [[String: Any]] = []
            var offset = 0
            let pageSize = 100
            while true {
                let page = try await network.fetchRecentTasksForStatusRefresh(days: initialBackfillDays, offset: offset)
                allRows.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += page.count
                if offset >= 5000 { break }
            }

            let filtered = allRows.filter { row in
                guard let rawDate = row["CreateDate"] ?? row["CreateTime"] ?? row["CreatedAt"] ?? row["CreateDateTime"] else {
                    return true
                }
                guard let date = Self.parseDate(String(describing: rawDate)) else { return true }
                return date >= startDate
            }

            // 首次 90 天补录若接口返回空数组，不推进同步时间，也不标记补录完成；
            // 下次启动仍会重试，避免一次异常空响应永久跳过历史数据。
            if needsInitialBackfill && filtered.isEmpty {
                errorMessage = "WMS 最近 90 天没有返回任务记录，本次未更新同步标记；下次打开软件会重新补录。"
                return
            }

            // 将 WMS 本次返回数据与本地历史合并，按任务主编号去重。
            // 使用逐条赋值，避免本地旧数据中存在重复 ID 时 Dictionary 初始化崩溃。
            var mergedByID: [String: WMSTaskRecord] = [:]
            for record in records {
                mergedByID[record.id] = record
            }
            for (index, row) in filtered.enumerated() {
                let record = WMSTaskRecord(row, index: index)
                guard !record.id.isEmpty else { continue }
                mergedByID[record.id] = record
            }
            let mergedRecords = Array(mergedByID.values).sorted { $0.createdAt > $1.createdAt }

            saveRecordsToFile(mergedRecords)
            records = mergedRecords

            let now = Date()
            defaults.set(now, forKey: lastSyncKey)
            if needsInitialBackfill || !records.isEmpty {
                defaults.set(true, forKey: initialBackfillCompletedKey)
            }
            lastUpdated = now
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 日期筛选专用查询：先保留本地记录供界面即时显示，再从 WMS 补齐所选日期范围。
    /// 合并时按任务主编号去重，不会删除所选范围之外的本地历史记录。
    @MainActor
    func loadTasks(from startDate: Date, to endDate: Date, using network: WMSNetworkManager) async {
        guard network.isConnected, !isLoading else { return }
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        let calendar = Calendar.current
        let rangeStart = calendar.startOfDay(for: min(startDate, endDate))
        let rangeEndDay = calendar.startOfDay(for: max(startDate, endDate))
        let rangeEndExclusive = calendar.date(byAdding: .day, value: 1, to: rangeEndDay)
            ?? rangeEndDay.addingTimeInterval(86_400)

        do {
            var allRows: [[String: Any]] = []
            var offset = 0
            let pageSize = 100
            while true {
                let page = try await network.fetchTasks(from: rangeStart, to: rangeEndDay, offset: offset)
                allRows.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += page.count
                if offset >= 5000 { break }
            }

            let selectedRows = allRows.filter { row in
                guard let rawDate = row["CreateDate"] ?? row["CreateTime"] ?? row["CreatedAt"] ?? row["CreateDateTime"] else {
                    return false
                }
                guard let date = Self.parseDate(String(describing: rawDate)) else { return false }
                return date >= rangeStart && date < rangeEndExclusive
            }

            var mergedByID: [String: WMSTaskRecord] = [:]
            for record in records {
                mergedByID[record.id] = record
            }
            for (index, row) in selectedRows.enumerated() {
                let record = WMSTaskRecord(row, index: index)
                guard !record.id.isEmpty else { continue }
                mergedByID[record.id] = record
            }

            let mergedRecords = Array(mergedByID.values).sorted { $0.createdAt > $1.createdAt }
            saveRecordsToFile(mergedRecords)
            records = mergedRecords
            let now = Date()
            UserDefaults.standard.set(now, forKey: lastSyncKey)
            lastUpdated = now
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// App 前台轮询专用：从上次成功同步时间开始增量查询，只对真正新增的任务发出提示。
    /// 首次 90 天历史补录由 loadUpdates 完成，不会把历史任务误报为“新增”。
    @MainActor
    func checkForNewTasks(using network: WMSNetworkManager) async {
        guard network.isConnected, !isLoading else { return }
        // 若首次 90 天补录暂时没有成功建立同步点，轮询只检查最近一分钟，
        // 避免每 30 秒重复请求整段历史；下次重新打开软件仍会再次尝试完整补录。
        let syncPoint = lastUpdated ?? Date().addingTimeInterval(-60)

        isLoading = true
        errorMessage = ""
        defer { isLoading = false }

        do {
            var allRows: [[String: Any]] = []
            var offset = 0
            let pageSize = 100

            while true {
                let page = try await network.fetchTasks(since: syncPoint, offset: offset)
                allRows.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += page.count
                if offset >= 5000 { break }
            }

            // 服务器列表的日期筛选通常精确到“日”，这里再按上次同步时刻过滤。
            let candidateRows = allRows.filter { row in
                guard let rawDate = row["CreateDate"] ?? row["CreateTime"] ?? row["CreatedAt"] ?? row["CreateDateTime"] else {
                    return true
                }
                guard let date = Self.parseDate(String(describing: rawDate)) else { return true }
                return date >= syncPoint
            }

            let oldIDs = Set(records.map(\.id))
            var mergedByID: [String: WMSTaskRecord] = [:]
            for record in records {
                mergedByID[record.id] = record
            }

            var newRecords: [WMSTaskRecord] = []
            for (index, row) in candidateRows.enumerated() {
                let record = WMSTaskRecord(row, index: index)
                guard !record.id.isEmpty else { continue }
                if !oldIDs.contains(record.id) {
                    newRecords.append(record)
                }
                // 同步返回的记录也合并，保留 WMS 最新状态。
                mergedByID[record.id] = record
            }

            let mergedRecords = Array(mergedByID.values).sorted { $0.createdAt > $1.createdAt }
            saveRecordsToFile(mergedRecords)
            records = mergedRecords

            let now = Date()
            UserDefaults.standard.set(now, forKey: lastSyncKey)
            lastUpdated = now

            if !newRecords.isEmpty {
                let descriptions = newRecords.prefix(4).map { record in
                    let taskName: String
                    switch record.taskType {
                    case "13", "13.0": taskName = "生产领料出库"
                    case "8", "8.0": taskName = "拣货入库"
                    default: taskName = record.taskType.isEmpty ? "其他任务" : record.taskType
                    }
                    let tray = record.trayCode.isEmpty ? "托盘未知" : "托盘 \(record.trayCode)"
                    return "\(taskName) · \(tray)"
                }
                let extraCount = newRecords.count - descriptions.count
                let suffix = extraCount > 0 ? "，另有 \(extraCount) 条" : ""
                latestNewTaskMessage = "发现新增 \(newRecords.count) 条任务：\(descriptions.joined(separator: "；"))\(suffix)"
                newTaskNoticeToken = UUID()
            }
        } catch {
            // 轮询失败不清空本地数据，也不推进同步时间，下次前台轮询会重试。
            errorMessage = error.localizedDescription
        }
    }

    /// 点击某条任务时再读取其明细，避免打开监控页时对数百条任务逐条发请求。
    @MainActor
    func loadDetails(for record: WMSTaskRecord, using network: WMSNetworkManager) async {
        guard !record.taskMainID.isEmpty,
              detailRows[record.id] == nil,
              !detailLoadingIDs.contains(record.id) else { return }
        detailLoadingIDs.insert(record.id)
        detailErrors.removeValue(forKey: record.id)
        defer { detailLoadingIDs.remove(record.id) }
        do {
            let rows = try await network.fetchTaskDetails(taskID: record.taskMainID)
            detailRows[record.id] = rows
            persistDetails()
        } catch {
            detailErrors[record.id] = error.localizedDescription
        }
    }

    private func persistDetails() {
        let serializable = detailRows.mapValues { rows in
            rows.map { row in
                row.reduce(into: [String: Any]()) { result, pair in
                    if !(pair.value is NSNull),
                       JSONSerialization.isValidJSONObject(["value": pair.value]) {
                        result[pair.key] = pair.value
                    } else {
                        result[pair.key] = String(describing: pair.value)
                    }
                }
            }
        }
        guard JSONSerialization.isValidJSONObject(serializable),
              let data = try? JSONSerialization.data(withJSONObject: serializable) else {
            return
        }
        try? data.write(to: detailsFileURL, options: .atomic)
    }

    /// 高并发多线程拉取物料明细，大幅提升导出和批量查看速度
    @MainActor
    func prefetchDetailsConcurrently(
        for records: [WMSTaskRecord],
        maxConcurrency: Int = 8,
        using network: WMSNetworkManager,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> Int {
        let unCached = records.filter { detailRows[$0.id] == nil }
        guard !unCached.isEmpty else {
            onProgress?(records.count, records.count)
            return 0
        }

        let total = unCached.count
        var completed = 0
        var failedCount = 0

        await withTaskGroup(of: (String, [[String: Any]]?, String?).self) { group in
            var iterator = unCached.makeIterator()

            for _ in 0..<min(maxConcurrency, total) {
                if let record = iterator.next() {
                    group.addTask {
                        guard !record.taskMainID.isEmpty else {
                            return (record.id, nil, "缺少任务主编号")
                        }
                        do {
                            let details = try await network.fetchTaskDetails(taskID: record.taskMainID)
                            return (record.id, details, nil)
                        } catch {
                            return (record.id, nil, error.localizedDescription)
                        }
                    }
                }
            }

            while let result = await group.next() {
                completed += 1
                let (recordID, details, errorDesc) = result
                if let details = details {
                    self.detailRows[recordID] = details
                    self.detailErrors.removeValue(forKey: recordID)
                } else {
                    failedCount += 1
                    self.detailErrors[recordID] = errorDesc ?? "明细获取失败"
                }

                onProgress?(completed, total)

                if let nextRecord = iterator.next() {
                    group.addTask {
                        guard !nextRecord.taskMainID.isEmpty else {
                            return (nextRecord.id, nil, "缺少任务主编号")
                        }
                        do {
                            let details = try await network.fetchTaskDetails(taskID: nextRecord.taskMainID)
                            return (nextRecord.id, details, nil)
                        } catch {
                            return (nextRecord.id, nil, error.localizedDescription)
                        }
                    }
                }
            }
        }

        persistDetails()
        return failedCount
    }

    /// 统一高速导出接口：支持极速导出 (秒级纯本地) 与完整明细并发导出，支持 XLS 与 CSV
    @MainActor
    func exportData(
        records recordsToExport: [WMSTaskRecord],
        detailMode: ExportDetailMode,
        format: ExportFormat,
        using network: WMSNetworkManager,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> ExportResult {
        var failedDetailCount = 0

        if detailMode == .fullWithDetails {
            failedDetailCount = await prefetchDetailsConcurrently(
                for: recordsToExport,
                maxConcurrency: 8,
                using: network,
                onProgress: onProgress
            )
        }

        let baseColumns = ["创建时间", "任务编号", "任务主编号", "任务类型", "状态", "出库站点", "托盘号", "起始库位"]
        let detailColumns = [
            "物料编码", "物料名称", "供应商", "规格型号", "批号", "件数", "重量",
            "入库日期", "有效日期", "是否坏包", "生产日期", "质检状态"
        ]

        let headers: [String]
        var rows: [[String]] = []

        if detailMode == .summaryOnly {
            headers = baseColumns
            for record in recordsToExport {
                rows.append([
                    Self.displayDate(record.createdAt),
                    record.taskCode,
                    record.taskMainID,
                    Self.taskTypeTitle(record.taskType),
                    Self.statusDisplay(record.status),
                    record.outStation,
                    record.trayCode,
                    record.startLocation
                ])
            }
        } else {
            let allDetails = recordsToExport.flatMap { detailRows[$0.id] ?? [] }
            let knownColumns = Set(detailColumns)
            let extraColumns = Array(
                Set(allDetails.flatMap { Self.detailEntries($0).map(\.0) })
                    .subtracting(knownColumns)
            ).sorted()
            headers = baseColumns + detailColumns + extraColumns

            for record in recordsToExport {
                let base = [
                    Self.displayDate(record.createdAt),
                    record.taskCode,
                    record.taskMainID,
                    Self.taskTypeTitle(record.taskType),
                    Self.statusDisplay(record.status),
                    record.outStation,
                    record.trayCode,
                    record.startLocation
                ]
                let details = detailRows[record.id] ?? []

                if details.isEmpty {
                    var emptyCols = Array(repeating: "", count: headers.count - base.count)
                    if let err = detailErrors[record.id] {
                        emptyCols[0] = "[明细获取失败: \(err)]"
                    }
                    rows.append(base + emptyCols)
                } else {
                    for detail in details {
                        let values = Self.detailEntries(detail).reduce(into: [String: String]()) {
                            $0[$1.0] = $1.1
                        }
                        rows.append(base + (detailColumns + extraColumns).map { values[$0] ?? "" })
                    }
                }
            }
        }

        let timeStamp = Self.fileStampFormatter.string(from: Date())
        let modeTag = detailMode == .summaryOnly ? "基础" : "明细"
        let fileName = "WMS任务列表_\(modeTag)_\(timeStamp).\(format.fileExtension)"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        let fileData: Data
        switch format {
        case .csv:
            var csv = "\u{FEFF}" // UTF-8 BOM，防止 Windows/Excel 中文乱码
            csv.append(headers.map { Self.csvEscape($0) }.joined(separator: ",") + "\r\n")
            for row in rows {
                csv.append(row.map { Self.csvEscape($0) }.joined(separator: ",") + "\r\n")
            }
            guard let data = csv.data(using: .utf8) else {
                throw NSError(domain: "WMSTaskExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法生成 CSV 文件"])
            }
            fileData = data

        case .xls:
            func cell(_ value: String, isHeader: Bool = false, isOdd: Bool = false) -> String {
                let style = isHeader ? "Header" : (isOdd ? "OddRow" : "EvenRow")
                return "<Cell ss:StyleID=\"\(style)\"><Data ss:Type=\"String\">\(Self.xmlEscape(value))</Data></Cell>"
            }

            var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <?mso-application progid="Excel.Sheet"?>
            <Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"
             xmlns:o="urn:schemas-microsoft-com:office:office"
             xmlns:x="urn:schemas-microsoft-com:office:excel"
             xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
              <Styles>
                <Style ss:ID="Header">
                  <Font ss:Bold="1" ss:Color="#FFFFFF"/>
                  <Interior ss:Color="#2563EB" ss:Pattern="Solid"/>
                  <Borders>
                    <Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#D1D5DB"/>
                  </Borders>
                </Style>
                <Style ss:ID="EvenRow">
                  <Interior ss:Color="#FFFFFF" ss:Pattern="Solid"/>
                  <Borders>
                    <Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#E5E7EB"/>
                  </Borders>
                </Style>
                <Style ss:ID="OddRow">
                  <Interior ss:Color="#F9FAFB" ss:Pattern="Solid"/>
                  <Borders>
                    <Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#E5E7EB"/>
                  </Borders>
                </Style>
              </Styles>
              <Worksheet ss:Name="WMS任务">
                <Table>
            """
            xml.append("<Row>" + headers.map { cell($0, isHeader: true) }.joined() + "</Row>\n")
            for (index, row) in rows.enumerated() {
                let isOdd = index % 2 == 1
                xml.append("<Row>" + row.map { cell($0, isOdd: isOdd) }.joined() + "</Row>\n")
            }
            xml.append("""
                </Table>
              </Worksheet>
            </Workbook>
            """)

            guard let data = ("\u{FEFF}" + xml).data(using: .utf8) else {
                throw NSError(domain: "WMSTaskExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法生成 Excel 文件"])
            }
            fileData = data
        }

        try fileData.write(to: fileURL, options: .atomic)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? Int64(fileData.count)
        let fileSizeString = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)

        return ExportResult(
            url: fileURL,
            fileName: fileName,
            totalRows: rows.count,
            failedDetailCount: failedDetailCount,
            fileSizeString: fileSizeString,
            format: format,
            mode: detailMode
        )
    }

    @MainActor
    func exportXLS(
        records selectedRecords: [WMSTaskRecord]? = nil,
        using network: WMSNetworkManager
    ) async throws -> URL {
        let result = try await exportData(
            records: selectedRecords ?? records,
            detailMode: .fullWithDetails,
            format: .xls,
            using: network
        )
        return result.url
    }

    /// 将 WMS 任务状态转换为界面中文。
    /// 状态码 3 已通过同一任务在 WMS 网页端显示“已完成”交叉核对。
    /// 其他未核实的数字码不猜测，显示“未知状态”，避免把错误状态展示给操作人员。
    static func statusDisplay(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "状态未知" }

        switch value.lowercased() {
        case "3", "已完成", "完成", "completed", "complete", "finished", "success":
            return "已完成"
        case "待执行", "待开始", "pending", "waiting":
            return "待执行"
        case "执行中", "进行中", "运行中", "processing", "running", "inprogress", "in progress":
            return "执行中"
        case "已取消", "取消", "cancelled", "canceled":
            return "已取消"
        case "执行异常", "异常", "失败", "error", "failed", "failure":
            return "执行异常"
        default:
            if Int(value) != nil { return "未知状态" }
            return value
        }
    }

    static func isProductionIssue(_ rawType: String) -> Bool {
        let value = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "13" || value == "13.0"
            || value.localizedCaseInsensitiveContains("生产领料出库")
    }

    static func isPickingPutaway(_ rawType: String) -> Bool {
        let value = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "8" || value == "8.0"
            || value.localizedCaseInsensitiveContains("拣货入库")
    }

    static func isOtherTaskType(_ rawType: String) -> Bool {
        !isProductionIssue(rawType) && !isPickingPutaway(rawType)
    }

    static func taskTypeTitle(_ rawType: String) -> String {
        let value = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        if isProductionIssue(value) { return "生产领料出库" }
        if isPickingPutaway(value) { return "拣货入库" }
        return value.isEmpty ? "其他任务" : value
    }

    static func parseRecordDate(_ value: String) -> Date? {
        parseDate(value)
    }

    static func displayDate(_ value: String) -> String {
        guard let date = parseDate(value) else { return value }
        return displayFormatter.string(from: date)
    }

    static func detailEntries(_ row: [String: Any]) -> [(String, String)] {
        let groups: [(String, [String])] = [
            ("物料编码", ["MaterialNo", "MaterialCode", "MaterialCodeNo", "GoodsCode", "ItemCode"]),
            ("物料名称", ["MaterialName", "GoodsName", "ItemName"]),
            ("供应商", ["SupplierName", "Supplier", "VendorName"]),
            ("规格型号", ["Specification", "Spec", "Model", "MaterialSpec"]),
            ("批号", ["BatchNo", "Batch", "LotNo"]),
            ("件数", ["Qty", "Quantity", "PieceQty", "Count"]),
            ("重量", ["Weight", "TotalWeight", "NetWeight"]),
            ("入库日期", ["InDate", "StorageDate", "StockInDate"]),
            ("有效日期", ["ExpireDate", "ExpiryDate", "ValidDate"]),
            ("是否坏包", ["IsBadPack", "BadPack", "IsDamaged"]),
            ("生产日期", ["ProductionDate", "ProduceDate", "ManufactureDate", "MfgDate"]),
            ("质检状态", ["Qualified", "QualityStatus", "QCStatus", "CheckStatus"])
        ]
        var output: [(String, String)] = []
        var used = Set<String>()
        for (label, keys) in groups {
            for key in keys {
                if let raw = row[key], !(raw is NSNull) {
                    let value = String(describing: raw)
                    if !value.isEmpty && value != "<null>" {
                        let displayVal: String
                        switch label {
                        case "是否坏包":
                            switch value.lowercased() {
                            case "0", "false", "否": displayVal = "否"
                            case "1", "true", "是": displayVal = "是"
                            default: displayVal = value
                            }
                        case "质检状态":
                            switch value.lowercased() {
                            case "1", "true", "合格", "qualified": displayVal = "合格"
                            case "0", "false", "不合格", "unqualified": displayVal = "不合格"
                            default: displayVal = value
                            }
                        default:
                            displayVal = value.hasPrefix("/Date(") ? displayDate(value) : value
                        }
                        output.append((label, displayVal))
                        used.insert(key)
                        break
                    }
                }
            }
        }
        let hiddenKeys: Set<String> = ["TaskDetailId", "TaskMainId", "Id", "MaterialId", "IsDel", "CreateDate", "UpdateDate"]
        for key in row.keys.sorted() where !used.contains(key) && !hiddenKeys.contains(key) {
            guard let raw = row[key], !(raw is NSNull) else { continue }
            let value = String(describing: raw)
            if !value.isEmpty && value != "<null>" {
                output.append((key, value.hasPrefix("/Date(") ? displayDate(value) : value))
            }
        }
        return output
    }

    static func csvEscape(_ field: String) -> String {
        let clean = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.contains(",") || clean.contains("\"") || clean.contains("\n") || clean.contains("\r") {
            return "\"\(clean.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return clean
    }

    static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func parseDate(_ value: String) -> Date? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("/Date(") {
            let digits = clean.replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
            if let milliseconds = Double(digits) { return Date(timeIntervalSince1970: milliseconds / 1000) }
        }
        for formatter in isoFormatters {
            if let date = formatter.date(from: clean) { return date }
        }
        return nil
    }

    static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let isoFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy-MM-dd"
        ]
        return formats.map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = format
            return f
        }
    }()
}

// MARK: - Status Badge View
private struct WMSTaskStatusBadge: View {
    let status: String

    var body: some View {
        let display = WMSTaskMonitorStore.statusDisplay(status)
        let style = statusStyle(for: display)

        HStack(spacing: 3) {
            Image(systemName: style.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(display)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(style.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(style.color.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(style.color.opacity(0.24), lineWidth: 0.8))
    }

    private func statusStyle(for display: String) -> (color: Color, icon: String) {
        switch display {
        case "已完成":
            return (.green, "checkmark.circle.fill")
        case "执行中":
            return (.blue, "arrow.triangle.2.circlepath")
        case "待执行":
            return (.orange, "clock.fill")
        case "执行异常":
            return (.red, "exclamationmark.triangle.fill")
        case "已取消":
            return (.secondary, "xmark.circle.fill")
        default:
            return (.secondary, "questionmark.circle")
        }
    }
}

// MARK: - Metrics Dashboard Bar
private struct WMSTaskMetricsBar: View {
    let totalCount: Int
    let inProgressCount: Int
    let pendingCount: Int
    let completedCount: Int
    @Binding var selectedFilter: TaskStatusFilter

    private var completionRate: Int {
        guard totalCount > 0 else { return 0 }
        return completedCount * 100 / totalCount
    }

    var body: some View {
        HStack(spacing: 8) {
            metricCard(
                title: "总任务",
                value: "\(totalCount)",
                badge: "全部",
                tint: .primary,
                isSelected: selectedFilter == .all
            ) {
                selectedFilter = .all
            }

            metricCard(
                title: "执行中",
                value: "\(inProgressCount)",
                badge: "进行中",
                tint: .blue,
                isSelected: selectedFilter == .inProgress
            ) {
                selectedFilter = (selectedFilter == .inProgress ? .all : .inProgress)
            }

            metricCard(
                title: "待执行",
                value: "\(pendingCount)",
                badge: "排队中",
                tint: .orange,
                isSelected: selectedFilter == .pending
            ) {
                selectedFilter = (selectedFilter == .pending ? .all : .pending)
            }

            metricCard(
                title: "已完成",
                value: "\(completedCount)",
                badge: "\(completionRate)%",
                tint: .green,
                isSelected: selectedFilter == .completed
            ) {
                selectedFilter = (selectedFilter == .completed ? .all : .completed)
            }
        }
        .padding(.vertical, 3)
    }

    private func metricCard(
        title: String,
        value: String,
        badge: String,
        tint: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(tint.opacity(0.12), in: Capsule())
                }
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(tint == .primary ? Color.primary : tint)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? tint.opacity(0.12) : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? tint : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tray Quick Inspection Sheet
private struct WMSTrayQuickSheet: View {
    let tray: String
    @ObservedObject var network: WMSNetworkManager
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var tasks: [WMSPdaTask] = []
    @State private var errorMessage = ""
    @State private var copiedToast = false
    @State private var actualQuantities: [String: String] = [:]
    @State private var isSubmitting = false
    @State private var showConfirmDialog = false
    @State private var submitAlertMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在查询托盘 \(tray) 任务…")
                } else if !errorMessage.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("托盘查询失败")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            Task { await loadTrayTasks() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                } else if tasks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "shippingbox")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("托盘 \(tray)")
                            .font(.headline)
                        Text("该托盘当前没有待出库的 PDA 任务。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    List {
                        Section {
                            HStack {
                                Text("托盘编号：\(tray)")
                                    .font(.headline)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = tray
                                    copiedToast = true
                                    Task {
                                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                                        copiedToast = false
                                    }
                                } label: {
                                    Label(copiedToast ? "已复制" : "复制", systemImage: copiedToast ? "checkmark" : "doc.on.doc")
                                        .font(.caption.weight(.medium))
                                }
                                .buttonStyle(.bordered)
                            }
                            Text("共找到 \(tasks.count) 条出库任务")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Section("出库任务列表") {
                            ForEach(tasks) { task in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(task.materialName)
                                            .font(.subheadline.bold())
                                        Spacer()
                                        Text(task.status.isEmpty ? "待出库" : task.status)
                                            .font(.caption2.bold())
                                            .foregroundStyle(.blue)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.1), in: Capsule())
                                    }
                                    Text("物料编码：\(task.materialNo.isEmpty ? "-" : task.materialNo)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    Text("规格型号：\(task.specification.isEmpty ? "-" : task.specification)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    Text("TaskDetailId：\(task.id)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text("计划出库量：\(WMSOutboundCalculator.format(task.plannedQuantity))")
                                        .font(.footnote.weight(.medium))

                                    // 实际取出数量调整
                                    HStack(spacing: 8) {
                                        Text("实际数量：")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        let planInt = NSDecimalNumber(decimal: task.plannedQuantity).intValue
                                        let curVal = Int(actualQuantities[task.id] ?? "\(planInt)") ?? planInt

                                        Button {
                                            if curVal > 1 { actualQuantities[task.id] = "\(curVal - 1)" }
                                        } label: {
                                            Image(systemName: "minus.circle")
                                                .font(.body)
                                                .foregroundStyle(curVal > 1 ? Color.blue : Color.secondary.opacity(0.3))
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(curVal <= 1 || isSubmitting)

                                        TextField("数量", text: Binding(
                                            get: { actualQuantities[task.id] ?? "\(planInt)" },
                                            set: { actualQuantities[task.id] = $0 }
                                        ))
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 44)
                                        .padding(.vertical, 2)
                                        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                                        .disabled(isSubmitting)

                                        Button {
                                            if curVal < planInt { actualQuantities[task.id] = "\(curVal + 1)" }
                                        } label: {
                                            Image(systemName: "plus.circle")
                                                .font(.body)
                                                .foregroundStyle(curVal < planInt ? Color.blue : Color.secondary.opacity(0.3))
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(curVal >= planInt || isSubmitting)
                                    }
                                    .padding(.top, 4)
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        Section("真实出库确认") {
                            let totalPlan = tasks.reduce(0) { $0 + (NSDecimalNumber(decimal: $1.plannedQuantity).intValue) }
                            let totalActual = tasks.reduce(0) { $0 + (Int(actualQuantities[$1.id] ?? "0") ?? 0) }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("计划总量：\(totalPlan)")
                                    Spacer()
                                    Text("实际总量：\(totalActual)")
                                    Spacer()
                                    Text("剩余：\(totalPlan - totalActual)")
                                }
                                .font(.footnote.weight(.medium))

                                Text("⚠️ 真实提交将修改 WMS 库存及任务状态，写操作不会自动重试。")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)

                            Button {
                                showConfirmDialog = true
                            } label: {
                                HStack {
                                    Spacer()
                                    if isSubmitting {
                                        ProgressView().tint(.white)
                                    } else {
                                        Text("确认出库提交 (OutTaskConfirm)")
                                            .font(.subheadline.bold())
                                    }
                                    Spacer()
                                }
                                .foregroundStyle(.white)
                                .padding(.vertical, 10)
                                .background(Color.blue, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .disabled(isSubmitting)
                        }
                    }
                }
            }
            .navigationTitle("托盘快捷查询")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                await loadTrayTasks()
            }
            .confirmationDialog("确认提交出库？", isPresented: $showConfirmDialog, titleVisibility: .visible) {
                Button("确认提交 (OutTaskConfirm)", role: .none) {
                    Task { await submitOutTaskConfirm() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("托盘：\(tray)\n接口：OutTaskConfirm\n真实提交将修改 WMS 库存，确认继续？")
            }
            .alert("出库提交结果", isPresented: Binding(
                get: { submitAlertMessage != nil },
                set: { if !$0 { submitAlertMessage = nil } }
            )) {
                Button("好", role: .cancel) {
                    submitAlertMessage = nil
                }
            } message: {
                Text(submitAlertMessage ?? "")
            }
        }
    }

    private func loadTrayTasks() async {
        guard !tray.isEmpty else { return }
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }
        do {
            tasks = try await network.queryPdaOutboundTasks(tray: tray)
            actualQuantities = [:]
            for t in tasks {
                let planInt = NSDecimalNumber(decimal: t.plannedQuantity).intValue
                actualQuantities[t.id] = "\(max(1, planInt))"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submitOutTaskConfirm() async {
        guard !tasks.isEmpty else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        var quantities: [String: Decimal] = [:]
        for task in tasks {
            guard let raw = actualQuantities[task.id], let val = Int(raw), val > 0 else {
                submitAlertMessage = "物料【\(task.materialName)】实际数量无效"
                return
            }
            let planInt = NSDecimalNumber(decimal: task.plannedQuantity).intValue
            if val > planInt {
                submitAlertMessage = "物料【\(task.materialName)】实际数量不能超过计划数量"
                return
            }
            quantities[task.id] = Decimal(val)
        }

        do {
            let res = try await network.confirmPdaOutbound(tray: tray, actualQuantities: quantities)
            if network.pdaResponseIndicatesSuccess(res) {
                submitAlertMessage = "✅ 提交成功！服务器已确认实际出库。请在 WMS 页面核对库存。"
                // 刷新列表
                await loadTrayTasks()
            } else {
                submitAlertMessage = "⚠️ 服务器未返回成功标志：\(res)\n请人工核对 WMS 状态，切勿重复提交。"
            }
        } catch {
            submitAlertMessage = "❌ 提交失败：\(error.localizedDescription)\n如已发起提交，请先核对 WMS 状态。"
        }
    }
}

// MARK: - Export Sheet with Progress and Options
private struct WMSTaskExportSheet: View {
    @ObservedObject var store: WMSTaskMonitorStore
    @ObservedObject var network: WMSNetworkManager
    let filteredRecords: [WMSTaskRecord]
    let allDateRecords: [WMSTaskRecord]
    @Environment(\.dismiss) private var dismiss

    @State private var selectedScope: ExportScope = .filtered
    @State private var selectedMode: ExportDetailMode = .fullWithDetails
    @State private var selectedFormat: ExportFormat = .xls
    @State private var isRunning = false
    @State private var progressText = ""
    @State private var progressRatio: Double = 0.0
    @State private var exportResult: ExportResult?
    @State private var errorMessage = ""

    private var targetRecords: [WMSTaskRecord] {
        selectedScope == .filtered ? filteredRecords : allDateRecords
    }

    private var uncachedDetailCount: Int {
        targetRecords.filter { store.detailRows[$0.id] == nil }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                if let result = exportResult {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.green)
                            Text("导出成功！")
                                .font(.title3.bold())
                            Text(result.fileName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            HStack(spacing: 20) {
                                VStack {
                                    Text("记录行数")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text("\(result.totalRows)")
                                        .font(.headline)
                                }
                                Divider().frame(height: 24)
                                VStack {
                                    Text("文件大小")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(result.fileSizeString)
                                        .font(.headline)
                                }
                                Divider().frame(height: 24)
                                VStack {
                                    Text("导出格式")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(result.format.fileExtension.uppercased())
                                        .font(.headline)
                                }
                            }
                            .padding(.vertical, 8)

                            if result.failedDetailCount > 0 {
                                Label("提示：有 \(result.failedDetailCount) 条任务明细获取失败，已在表格中保留基础数据并标注。", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }

                            ShareLink(item: result.url) {
                                Label("分享 / 保存文件", systemImage: "square.and.arrow.up")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                } else {
                    Section("导出数据范围") {
                        Picker("数据范围", selection: $selectedScope) {
                            Text("当前筛选 (\(filteredRecords.count) 条)").tag(ExportScope.filtered)
                            Text("所选日期全部 (\(allDateRecords.count) 条)").tag(ExportScope.allDate)
                        }
                        .pickerStyle(.segmented)
                    }

                    Section("导出内容模式") {
                        Picker("内容模式", selection: $selectedMode) {
                            ForEach(ExportDetailMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()

                        if selectedMode == .fullWithDetails {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "bolt.horizontal.fill")
                                    .foregroundStyle(.blue)
                                if uncachedDetailCount == 0 {
                                    Text("所有任务物料明细均已缓存，可秒级即刻导出。")
                                        .font(.footnote).foregroundStyle(.secondary)
                                } else {
                                    Text("将并发多线程拉取 \(uncachedDetailCount) 条物料明细，多连接加速拉取，预计仅需 1~3 秒。")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(.orange)
                                Text("极速模式：导出任务编号、类型、状态、站点、托盘号与库位，0.1秒纯本地秒出，无需等待网络。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("导出文件格式") {
                        Picker("文件格式", selection: $selectedFormat) {
                            ForEach(ExportFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if isRunning {
                        Section("正在导出") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(progressText.isEmpty ? "正在处理…" : progressText)
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(Int(progressRatio * 100))%")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.blue)
                                }
                                ProgressView(value: progressRatio, total: 1.0)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if !errorMessage.isEmpty {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }

                    Section {
                        Button {
                            startExport()
                        } label: {
                            HStack {
                                Spacer()
                                if isRunning {
                                    ProgressView().tint(.white).padding(.trailing, 4)
                                    Text("正在高速导出…")
                                } else {
                                    Image(systemName: "arrow.down.doc")
                                    Text("立即导出 (\(targetRecords.count) 条任务)")
                                }
                                Spacer()
                            }
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .listRowBackground(targetRecords.isEmpty || isRunning ? Color.gray : Color.blue)
                        .disabled(targetRecords.isEmpty || isRunning)
                    }
                }
            }
            .navigationTitle("导出任务记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .disabled(isRunning)
                }
            }
        }
    }

    private func startExport() {
        guard !targetRecords.isEmpty, !isRunning else { return }
        isRunning = true
        errorMessage = ""
        exportResult = nil
        progressRatio = 0.0
        progressText = selectedMode == .fullWithDetails ? "正在准备并发拉取物料明细…" : "正在生成本地表格…"

        Task {
            defer { isRunning = false }
            do {
                let result = try await store.exportData(
                    records: targetRecords,
                    detailMode: selectedMode,
                    format: selectedFormat,
                    using: network
                ) { completed, total in
                    progressRatio = Double(completed) / Double(max(1, total))
                    progressText = "正在并行读取物料明细 (\(completed)/\(total))"
                }
                progressRatio = 1.0
                progressText = "导出完成！"
                exportResult = result
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Task Monitor View
private struct WMSTaskMonitorView: View {
    @ObservedObject var store: WMSTaskMonitorStore
    @ObservedObject var network: WMSNetworkManager
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var expandedIDs: Set<String> = []
    @State private var selectedStatusFilter: TaskStatusFilter = .all
    @State private var selectedTaskType: TaskTypeFilter = .all
    @State private var selectedDatePreset: TaskDatePreset = .last7Days
    @State private var selectedSortOption: TaskSortOption = .newest
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    @State private var endDate = Date()

    @State private var showExportSheet = false
    @State private var inspectingTray: String? = nil
    @State private var copiedNotice = ""

    private var selectedDateRange: (start: Date, endExclusive: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: min(startDate, endDate))
        let endDay = calendar.startOfDay(for: max(startDate, endDate))
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDay)
            ?? endDay.addingTimeInterval(86_400)
        return (start, endExclusive)
    }

    private var dateFilteredRecords: [WMSTaskRecord] {
        let range = selectedDateRange
        return store.records.filter { record in
            guard let date = WMSTaskMonitorStore.parseRecordDate(record.createdAt) else {
                return false
            }
            return date >= range.start && date < range.endExclusive
        }
    }

    private var statusFilteredRecords: [WMSTaskRecord] {
        dateFilteredRecords.filter { selectedStatusFilter.matches(status: $0.status) }
    }

    private var typeFilteredRecords: [WMSTaskRecord] {
        statusFilteredRecords.filter { matchesTaskType($0) }
    }

    private var searchFilteredRecords: [WMSTaskRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return typeFilteredRecords }
        return typeFilteredRecords.filter { record in
            if [record.taskCode, record.taskMainID, record.trayCode, record.startLocation, record.status, record.taskType]
                .contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
                return true
            }
            if let details = store.detailRows[record.id] {
                for detail in details {
                    for (_, val) in WMSTaskMonitorStore.detailEntries(detail) {
                        if val.localizedCaseInsensitiveContains(query) { return true }
                    }
                }
            }
            return false
        }
    }

    private var sortedRecords: [WMSTaskRecord] {
        switch selectedSortOption {
        case .newest:
            return searchFilteredRecords.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return searchFilteredRecords.sorted { $0.createdAt < $1.createdAt }
        case .statusPriority:
            func priority(for status: String) -> Int {
                switch WMSTaskMonitorStore.statusDisplay(status) {
                case "执行中": return 0
                case "待执行": return 1
                case "执行异常": return 2
                case "已完成": return 3
                case "已取消": return 4
                default: return 5
                }
            }
            return searchFilteredRecords.sorted { a, b in
                let pa = priority(for: a.status)
                let pb = priority(for: b.status)
                if pa != pb { return pa < pb }
                return a.createdAt > b.createdAt
            }
        }
    }

    private func statusCount(for filter: TaskStatusFilter) -> Int {
        switch filter {
        case .all:
            return dateFilteredRecords.count
        case .inProgress, .pending, .completed, .abnormal:
            return dateFilteredRecords.filter { filter.matches(status: $0.status) }.count
        }
    }

    private func typeCount(for filter: TaskTypeFilter) -> Int {
        switch filter {
        case .all:
            return statusFilteredRecords.count
        case .productionIssue:
            return statusFilteredRecords.filter { WMSTaskMonitorStore.isProductionIssue($0.taskType) }.count
        case .pickingPutaway:
            return statusFilteredRecords.filter { WMSTaskMonitorStore.isPickingPutaway($0.taskType) }.count
        case .other:
            return statusFilteredRecords.filter { WMSTaskMonitorStore.isOtherTaskType($0.taskType) }.count
        }
    }

    private func applyDatePreset(_ preset: TaskDatePreset) {
        selectedDatePreset = preset
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch preset {
        case .today:
            startDate = today
            endDate = today
            Task { await loadSelectedDateRange() }
        case .yesterday:
            let yDay = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            startDate = yDay
            endDate = yDay
            Task { await loadSelectedDateRange() }
        case .last7Days:
            startDate = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            endDate = today
            Task { await loadSelectedDateRange() }
        case .last30Days:
            startDate = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            endDate = today
            Task { await loadSelectedDateRange() }
        case .custom:
            break
        }
    }

    @MainActor
    private func loadSelectedDateRange() async {
        guard network.isConnected else {
            store.errorMessage = "WMS 尚未连接，请连接后再查询所选日期。"
            return
        }
        await store.loadTasks(from: startDate, to: endDate, using: network)
    }

    private func matchesTaskType(_ record: WMSTaskRecord) -> Bool {
        switch selectedTaskType {
        case .all:
            return true
        case .productionIssue:
            return WMSTaskMonitorStore.isProductionIssue(record.taskType)
        case .pickingPutaway:
            return WMSTaskMonitorStore.isPickingPutaway(record.taskType)
        case .other:
            return WMSTaskMonitorStore.isOtherTaskType(record.taskType)
        }
    }

    private func copyToClipboard(_ text: String, label: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        copiedNotice = "已复制\(label)：\(text)"
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if copiedNotice.hasPrefix("已复制\(label)") {
                copiedNotice = ""
            }
        }
    }

    private func toggleExpandAll() {
        if expandedIDs.count >= sortedRecords.count && !sortedRecords.isEmpty {
            expandedIDs.removeAll()
        } else {
            expandedIDs = Set(sortedRecords.map(\.id))
            Task {
                _ = await store.prefetchDetailsConcurrently(
                    for: Array(sortedRecords.prefix(50)),
                    maxConcurrency: 6,
                    using: network
                )
            }
        }
    }

    // MARK: - Filter Bars
    private var dateFilterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日期范围")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TaskDatePreset.allCases) { preset in
                        let selected = selectedDatePreset == preset
                        Button {
                            applyDatePreset(preset)
                        } label: {
                            Text(preset.rawValue)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(selected ? Color.white : Color.blue)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background(selected ? Color.blue : Color.blue.opacity(0.08), in: Capsule())
                                .overlay(Capsule().stroke(selected ? Color.clear : Color.blue.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if selectedDatePreset == .custom {
                HStack(spacing: 8) {
                    Text("开始").foregroundStyle(.secondary)
                    DatePicker("开始", selection: $startDate, displayedComponents: .date)
                        .labelsHidden()
                    Text("结束").foregroundStyle(.secondary)
                    DatePicker("结束", selection: $endDate, displayedComponents: .date)
                        .labelsHidden()
                    Button("查询") {
                        Task { await loadSelectedDateRange() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(store.isLoading)
                }
                .font(.caption)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusFilterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("任务状态")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TaskStatusFilter.allCases) { filter in
                        let isSelected = selectedStatusFilter == filter
                        Button {
                            selectedStatusFilter = filter
                        } label: {
                            HStack(spacing: 5) {
                                Text(filter.rawValue)
                                Text("\(statusCount(for: filter))")
                                    .font(.caption2.bold())
                                    .opacity(isSelected ? 0.9 : 0.7)
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isSelected ? Color.white : Color.blue)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color.blue : Color.blue.opacity(0.08), in: Capsule())
                            .overlay(Capsule().stroke(isSelected ? Color.clear : Color.blue.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var taskTypeFilterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("任务类型")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TaskTypeFilter.allCases) { filter in
                        let isSelected = selectedTaskType == filter
                        Button {
                            selectedTaskType = filter
                        } label: {
                            HStack(spacing: 5) {
                                Text(filter.rawValue)
                                Text("\(typeCount(for: filter))")
                                    .font(.caption2.bold())
                                    .opacity(isSelected ? 0.9 : 0.7)
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isSelected ? Color.white : Color.blue)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color.blue : Color.blue.opacity(0.08), in: Capsule())
                            .overlay(Capsule().stroke(isSelected ? Color.clear : Color.blue.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading && store.records.isEmpty {
                    ProgressView("正在同步 WMS 任务列表…")
                } else if !store.errorMessage.isEmpty && store.records.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 44))
                            .foregroundStyle(.orange)
                        Text("任务获取失败")
                            .font(.headline)
                        Text(store.errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重新加载") {
                            Task { await store.loadUpdates(using: network) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else if store.records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("暂无任务记录")
                            .font(.headline)
                        Text("连接 WMS 后会自动同步任务历史；记录将持久保存在本地。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        // 顶部概览仪表盘
                        Section {
                            WMSTaskMetricsBar(
                                totalCount: dateFilteredRecords.count,
                                inProgressCount: statusCount(for: .inProgress),
                                pendingCount: statusCount(for: .pending),
                                completedCount: statusCount(for: .completed),
                                selectedFilter: $selectedStatusFilter
                            )

                            dateFilterBar
                            statusFilterBar
                            taskTypeFilterBar

                            HStack {
                                Text("显示 \(sortedRecords.count) / \(dateFilteredRecords.count) 条任务")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Menu {
                                    ForEach(TaskSortOption.allCases) { sort in
                                        Button {
                                            selectedSortOption = sort
                                        } label: {
                                            if selectedSortOption == sort {
                                                Label(sort.rawValue, systemImage: "checkmark")
                                            } else {
                                                Text(sort.rawValue)
                                            }
                                        }
                                    }
                                } label: {
                                    Label(selectedSortOption.rawValue, systemImage: "arrow.up.arrow.down")
                                        .font(.caption.weight(.medium))
                                }

                                Button {
                                    toggleExpandAll()
                                } label: {
                                    Text(expandedIDs.count >= sortedRecords.count && !sortedRecords.isEmpty ? "全部收起" : "全部展开")
                                        .font(.caption.weight(.medium))
                                }
                            }
                        }

                        // 任务列表
                        Section {
                            if sortedRecords.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                    Text("当前筛选条件下没有匹配的任务")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 28)
                            }

                            ForEach(sortedRecords) { record in
                                VStack(alignment: .leading, spacing: 9) {
                                    // 卡片头部
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 6) {
                                                Text(record.taskCode.isEmpty ? "任务" : record.taskCode)
                                                    .font(.headline)
                                                Button {
                                                    copyToClipboard(record.taskCode, label: "任务号")
                                                } label: {
                                                    Image(systemName: "doc.on.doc")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            Text(WMSTaskMonitorStore.displayDate(record.createdAt).isEmpty ? "-" : WMSTaskMonitorStore.displayDate(record.createdAt))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        WMSTaskStatusBadge(status: record.status)
                                    }

                                    // 信息行
                                    HStack(spacing: 12) {
                                        Label(record.taskTypeDisplay, systemImage: "tag")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.blue)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))

                                        if !record.taskMainID.isEmpty {
                                            Text("主编号: \(record.taskMainID)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }

                                    HStack {
                                        Text("站点：\(record.outStation.isEmpty ? "-" : record.outStation)")
                                        Spacer()
                                        Text("库位：\(record.startLocation.isEmpty ? "-" : record.startLocation)")
                                    }
                                    .font(.subheadline)

                                    if !record.trayCode.isEmpty {
                                        HStack {
                                            Text("托盘号：\(record.trayCode)")
                                                .font(.subheadline.weight(.medium))
                                            Spacer()
                                            Button {
                                                inspectingTray = record.trayCode
                                            } label: {
                                                HStack(spacing: 3) {
                                                    Image(systemName: "shippingbox")
                                                    Text("查托")
                                                }
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(Color.blue, in: Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }

                                    // 明细折叠/展开按钮
                                    Button {
                                        if expandedIDs.contains(record.id) {
                                            expandedIDs.remove(record.id)
                                        } else {
                                            expandedIDs.insert(record.id)
                                            Task { await store.loadDetails(for: record, using: network) }
                                        }
                                    } label: {
                                        Label(expandedIDs.contains(record.id) ? "收起物料明细" : "查看物料明细",
                                              systemImage: expandedIDs.contains(record.id) ? "chevron.up" : "chevron.down")
                                            .font(.subheadline.weight(.medium))
                                    }
                                    .padding(.top, 2)

                                    // 展开物料明细
                                    if expandedIDs.contains(record.id) {
                                        Divider()
                                        if store.detailLoadingIDs.contains(record.id) {
                                            ProgressView("正在读取物料明细…")
                                                .padding(.vertical, 4)
                                        } else if let error = store.detailErrors[record.id] {
                                            HStack {
                                                Text("明细读取失败：\(error)")
                                                    .font(.footnote).foregroundStyle(.red)
                                                Spacer()
                                                Button("重试") {
                                                    Task { await store.loadDetails(for: record, using: network) }
                                                }
                                                .font(.caption.bold())
                                            }
                                        } else if let details = store.detailRows[record.id] {
                                            if details.isEmpty {
                                                Text("该任务没有物料明细记录。")
                                                    .font(.footnote).foregroundStyle(.secondary)
                                            } else {
                                                ForEach(Array(details.enumerated()), id: \.offset) { index, row in
                                                    VStack(alignment: .leading, spacing: 6) {
                                                        Text("物料明细 #\(index + 1)")
                                                            .font(.subheadline.bold())
                                                        let entries = WMSTaskMonitorStore.detailEntries(row)
                                                        if entries.isEmpty {
                                                            Text("接口未返回可显示的物料字段。")
                                                                .font(.footnote).foregroundStyle(.secondary)
                                                        } else {
                                                            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                                                                HStack(alignment: .top, spacing: 8) {
                                                                    Text(entry.0 + "：")
                                                                        .foregroundStyle(.secondary)
                                                                        .frame(width: 76, alignment: .leading)
                                                                    Text(entry.1)
                                                                        .textSelection(.enabled)
                                                                    Spacer(minLength: 0)
                                                                }
                                                                .font(.footnote)
                                                            }
                                                        }
                                                    }
                                                    .padding(10)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 5)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await store.loadUpdates(using: network)
                    }
                    .searchable(text: $searchText, prompt: "搜索任务号 / 托盘 / 库位 / 物料")
                }
            }
            .navigationTitle("任务记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await store.loadUpdates(using: network) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)

                    Button {
                        showExportSheet = true
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.records.isEmpty)
                }
            }
            .overlay(alignment: .bottom) {
                if !copiedNotice.isEmpty {
                    Text(copiedNotice)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.85), in: Capsule())
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $showExportSheet) {
                WMSTaskExportSheet(
                    store: store,
                    network: network,
                    filteredRecords: sortedRecords,
                    allDateRecords: dateFilteredRecords
                )
            }
            .sheet(isPresented: Binding(
                get: { inspectingTray != nil },
                set: { if !$0 { inspectingTray = nil } }
            )) {
                if let tray = inspectingTray {
                    WMSTrayQuickSheet(tray: tray, network: network)
                }
            }
            .task {
                await store.loadUpdates(using: network)
            }
        }
    }
}
