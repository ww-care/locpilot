import Foundation

/// 经纬度。后端在 position / last_position / teleport 结果里都用这个形状。
public struct LatLon: Codable, Sendable, Equatable {
    public let lat: Double
    public let lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

/// 设备连接方式：USB 数据线 / Wi-Fi 无线。
public enum DeviceLink: String, Sendable, Equatable {
    case usb
    case wifi

    public init?(connection: String?) {
        switch connection?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "usb":
            self = .usb
        case "network", "wifi", "wi-fi":
            self = .wifi
        default:
            return nil
        }
    }

    /// 界面上显示的名称。
    public var label: String { self == .wifi ? "Wi-Fi" : "USB" }

    /// 手机图标右下角的角标符号。
    public var symbolName: String { self == .wifi ? "wifi" : "cable.connector" }
}

/// 后端状态快照。字段与 locpilot/core/session.py 的 snapshot() 一一对应，
/// 只声明原生界面真正用到的部分，其余忽略（后端新增字段不会破坏解析）。
public struct StatusSnapshot: Decodable, Sendable {
    public struct AppInfo: Decodable, Sendable {
        public let name: String
        public let version: String
    }
    public struct Device: Decodable, Sendable {
        public let name: String?
        public let udid: String?
        public let iosVersion: String?
        public let productType: String?
        public let connection: String?

        enum CodingKeys: String, CodingKey {
            case name, udid, connection
            case iosVersion = "ios_version"
            case productType = "product_type"
        }

        /// 当前连接方式（后端 device.connection：usb / network）。
        public var link: DeviceLink? { DeviceLink(connection: connection) }
    }
    public struct Engine: Decodable, Sendable {
        public let name: String?
        public let label: String?
        public let opened: Bool
        public let mode: String?
        public let device: Device?
    }

    /// 路线摘要（快照里不含 geometry，避免 SSE 每秒推几百个点）。
    public struct RouteState: Decodable, Sendable {
        public let loaded: Bool
        public let mode: String?
        public let provider: String?
        public let distance: Double?
        public let waypointCount: Int?
        public let warnings: [String]?

        enum CodingKeys: String, CodingKey {
            case loaded, mode, provider, distance, warnings
            case waypointCount = "waypoint_count"
        }
    }

    /// 回放状态（/api/status 与 /api/route/* 的结果同形）。
    public struct PlaybackState: Decodable, Sendable {
        public let state: String
        public let mode: String?
        public let speed: Double
        public let speedBase: Double?
        public let progress: Double
        public let distance: Double
        public let totalDistance: Double
        public let remainingDistance: Double?
        public let etaSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case state, mode, speed, progress, distance
            case speedBase = "speed_base"
            case totalDistance = "total_distance"
            case remainingDistance = "remaining_distance"
            case etaSeconds = "eta_seconds"
        }

        public init(state: String, mode: String? = nil, speed: Double = 0,
                    speedBase: Double? = nil, progress: Double = 0, distance: Double = 0,
                    totalDistance: Double = 0, remainingDistance: Double? = nil,
                    etaSeconds: Double? = nil) {
            self.state = state
            self.mode = mode
            self.speed = speed
            self.speedBase = speedBase
            self.progress = progress
            self.distance = distance
            self.totalDistance = totalDistance
            self.remainingDistance = remainingDistance
            self.etaSeconds = etaSeconds
        }
    }

    public let app: AppInfo
    public let engine: Engine
    public let position: LatLon?
    public let error: String?
    public let route: RouteState?
    public let playback: PlaybackState?
}

/// /api/route 的规划结果（geometry 为 [[lat, lon], ...]，WGS-84）。
public struct RoutePlanResult: Decodable, Sendable {
    public let loaded: Bool
    public let mode: String?
    public let provider: String?
    public let distance: Double?
    public let duration: Double?
    public let geometry: [[Double]]
    public let warnings: [String]?
    public let routed: Bool?

