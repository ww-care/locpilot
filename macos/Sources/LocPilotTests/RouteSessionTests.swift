import Foundation
import LocPilotKit

/// RouteSession 的假客户端：可配置成功/失败、延时，并记录调用次数。
actor FakeRouteClient: RouteServicing {
    enum Behavior { case success, failure }

    private var behavior: Behavior = .success
    private var delay: TimeInterval = 0
    private(set) var planCalls = 0
    private(set) var startCalls = 0
    private(set) var pauseCalls = 0
    private(set) var resumeCalls = 0
    private(set) var stopCalls = 0
    private(set) var lastMode: String?
    private(set) var lastProvider: String?

    func setBehavior(_ value: Behavior) { behavior = value }
    func setDelay(_ value: TimeInterval) { delay = value }
    func planCount() -> Int { planCalls }
    func startCount() -> Int { startCalls }
    func pauseCount() -> Int { pauseCalls }
    func resumeCount() -> Int { resumeCalls }
    func stopCount() -> Int { stopCalls }
    func modeUsed() -> String? { lastMode }
    func providerUsed() -> String? { lastProvider }

    func planRoute(points: [LatLon], mode: String, provider: String,
                   jitter: Double?, seed: Int?) async throws -> RoutePlanResult {
        planCalls += 1
        lastMode = mode
        lastProvider = provider
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if case .failure = behavior {
            throw EngineError.backend("模拟规划失败")
        }
        return RoutePlanResult(
            loaded: true,
            mode: mode,
            provider: "mock",
            distance: 1000,
            duration: 100,
            geometry: [[31.2304, 121.4737], [31.2454, 121.4987]],
            warnings: [],
            routed: true)
    }

    func startRoute() async throws -> StatusSnapshot.PlaybackState {
        startCalls += 1
        return StatusSnapshot.PlaybackState(state: "playing", mode: lastMode, speed: 1.3,
                                            speedBase: 1.3, progress: 0.1, distance: 100,
                                            totalDistance: 1000, etaSeconds: 90)
    }

    func pauseRoute() async throws -> StatusSnapshot.PlaybackState {
        pauseCalls += 1
        return StatusSnapshot.PlaybackState(state: "paused", mode: lastMode, speed: 1.3,
                                            speedBase: 1.3, progress: 0.2, distance: 200,
                                            totalDistance: 1000, etaSeconds: 80)
    }

    func resumeRoute() async throws -> StatusSnapshot.PlaybackState {
        resumeCalls += 1
        return StatusSnapshot.PlaybackState(state: "playing", mode: lastMode, speed: 1.3,
                                            speedBase: 1.3, progress: 0.2, distance: 200,
                                            totalDistance: 1000, etaSeconds: 80)
    }

    func stopRoute() async throws -> StatusSnapshot.PlaybackState {
        stopCalls += 1
        // 与后端语义一致：停止保留当前位置与进度
        return StatusSnapshot.PlaybackState(state: "idle", mode: lastMode, speed: 0,
                                            speedBase: 1.3, progress: 0.2, distance: 200,
                                            totalDistance: 1000, etaSeconds: 80)
    }
}

