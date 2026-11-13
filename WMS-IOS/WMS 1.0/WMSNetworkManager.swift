import Foundation
import Combine

// MARK: - Configuration

struct WMSNetworkConfiguration {
    var baseURL: URL
    var username: String
    var password: String
    var pdaUserID: String
    var warehouseOID: String
    var barkURL: String?

    static let defaultBaseURL = URL(string: "http://10.118.7.200")!

    // 与 Python 原脚本一致：PDA ID 只接受纯数字，否则使用脚本内置默认值。
    static let defaultPDAUserID = "491786087098744832"
    static let defaultWarehouseOID = "9099134087921669"

    init(
        baseURL: URL = Self.defaultBaseURL,
        username: String,
        password: String,
        pdaUserID: String,
        warehouseOID: String,
        barkURL: String? = nil
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.pdaUserID = Self.isDigitsOnly(pdaUserID)
            ? pdaUserID : Self.defaultPDAUserID
        self.warehouseOID = Self.isDigitsOnly(warehouseOID)
            ? warehouseOID : Self.defaultWarehouseOID
        self.barkURL = barkURL
    }

    private static func isDigitsOnly(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil
    }
}

// MARK: - Models

struct WMSMaterial: Identifiable {
    let id: String
    let materialName: String
    let materialNo: String
    let specification: String
    let unit: String
    let isDeleted: String
    let score: Double
    let raw: [String: AnyHashable]

    init(dictionary: [String: Any], score: Double = 0) {
        id = String(describing: dictionary["MaterialId"] ?? "")
        materialName = String(describing: dictionary["MaterialName"] ?? "")
        materialNo = String(describing: dictionary["MaterialNo"] ?? "")
        specification = String(describing: dictionary["Specification"] ?? "")
        unit = String(describing: dictionary["Unit"] ?? "")
        isDeleted = String(describing: dictionary["IsDel"] ?? "")
        self.score = score
        raw = dictionary.reduce(into: [:]) { result, pair in
            if let value = pair.value as? AnyHashable {
                result[pair.key] = value
            }
        }
    }
}

struct WMSStockOut: Identifiable {
    let id: String
    let number: String
    let status: Int?
    let raw: [String: Any]
}

struct WMSPdaTask: Identifiable {
    let id: String
    let materialName: String
    let materialNo: String
    let specification: String
    let plannedQuantity: Decimal
    let status: String
}

struct WMSAPIResult {
    let raw: Any
    let businessSuccess: Bool
    let message: String
}

struct WMSConnectionResult {
    let success: Bool
    let message: String
}

// MARK: - Errors

enum WMSNetworkError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int, String)
    case invalidJSON(String)
    case businessFailure(String)
    case sessionVerificationFailed
    case missingStockOutID
    case stockOutNotFound
    case invalidPdaResponse(String)
    case redirect(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "WMS 地址无效。"
        case .invalidResponse:
            return "服务器响应格式无效。"
        case .httpStatus(let code, let body):
            return "WMS HTTP \(code)：\(body)"
        case .invalidJSON(let body):
            return "WMS 没有返回有效 JSON：\(body)"
        case .businessFailure(let message):
            return "WMS 业务操作未成功：\(message)"
        case .sessionVerificationFailed:
            return "WMS 登录请求已发送，但只读会话验证未通过。"
        case .missingStockOutID:
            return "创建出库单后未能唯一确认 StockOutId，已停止后续操作。"
        case .stockOutNotFound:
            return "在 WMS 出库单列表中找不到指定单据。"
        case .invalidPdaResponse(let body):
            return "PDA 接口返回格式不符合预期：\(body)"
        case .redirect(let location):
            return "WMS 返回重定向，未将其视为成功：\(location)"
        }
    }
}

// MARK: - Redirect policy

/// 与 Python 脚本 allow_redirects=False 的原则一致。
private final class WMSNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Network Manager