    public init(loaded: Bool = true, mode: String? = nil, provider: String? = nil,
                distance: Double? = nil, duration: Double? = nil,
                geometry: [[Double]] = [], warnings: [String]? = nil, routed: Bool? = nil) {
        self.loaded = loaded
        self.mode = mode
        self.provider = provider
        self.distance = distance
        self.duration = duration
        self.geometry = geometry
        self.warnings = warnings
        self.routed = routed
    }

    public var coordinates: [LatLon] {
        geometry.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return LatLon(lat: pair[0], lon: pair[1])
        }
    }
}

/// 与后端 REST + SSE 的唯一通道。UI 只依赖这一层，方便单测。
public actor EngineClient {
    public struct TeleportResult: Decodable, Sendable {
        public let position: LatLon
        public let historyId: String?

        enum CodingKeys: String, CodingKey {
            case position
            case historyId = "history_id"
        }
    }

    public struct ConnectResult: Decodable, Sendable {
        public let engine: String
        public let device: StatusSnapshot.Device?
        /// 后端返回的是字符串数组（例如"libimobiledevice 无法处理 iOS 27 设备，已自动改用 …"）。
        public let notes: [String]?
    }

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - 请求

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw EngineError.badURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request(path, method: method, body: body))
        guard let http = response as? HTTPURLResponse else { throw EngineError.transport("无 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else {
            // 后端错误体是 {"ok": false, "error": "…"}：ok 是 Bool，
            // 用 [String: String] 整体解码会失败，用户就只能看到 "HTTP 503"。
            let message = (try? JSONDecoder().decode(BackendErrorBody.self, from: data))?.error
            throw EngineError.backend(message ?? "HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func health() async throws -> Bool {
        struct Health: Decodable { let status: String? }
        let result = try await send("api/health", as: Health.self)
        return result.status == "ok" || result.status == nil
    }

    public func status() async throws -> StatusSnapshot {
        try await send("api/status", as: StatusSnapshot.self)
    }

    public func connect(engine: String = "auto") async throws -> ConnectResult {
        try await send("api/connect", method: "POST", body: ["engine": engine], as: ConnectResult.self)
    }

    public func disconnect() async throws {
        _ = try await send("api/disconnect", method: "POST", body: [:], as: EmptyResponse.self)
    }

    @discardableResult
    public func teleport(lat: Double, lon: Double) async throws -> TeleportResult {
        try await send("api/teleport", method: "POST", body: ["lat": lat, "lon": lon], as: TeleportResult.self)
    }

    /// 逆地理编码：/api/reverse 返回 {"result": {"name":…, "display_name":…}}，查不到时 result 为 null。
    public func reverse(lat: Double, lon: Double) async throws -> Place? {
        struct Envelope: Decodable { let result: Place? }
        let envelope = try await send("api/reverse?lat=\(lat)&lon=\(lon)", as: Envelope.self)
        return envelope.result
    }

    public func clear() async throws {
        _ = try await send("api/clear", method: "POST", body: [:], as: EmptyResponse.self)
    }

    // MARK: - 路线

    /// 规划路线。points 为 WGS-84；mode 见 TravelMode；provider=auto 时后端按区域选择。
    public func planRoute(points: [LatLon], mode: String, provider: String = "auto",
                          jitter: Double? = nil, seed: Int? = nil) async throws -> RoutePlanResult {
        var body: [String: Any] = [
            "points": points.map { [$0.lat, $0.lon] },
            "mode": mode,
            "provider": provider,
        ]
        if let jitter { body["jitter"] = jitter }
        if let seed { body["seed"] = seed }
        return try await send("api/route", method: "POST", body: body, as: RoutePlanResult.self)
    }

    public func startRoute() async throws -> StatusSnapshot.PlaybackState {
        try await send("api/route/start", method: "POST", body: [:], as: StatusSnapshot.PlaybackState.self)
    }

    public func pauseRoute() async throws -> StatusSnapshot.PlaybackState {
        try await send("api/route/pause", method: "POST", body: [:], as: StatusSnapshot.PlaybackState.self)
    }

    public func resumeRoute() async throws -> StatusSnapshot.PlaybackState {
        try await send("api/route/resume", method: "POST", body: [:], as: StatusSnapshot.PlaybackState.self)
    }

    public func stopRoute() async throws -> StatusSnapshot.PlaybackState {
        try await send("api/route/stop", method: "POST", body: [:], as: StatusSnapshot.PlaybackState.self)
    }

    // MARK: - 事件流

    /// 订阅 /api/events（text/event-stream）。后端每次状态变化推一帧 snapshot。
    /// 用 AsyncStream 暴露，调用方只关心快照；连接断开时流自然结束，由上层决定是否重连。
    public nonisolated func events() -> AsyncStream<StatusSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                var attempt = 0
                while !Task.isCancelled {
                    var receivedEvent = false
                    do {
                        let request = try await self.request("api/events")
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                            throw EngineError.transport("事件流返回 \(String(describing: response))")
                        }
                        // 关键：Foundation 的 bytes.lines **不会产出空行**，而 SSE 正是用空行分帧，
                        // 靠它做判定会让事件流永远没有输出。这里按字节自己切行，保留空行。
                        // 同时按行累积字节再整体 UTF-8 解码，避免多字节中文被逐字节拆坏。
                        var lineBytes: [UInt8] = []
                        var payload = ""
                        for try await byte in bytes {
                            if Task.isCancelled { break }
                            if byte == 0x0A {
                                let line = String(decoding: lineBytes, as: UTF8.self)
                                lineBytes.removeAll(keepingCapacity: true)
                                if line.isEmpty {
                                    // 空行 = 一帧结束
                                    if !payload.isEmpty {
                                        if let data = payload.data(using: .utf8),
                                           let snapshot = try? JSONDecoder().decode(StatusSnapshot.self, from: data) {
                                            continuation.yield(snapshot)
                                            receivedEvent = true
                                        }
                                        payload = ""
                                    }
                                } else if line.hasPrefix("data:") {
                                    payload += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                                }
                            } else if byte != 0x0D {
                                lineBytes.append(byte)
                            }
                        }
                        // 读循环正常结束（后端关闭了事件流）同样算断流：统一走下面的退避，
                        // 否则后端重启/空闲断流时就会变成零延迟热循环，白白烧 CPU。
                    } catch {
                        // 建连失败或流内异常：统一走下面的退避
                    }
                    if Task.isCancelled { break }
                    // 收到过事件 → 从短退避重新开始；一次都没收到 → 递增退避（上限 3s）
                    attempt = receivedEvent ? 1 : attempt + 1
                    let delay = min(Double(attempt) * 0.5, 3.0)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension EngineClient: RouteServicing {}

public struct EmptyResponse: Decodable, Sendable {}

/// /api/reverse 的地点信息（字段来自 Nominatim）。
public struct Place: Decodable, Sendable {
    public let name: String?
    public let displayName: String?
    /// 后端按"原生地图落针"的优先级挑好的短名（POI → 建筑 → 门牌+道路 → 街区 → 城市）。
    public let label: String?

    enum CodingKeys: String, CodingKey {
        case name
        case label
        case displayName = "display_name"
    }

    /// 落针标签：优先后端挑好的短名，其次 name，最后才用完整地址。
    public var shortLabel: String? { label ?? name ?? displayName }
}

/// 后端错误体：{"ok": false, "error": "…", "retryable": …, "code": …}
struct BackendErrorBody: Decodable {
    let error: String?
}

public enum EngineError: LocalizedError {
    case badURL(String)
    case transport(String)
    case backend(String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let path): return "无效地址：" + path
        case .transport(let message): return message
        case .backend(let message): return message
        }
    }
}
