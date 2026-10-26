import Foundation

/// 路线服务抽象：便于在测试里替换真实的 EngineClient。
public protocol RouteServicing {
    func planRoute(points: [LatLon], mode: String, provider: String,
                   jitter: Double?, seed: Int?) async throws -> RoutePlanResult
    func startRoute() async throws -> StatusSnapshot.PlaybackState
    func pauseRoute() async throws -> StatusSnapshot.PlaybackState
    func resumeRoute() async throws -> StatusSnapshot.PlaybackState
    func stopRoute() async throws -> StatusSnapshot.PlaybackState
}

/// 六种交通方式。rawValue 与后端 `mode` 一致；baseSpeed 只用于界面展示（后端才是权威）。
public enum TravelMode: String, CaseIterable, Identifiable, Sendable, Equatable {
    case walk, run, cycle, ebike, drive, highway

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .walk: return "步行"
        case .run: return "跑步"
        case .cycle: return "自行车"
        case .ebike: return "电动自行车"
        case .drive: return "开车"
        case .highway: return "高速"
        }
    }

    public var systemImage: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .ebike: return "scooter"
        case .drive: return "car.fill"
        case .highway: return "speedometer"
        }
    }

    /// 与后端 config.MODE_PROFILES 的 base 对齐（仅用于 UI 估算与展示）。
    public var baseSpeed: Double {
        switch self {
        case .walk: return 1.3
        case .run: return 3.0
        case .cycle: return 4.8
        case .ebike: return 6.2
        case .drive: return 12.0
        case .highway: return 28.0
        }
    }
}

public enum RouteSessionError: LocalizedError {
    case emptyPlan

    public var errorDescription: String? {
        switch self {
        case .emptyPlan: return "路线服务没有返回有效几何"
        }
    }
}

/// 路线模式状态机：点编辑 → 规划（防抖 + 代次）→ 播放。
///
/// 设计约束：
/// * 所有网络调用都经过 `RouteServicing`，测试可注入假实现；
/// * 规划请求带代次令牌，旧结果不会覆盖新结果；
/// * 播放中禁止编辑（isEditingAllowed = false）；
/// * 回放进度由 SSE 快照驱动（apply(playback:)），不轮询。
@MainActor
public final class RouteSession: ObservableObject {
    public enum Phase: Equatable {
        case editing        // 点不够 / 刚清空
        case planning       // 请求中（含防抖后的等待）
        case planned        // 有规划结果，可播放
        case failed(String) // 规划失败，可重试
        case playing
        case paused
        case stopped        // 中途停止：设备停在当前位置，进度保留
        case finished
    }

    public struct RoutePoint: Identifiable, Equatable {
        public let id: UUID
        public var lat: Double
        public var lon: Double

        public init(id: UUID = UUID(), lat: Double, lon: Double) {
            self.id = id
            self.lat = lat
            self.lon = lon
        }
    }

    public struct Plan: Equatable {
        public let geometry: [LatLon]
        public let distance: Double
        public let duration: Double?
        public let provider: String
        public let mode: TravelMode
        public let warnings: [String]
    }

    public static let maxPoints = 7

    @Published public private(set) var points: [RoutePoint] = []
    @Published public private(set) var plan: Plan?
    @Published public private(set) var phase: Phase = .editing
    @Published public private(set) var mode: TravelMode = .walk
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var currentSpeed: Double = 0
    @Published public private(set) var etaSeconds: Double?
    /// 每次规划成功 +1，供界面触发"取景到整条路线"。
    @Published public private(set) var planRevision = 0
    @Published public var jitter: Double = 0.12

    public let maxPoints = 7

    private let client: RouteServicing
    private let debounce: TimeInterval
    private var planTask: Task<Void, Never>?
    private var generation = 0

    public init(client: RouteServicing, debounce: TimeInterval = 0.4) {
        self.client = client
        self.debounce = debounce
    }

    // MARK: - 编辑

    public var isEditingAllowed: Bool {
        switch phase {
        case .playing, .paused: return false
        default: return true
        }
    }

    public var canStart: Bool {
        plan != nil && phase != .playing && phase != .planning
    }

    @discardableResult
    public func addPoint(lat: Double, lon: Double) -> Bool {
        guard isEditingAllowed, points.count < maxPoints else { return false }
        points.append(RoutePoint(lat: lat, lon: lon))
        schedulePlan()
        return true
    }

    public func movePoint(_ id: UUID, lat: Double, lon: Double) {
        guard isEditingAllowed, let index = points.firstIndex(where: { $0.id == id }) else { return }
        points[index].lat = lat
        points[index].lon = lon
        schedulePlan()
    }

    public func removePoint(_ id: UUID) {
        guard isEditingAllowed else { return }
        points.removeAll { $0.id == id }
        schedulePlan()
    }