@MainActor
final class WMSNetworkManager: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var connectionMessage = "尚未连接"
    @Published private(set) var isBusy = false

    private var configuration: WMSNetworkConfiguration
    private let session: URLSession
    private let timeout: TimeInterval = 20

    private let stockOutTypeID = "503753018307510272"
    private let stockOutTypeName = "成品出库单"
    private let outStation = 4
    private let targetTaskType = 13

    init(configuration: WMSNetworkConfiguration) {
        self.configuration = configuration

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = timeout
        sessionConfiguration.timeoutIntervalForResource = timeout
        sessionConfiguration.httpCookieStorage = HTTPCookieStorage.shared
        sessionConfiguration.httpShouldSetCookies = true
        sessionConfiguration.httpCookieAcceptPolicy = .always

        let delegate = WMSNoRedirectDelegate()
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    // MARK: URL / Encoding

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw WMSNetworkError.invalidURL
        }
        return url
    }

    private func formEncode(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.keys.sorted().map {
            URLQueryItem(name: $0, value: values[$0] ?? "")
        }
        return (components.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()
    }

    private func makeRequest(
        path: String,
        method: String,
        query: [String: String] = [:],
        form: [String: String]? = nil,
        json: [String: Any]? = nil,
        referer: String? = nil
    ) throws -> URLRequest {
        var components = URLComponents(url: try endpoint(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map {
                URLQueryItem(name: $0, value: query[$0] ?? "")
            }
        }

        guard let url = components.url else { throw WMSNetworkError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let form {
            request.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = formEncode(form)
        }

        return request
    }

    private func sendRaw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw WMSNetworkError.invalidResponse
        }

        if (300..<400).contains(http.statusCode) {
            let location = http.value(forHTTPHeaderField: "Location") ?? "(无 Location)"
            throw WMSNetworkError.redirect(location)
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WMSNetworkError.httpStatus(http.statusCode, String(body.prefix(500)))
        }
        return (data, http)
    }

    private func send(_ request: URLRequest) async throws -> (Any, HTTPURLResponse) {
        let (data, http) = try await sendRaw(request)
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return (object, http)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WMSNetworkError.invalidJSON(String(body.prefix(500)))
        }
    }

    private func rows(from object: Any) -> [[String: Any]] {
        if let list = object as? [[String: Any]] { return list }

        guard let dictionary = object as? [String: Any] else { return [] }

        for key in ["rows", "data", "Data"] {
            if let list = dictionary[key] as? [[String: Any]] { return list }
        }

        if dictionary["MaterialId"] != nil ||
            dictionary["StockOutId"] != nil ||
            dictionary["TaskMainId"] != nil {
            return [dictionary]
        }
        return []
    }

    private func businessSuccess(_ object: Any) -> (Bool, String) {
        guard let dictionary = object as? [String: Any] else {
            return (false, String(describing: object))
        }

        let raw = dictionary["Item1"]
        let success: Bool
        if let value = raw as? Bool {
            success = value
        } else {
            success = ["true", "1"].contains(
                String(describing: raw ?? "").lowercased()
            )
        }

        let message = String(describing: dictionary["Item2"] ?? "")
        return (success, message)
    }

    private func requireBusinessSuccess(_ object: Any) throws -> WMSAPIResult {
        let (success, message) = businessSuccess(object)
        guard success else {
            throw WMSNetworkError.businessFailure(
                message.isEmpty ? String(describing: object) : message
            )
        }
        return WMSAPIResult(raw: object, businessSuccess: true, message: message)
    }

    // MARK: Login and Session Verification

    /// 先 GET 登录页，再 POST JSON 登录，最后通过 Material/Search 验证 Cookie 会话。
    /// 不能仅凭登录接口 HTTP 200 就认定登录成功。
    func loginAndVerify() async throws {
        isBusy = true
        defer { isBusy = false }

        isConnected = false
        connectionMessage = "正在连接 WMS…"

        do {
            let pageRequest = try makeRequest(
                path: "/Login/Index",
                method: "GET"
            )
            _ = try await sendRaw(pageRequest)

            let loginRequest = try makeRequest(
                path: "/Login/CheckLoginAsync",
                method: "POST",
                json: [
                    "UserName": configuration.username,
                    "Password": configuration.password
                ],
                referer: absoluteURL("/Login/Index")
            )
            let (_, loginHTTP) = try await sendRaw(loginRequest)

            guard loginHTTP.statusCode == 200 else {
                throw WMSNetworkError.httpStatus(loginHTTP.statusCode, "登录请求失败")
            }

            let verifyRequest = try makeRequest(
                path: "/Material/Search",
                method: "GET",
                query: ["text": "胆碱"],
                referer: absoluteURL("/StockOut")
            )
            let (verifyObject, _) = try await send(verifyRequest)

            // Python 原脚本要求响应可解析为 JSON；有效 rows 可以为空。
            let isValidShape =
                verifyObject is [[String: Any]] ||
                (verifyObject as? [String: Any])?["rows"] is [[String: Any]] ||
                (verifyObject as? [String: Any])?["MaterialId"] != nil

            guard isValidShape else {
                throw WMSNetworkError.sessionVerificationFailed
            }

            isConnected = true
            connectionMessage = "WMS 已连接，会话验证成功"
        } catch {
            isConnected = false
            connectionMessage = error.localizedDescription
            throw error
        }
    }

    private func absoluteURL(_ path: String) -> String {
        URL(string: path, relativeTo: configuration.baseURL)?.absoluteString
            ?? configuration.baseURL.absoluteString
    }

    /// 兼容现有 ContentView 的登录调用；每次连接前刷新设置页保存的账号信息。
    func loginAndVerify(
        baseURL: String,
        username: String,
        password: String
    ) async -> WMSConnectionResult {
        let cleanURL = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? WMSNetworkConfiguration.defaultBaseURL

        let defaults = UserDefaults.standard
        configuration = WMSNetworkConfiguration(
            baseURL: cleanURL,
            username: username,
            password: password,
            pdaUserID: defaults.string(forKey: "wms.id") ?? configuration.pdaUserID,
            warehouseOID: defaults.string(forKey: "wms.oid") ?? configuration.warehouseOID,
            barkURL: defaults.string(forKey: "wms.barkURL")
        )

        do {
            try await loginAndVerify()
            return WMSConnectionResult(success: true, message: "WMS 登录成功，会话验证通过")
        } catch {
            return WMSConnectionResult(success: false, message: error.localizedDescription)
        }
    }

    // MARK: Material Search

    /// 将 WMS 返回的数字、字符串或空值统一转换为字符串。
    private func stringValue(_ value: Any?) -> String {
        guard let value = value, !(value is NSNull) else { return "" }
        return String(describing: value)
    }

    func searchMaterials(keyword: String) async throws -> [WMSMaterial] {
        let request = try makeRequest(
            path: "/Material/Search",
            method: "GET",
            query: ["text": keyword],
            referer: absoluteURL("/StockOut")
        )
        let (object, _) = try await send(request)
        let query = normalizeMaterialText(keyword)

        let materials = rows(from: object).compactMap { item -> WMSMaterial? in
            guard let name = item["MaterialName"] as? String, !name.isEmpty else {
                return nil
            }
            let materialID = stringValue(item["MaterialId"])
            guard !materialID.isEmpty else { return nil }

            return WMSMaterial(
                dictionary: item,
                score: materialSimilarityScore(query, name)
            )
        }

        // 与 Python 原脚本一致：按物料名称匹配分倒序排列，最多返回 10 条。
        return Array(materials.sorted { $0.score > $1.score }.prefix(10))
    }

    // MARK: Material candidate ranking

    private func normalizeMaterialText(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    /// 仅用于候选项排序，不会自动确认物料；规则对应 Python similarity_score。
    private func materialSimilarityScore(_ query: String, _ materialName: String) -> Double {
        let a = Array(normalizeMaterialText(query))
        let b = Array(normalizeMaterialText(materialName))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1.0 }

        let queryText = String(a)
        let nameText = String(b)
        if queryText.contains(nameText) { return 0.90 }
        if nameText.contains(queryText) { return 0.96 }

        let matches = matchingMaterialCharacters(a, b)
        return 2.0 * Double(matches) / Double(a.count + b.count)
    }

    /// SequenceMatcher 风格的最长连续匹配块比例，仅用于排序。
    private func matchingMaterialCharacters(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        var bestLength = 0
        var bestA = 0
        var bestB = 0
        var previous = [Int](repeating: 0, count: b.count + 1)

        for i in 0..<a.count {
            var current = [Int](repeating: 0, count: b.count + 1)
            for j in 0..<b.count where a[i] == b[j] {
                current[j + 1] = previous[j] + 1
                if current[j + 1] > bestLength {
                    bestLength = current[j + 1]
                    bestA = i - bestLength + 1
                    bestB = j - bestLength + 1
                }
            }
            previous = current
        }

        guard bestLength > 0 else { return 0 }
        let leftA = Array(a[..<bestA])
        let leftB = Array(b[..<bestB])
        let rightA = Array(a[(bestA + bestLength)...])
        let rightB = Array(b[(bestB + bestLength)...])

        return bestLength
            + matchingMaterialCharacters(leftA, leftB)
            + matchingMaterialCharacters(rightA, rightB)
    }

    // MARK: StockOut List / Create / Detail

    private func stockOutListPayload() -> [String: String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -120, to: now) ?? now
        let to = Calendar.current.date(byAdding: .day, value: 2, to: now) ?? now

        return [
            "limit": "100",
            "offset": "0",
            "sort": "CreateDate",
            "order": "desc",
            "search": "",
            "datemin": formatter.string(from: from),
            "datemax": formatter.string(from: to),
            "StockOutStatus": "",
            "StockOutType": ""
        ]
    }

    func fetchStockOutList() async throws -> [WMSStockOut] {
        let request = try makeRequest(
            path: "/StockOut/List",
            method: "POST",
            form: stockOutListPayload(),
            referer: absoluteURL("/StockOut")
        )
        let (object, _) = try await send(request)
        guard let dictionary = object as? [String: Any],
              let list = dictionary["rows"] as? [[String: Any]] else {
            throw WMSNetworkError.invalidJSON("StockOut/List 缺少 rows 数组")
        }

        return list.compactMap { row in
            guard let id = row["StockOutId"] else { return nil }
            let status = (row["StockOutStatus"] as? NSNumber)?.intValue
                ?? Int(String(describing: row["StockOutStatus"] ?? ""))
            return WMSStockOut(
                id: String(describing: id),
                number: String(describing: row["StockOutNo"] ?? ""),
                status: status,
                raw: row
            )
        }
    }

    func createStockOut() async throws -> WMSStockOut {
        let before = try await fetchStockOutList()
        let oldIDs = Set(before.map(\.id))

        let request = try makeRequest(
            path: "/StockOut/AddOrUpdate",
            method: "POST",
            form: [
                "id": "0",
                "CustomerId": "",
                "StockOutType": stockOutTypeID,
                "OrderNo": "",
                "Remark": ""
            ],
            referer: absoluteURL("/StockOut")
        )

        let (object, _) = try await send(request)
        _ = try requireBusinessSuccess(object)

        // 接口成功后只读查询新单据；不重复提交创建请求。
        for attempt in 0..<5 {
            let current = try await fetchStockOutList()
            let created = current.filter {
                !oldIDs.contains($0.id) &&
                String(describing: $0.raw["StockOutTypeId"] ?? "") == stockOutTypeID
            }

            if created.count == 1 { return created[0] }
            if created.count > 1 { throw WMSNetworkError.missingStockOutID }

            if attempt < 4 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        throw WMSNetworkError.missingStockOutID
    }

    func addStockOutDetail(
        stockOutID: String,
        materialID: String,
        planOutWeightKG: Decimal
    ) async throws -> WMSAPIResult {
        let request = try makeRequest(
            path: "/StockOut/AddOrUpdateD",
            method: "POST",
            form: [
                "id": "0",
                "StockOutId": stockOutID,
                "MaterialId": materialID,
                "PlanOutWeight": NSDecimalNumber(decimal: planOutWeightKG).stringValue,
                "Batch": "",
                "Remark": ""
            ],
            referer: absoluteURL("/StockOut")
        )
        let (object, _) = try await send(request)
        return try requireBusinessSuccess(object)
    }

    // MARK: Audit / Allot

    func auditStockOut(stockOutID: String) async throws -> WMSAPIResult {
        let request = try makeRequest(
            path: "/StockOut/Auditin",
            method: "GET",
            query: ["id": stockOutID],
            referer: absoluteURL("/StockOut")
        )
        let (object, _) = try await send(request)
        return try requireBusinessSuccess(object)
    }

    func allotStockOut(stockOutID: String) async throws -> WMSAPIResult {
        let request = try makeRequest(
            path: "/StockOut/AllotAll",
            method: "GET",
            query: [
                "id": stockOutID,
                "outStation": "4"
            ],
            referer: absoluteURL("/StockOut")
        )
        let (object, _) = try await send(request)
        return try requireBusinessSuccess(object)
    }

    // MARK: Task List / Detail

    private func taskListPayload(offset: Int = 0, from startDate: Date?, to endDate: Date = Date(), includeFutureBuffer: Bool = true) -> [String: String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"

        // 未显式传入起始日期时也按最近 90 天查询，避免意外退回旧版 7 天范围。
        let from = startDate ?? Calendar.current.date(byAdding: .day, value: -90, to: endDate) ?? endDate
        let to = Calendar.current.date(byAdding: .day, value: includeFutureBuffer ? 2 : 1, to: endDate) ?? endDate

        return [
            "limit": "100",
            "offset": String(offset),
            "sort": "CreateDate",
            "order": "desc",
            "search": "",
            "datemin": formatter.string(from: from),
            "datemax": formatter.string(from: to),
            "Status": "",
            "TaskType": ""
        ]
    }

    /// 兼容旧调用：默认查询最近 90 天。
    func fetchTasks(offset: Int = 0) async throws -> [[String: Any]] {
        try await fetchTasks(since: nil, offset: offset)
    }

    /// 从指定时间所在日期开始查询任务；调用方再按 CreateDate 精确过滤到时分秒。
    /// 首次历史补录由调用方传入 90 天前的时间，后续增量同步传入上次成功同步时间。
    func fetchTasks(since startDate: Date?, offset: Int = 0) async throws -> [[String: Any]] {
        let request = try makeRequest(
            path: "/Task/List",
            method: "POST",
            form: taskListPayload(offset: offset, from: startDate),
            referer: absoluteURL("/Task")
        )
        let (object, _) = try await send(request)
        guard let dictionary = object as? [String: Any],
              let list = dictionary["rows"] as? [[String: Any]] else {
            throw WMSNetworkError.invalidJSON("Task/List 缺少 rows 数组")
        }
        return list
    }

    /// 按界面选择的日期范围查询任务。WMS 的日期参数按“日”传递，
    /// 调用方仍需按 CreateDate 做精确的本地日期过滤。
    func fetchTasks(from startDate: Date, to endDate: Date, offset: Int = 0) async throws -> [[String: Any]] {
        let request = try makeRequest(
            path: "/Task/List",
            method: "POST",
            form: taskListPayload(
                offset: offset,
                from: startDate,
                to: endDate,
                includeFutureBuffer: false
            ),
            referer: absoluteURL("/Task")
        )
        let (object, _) = try await send(request)
        guard let dictionary = object as? [String: Any],
              let list = dictionary["rows"] as? [[String: Any]] else {
            throw WMSNetworkError.invalidJSON("Task/List 缺少 rows 数组")
        }
        return list
    }

    /// 状态刷新专用查询：每次刷新重新读取最近 N 天任务，而不是只读取新增任务。
    /// 这样 WMS 中已存在任务的 Status 变化也会随最新列表返回。
    func fetchRecentTasksForStatusRefresh(days: Int = 90, offset: Int = 0) async throws -> [[String: Any]] {
        let safeDays = max(1, days)
        let startDate = Calendar.current.date(
            byAdding: .day,
            value: -safeDays,
            to: Date()
        ) ?? Date()
        return try await fetchTasks(since: startDate, offset: offset)
    }

    func fetchTaskDetails(taskID: String) async throws -> [[String: Any]] {
        let request = try makeRequest(
            path: "/Task/ListDetail",
            method: "POST",
            form: ["pid": taskID],
            referer: absoluteURL("/Task")
        )
        let (object, _) = try await send(request)
        guard let dictionary = object as? [String: Any],
              let list = dictionary["rows"] as? [[String: Any]] else {
            throw WMSNetworkError.invalidJSON("Task/ListDetail 缺少 rows 数组")
        }
        return list
    }

    // MARK: PDA API

    /// 原 Python 代码将 args、UserName、WarehouseOid 同时放在 URL 查询串和 POST 表单中。
    /// 这里按原脚本保留该请求格式，后续应以实际抓包再次核实。
    private func pdaRequest(method: String, args: String) async throws -> Any {
        let values = [
            "args": args,
            "UserName": configuration.pdaUserID,
            "WarehouseOid": configuration.warehouseOID
        ]

        var components = URLComponents(
            url: try endpoint("/api/pda/\(method)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = values.keys.sorted().map {
            URLQueryItem(name: $0, value: values[$0] ?? "")
        }

        guard let url = components.url else { throw WMSNetworkError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(
            "application/x-www-form-urlencoded;charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.httpBody = formEncode(values)

        let (data, _) = try await sendRaw(request)
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return object
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func queryPdaOutboundTasks(tray: String) async throws -> [WMSPdaTask] {
        let result = try await pdaRequest(method: "GetOutTask", args: tray + ",")

        let list: [[String: Any]]
        if let direct = result as? [[String: Any]] {
            list = direct
        } else if let dictionary = result as? [String: Any],
                  let found = (dictionary["rows"] ?? dictionary["data"] ?? dictionary["Data"]) as? [[String: Any]] {
            list = found
        } else {
            throw WMSNetworkError.invalidPdaResponse(String(describing: result))
        }

        return try list.map { item in
            guard let detailID = item["TaskDetailId"],
                  let quantity = Decimal(string: String(describing: item["Qty"] ?? "")),
                  quantity > 0 else {
                throw WMSNetworkError.invalidPdaResponse("任务缺少有效 TaskDetailId 或 Qty")
            }

            return WMSPdaTask(
                id: String(describing: detailID),
                materialName: String(describing: item["MaterialName"] ?? ""),
                materialNo: String(describing: item["MaterialNo"] ?? ""),
                specification: String(describing: item["Specification"] ?? ""),
                plannedQuantity: quantity,
                status: String(describing: item["Status"] ?? "")
            )
        }
    }

    /// 真实出库写操作。调用前必须由界面展示计划数量、实际数量和剩余数量，
    /// 并要求用户进行二次确认；此方法本身不自动重试。
    func confirmPdaOutbound(tray: String, actualQuantities: [String: Decimal]) async throws -> Any {
        var detailString = ""

        for (detailID, quantity) in actualQuantities.sorted(by: { $0.key < $1.key }) {
            var sourceQuantity = quantity
            var integerQuantity = Decimal()
            NSDecimalRound(&integerQuantity, &sourceQuantity, 0, .down)

            guard detailID.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
                  quantity > 0,
                  quantity == integerQuantity else {
                throw WMSNetworkError.invalidPdaResponse("实际数量或 TaskDetailId 无效；实际数量必须为正整数")
            }
            detailString += "\(detailID)|\(NSDecimalNumber(decimal: quantity).stringValue);"
        }

        return try await pdaRequest(
            method: "OutTaskConfirm",
            args: tray + "," + detailString
        )
    }

    func pdaResponseIndicatesSuccess(_ result: Any) -> Bool {
        if let list = result as? [Any], let first = list.first {
            return ["true", "1"].contains(String(describing: first).lowercased())
        }
        if let dictionary = result as? [String: Any] {
            return (dictionary["Item1"] as? Bool) == true
        }
        if let string = result as? String {
            let first = string
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: CharacterSet(charactersIn: ",|;"))
                .first ?? ""
            return ["true", "1"].contains(first.lowercased())
        }
        return false
    }

    // MARK: Bark

    func sendBarkNotification(title: String, body: String) async throws -> Bool {
        guard let rawURL = configuration.barkURL,
              rawURL.hasPrefix("https://api.day.app/"),
              let url = URL(string: rawURL) else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": title,
            "body": body,
            "group": "WMS生产领料出库",
            "sound": "bell.caf"
        ])

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WMSNetworkError.invalidResponse
        }
        return http.statusCode == 200
    }
}