func registerRouteSessionTests() {
    testMainActorAsync("RouteSession：最多 7 个点") {
        let client = FakeRouteClient()
        let session = RouteSession(client: client, debounce: 0.01)
        for index in 0..<7 {
            let added = session.addPoint(lat: 31.2 + Double(index) * 0.001, lon: 121.4)
            expect(added, "第 \(index + 1) 个点应添加成功")
        }
        expect(!session.addPoint(lat: 32, lon: 122), "第 8 个点应被拒绝")
        expectEqual(session.pointCount, 7, "点数")
    }

    testMainActorAsync("RouteSession：规划成功进入 planned") {
        let client = FakeRouteClient()
        let session = RouteSession(client: client, debounce: 0.01)
        session.addPoint(lat: 31.2304, lon: 121.4737)
        session.addPoint(lat: 31.2454, lon: 121.4987)
        await session.planNow()
        expectEqual(session.phase, .planned, "phase")
        expect(session.plan != nil, "plan 应存在")
        expectEqual(session.plan?.provider ?? "", "mock", "provider")
        expectEqual(session.plan?.geometry.count ?? 0, 2, "几何点数")
        expectEqual(session.planRevision, 1, "planRevision")
        let modeUsed = await client.modeUsed()
        expectEqual(modeUsed ?? "", "walk", "传给后端的 mode")
    }

    testMainActorAsync("RouteSession：规划失败可重试") {
        let client = FakeRouteClient()
        await client.setBehavior(.failure)
        let session = RouteSession(client: client, debounce: 0.01)
        session.addPoint(lat: 31.2304, lon: 121.4737)
        session.addPoint(lat: 31.2454, lon: 121.4987)
        await session.planNow()
        if case .failed = session.phase {
            // 预期
        } else {
            expect(false, "应为 failed，实际 \(session.phase)")
        }

        await client.setBehavior(.success)
        await session.planNow()
        expectEqual(session.phase, .planned, "重试后应为 planned")
    }

    testMainActorAsync("RouteSession：防抖只发一次规划请求") {
        let client = FakeRouteClient()
        let session = RouteSession(client: client, debounce: 0.01)
        session.addPoint(lat: 31.2304, lon: 121.4737)
        session.addPoint(lat: 31.2454, lon: 121.4987)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let calls = await client.planCount()
        expectEqual(calls, 1, "连续改动应合并为一次规划")
    }

    testMainActorAsync("RouteSession：切换方式会重规划") {
        let client = FakeRouteClient()
        let session = RouteSession(client: client, debounce: 0.01)
        session.addPoint(lat: 31.2304, lon: 121.4737)
        session.addPoint(lat: 31.2454, lon: 121.4987)
        await session.planNow()
        session.setMode(.cycle)
        await session.planNow()
        expectEqual(session.plan?.mode, .cycle, "plan.mode 应跟随切换")
        let modeUsed = await client.modeUsed()
        expectEqual(modeUsed ?? "", "cycle", "传给后端的 mode")
    }

    testMainActorAsync("RouteSession：播放/暂停/继续/停止状态") {
        let client = FakeRouteClient()
        let session = RouteSession(client: client, debounce: 0.01)
        session.addPoint(lat: 31.2304, lon: 121.4737)
        session.addPoint(lat: 31.2454, lon: 121.4987)
        await session.planNow()

        await session.startPlayback()
        expectEqual(session.phase, .playing, "start 后")
        expect(!session.isEditingAllowed, "播放中应禁止编辑")

        await session.pausePlayback()
        expectEqual(session.phase, .paused, "pause 后")

        await session.resumePlayback()
        expectEqual(session.phase, .playing, "resume 后")

        await session.stopPlayback()
        expectEqual(session.phase, .stopped, "stop 后应为 stopped（设备停在当前位置）")
        expectClose(session.progress, 0.2, tolerance: 1e-9, "stop 后进度保留")
        expectEqual(session.currentSpeed, 0, "停止后当前速度归零")
        let starts = await client.startCount()
        expectEqual(starts, 1, "start 调用次数")

        // 停止后「继续」= 再次 start，从当前位置续播
        await session.startPlayback()
        expectEqual(session.phase, .playing, "继续后")
        let startsAfter = await client.startCount()
        expectEqual(startsAfter, 2, "继续应再次调用 start")
    }

    testMainActorAsync("RouteSession：SSE 快照驱动进度") {
        let client = FakeRouteClient()
        let session = RouteSession(client: client, debounce: 0.01)
        session.addPoint(lat: 31.2304, lon: 121.4737)
        session.addPoint(lat: 31.2454, lon: 121.4987)
        await session.planNow()
        let playback = StatusSnapshot.PlaybackState(
            state: "playing", mode: "walk", speed: 1.4, speedBase: 1.3,
            progress: 0.5, distance: 500, totalDistance: 1000, etaSeconds: 40)
        session.apply(route: nil, playback: playback)
        expectEqual(session.phase, .playing, "SSE 播放状态")
        expectClose(session.progress, 0.5, tolerance: 1e-9, "进度")
        expectClose(session.currentSpeed, 1.4, tolerance: 1e-9, "当前速度")
    }
}