    public func clear() {
        guard isEditingAllowed else { return }
        points.removeAll()
        planTask?.cancel()
        generation += 1
        plan = nil
        progress = 0
        currentSpeed = 0
        etaSeconds = nil
        phase = .editing
    }

    public func setMode(_ newMode: TravelMode) {
        guard isEditingAllowed, newMode != mode else { return }
        mode = newMode
        schedulePlan()
    }

    // MARK: - 规划

    /// 点集变化后延迟规划（防抖），旧请求会被代次令牌丢弃。
    public func schedulePlan() {
        planTask?.cancel()
        guard points.count >= 2 else {
            plan = nil
            progress = 0
            currentSpeed = 0
            etaSeconds = nil
            phase = .editing
            return
        }
        generation += 1
        let token = generation
        let delay = debounce
        phase = .planning
        planTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.runPlan(token: token)
        }
    }

    /// 立即规划（重试按钮 / 测试用）。
    public func planNow() async {
        planTask?.cancel()
        guard points.count >= 2 else {
            plan = nil
            phase = .editing
            return
        }
        generation += 1
        await runPlan(token: generation)
    }

    private func runPlan(token: Int) async {
        guard token == generation else { return }
        phase = .planning
        let snapshot = points.map { LatLon(lat: $0.lat, lon: $0.lon) }
        do {
            let result = try await client.planRoute(
                points: snapshot, mode: mode.rawValue, provider: "auto",
                jitter: jitter, seed: nil)
            guard token == generation else { return }
            let geometry = result.coordinates
            guard geometry.count >= 2 else { throw RouteSessionError.emptyPlan }
            plan = Plan(
                geometry: geometry,
                distance: result.distance ?? 0,
                duration: result.duration,
                provider: result.provider ?? "auto",
                mode: mode,
                warnings: result.warnings ?? [])
            progress = 0
            currentSpeed = 0
            if let duration = result.duration {
                etaSeconds = duration
            } else if mode.baseSpeed > 0 {
                etaSeconds = (result.distance ?? 0) / mode.baseSpeed
            } else {
                etaSeconds = nil
            }
            planRevision += 1
            phase = .planned
        } catch {
            guard token == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - 播放

    public func startPlayback() async {
        guard plan != nil else { return }
        do {
            let state = try await client.startRoute()
            apply(playback: state)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func pausePlayback() async {
        do {
            let state = try await client.pauseRoute()
            apply(playback: state)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func resumePlayback() async {
        do {
            let state = try await client.resumeRoute()
            apply(playback: state)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func stopPlayback() async {
        do {
            // 后端保留当前位置与进度：设备停在走到的地方，再次开始从当前位置继续。
            let state = try await client.stopRoute()
            apply(playback: state)
            currentSpeed = 0
            etaSeconds = state.etaSeconds ?? plan?.duration
            if plan == nil {
                phase = .editing
            } else if progress > 0.001 {
                phase = .stopped
            } else {
                phase = .planned
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - 事件流同步

    /// SSE 快照到达时调用：进度/速度/阶段都以后端为准。
    public func apply(route: StatusSnapshot.RouteState?, playback: StatusSnapshot.PlaybackState?) {
        guard let playback else { return }
        apply(playback: playback)
    }

    private func apply(playback state: StatusSnapshot.PlaybackState) {
        progress = min(max(state.progress, 0), 1)
        currentSpeed = state.speed
        etaSeconds = state.etaSeconds
        switch state.state {
        case "playing":
            phase = .playing
        case "paused":
            phase = .paused
        case "finished":
            phase = .finished
        default:
            guard plan != nil else { phase = .editing; return }
            // 规划中/失败时不要被 idle 快照冲掉状态
            if case .planning = phase { return }
            if case .failed = phase { return }
            currentSpeed = 0
            // 中途停止：后端保留进度，显示为「已停止」而不是回到 0%
            phase = progress > 0.001 ? .stopped : .planned
        }
    }
}

// MARK: - 展示辅助

public extension RouteSession {
    var pointCount: Int { points.count }

    var distanceText: String {
        guard let plan else { return "—" }
        if plan.distance >= 1000 {
            return String(format: "%.2f km", plan.distance / 1000)
        }
        return String(format: "%.0f m", plan.distance)
    }

    var etaText: String {
        guard let etaSeconds, etaSeconds.isFinite, etaSeconds > 0 else { return "—" }
        let total = Int(etaSeconds.rounded())
        if total >= 3600 {
            return String(format: "%d 小时 %d 分", total / 3600, (total % 3600) / 60)
        }
        if total >= 60 {
            return String(format: "%d 分 %d 秒", total / 60, total % 60)
        }
        return "\(total) 秒"
    }
}
