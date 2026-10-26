import LocPilotKit
import SwiftUI

/// 传送模式下的入口：一个小胶囊，点一下进入路线模式。
struct RouteEntryButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button {
            state.toggleMapMode()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                Text("路线")
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .modifier(GlassChrome(shape: Capsule()))
        .help("路线模式：在地图上选点并规划")
    }
}

/// 路线模式底部面板：交通方式、点数、规划状态、进度、播放控制。
struct RoutePanel: View {
    @EnvironmentObject var state: AppState

    private var route: RouteSession? { state.routeSession }

    var body: some View {
        if let route {
            VStack(spacing: 10) {
                header(route)
                content(route)
                if route.plan != nil {
                    progress(route)
                }
                controls(route)
            }
            .padding(12)
            .frame(width: 372)
            .modifier(GlassChrome(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))
        }
    }

    // MARK: - 头

    private func header(_ route: RouteSession) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(TravelMode.allCases) { mode in
                    Button {
                        state.routeSetMode(mode)
                    } label: {
                        Label(mode.title, systemImage: mode.systemImage)
                    }
                }
            } label: {
                Label(route.mode.title, systemImage: route.mode.systemImage)
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!route.isEditingAllowed)

            Spacer(minLength: 4)

            Text("\(route.pointCount)/\(route.maxPoints) 点")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button {
                state.toggleMapMode()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("退出路线模式")
        }
    }

    // MARK: - 状态

    @ViewBuilder
    private func content(_ route: RouteSession) -> some View {
        switch route.phase {
        case .editing:
            hint("点击地图添加起点和终点")
        case .planning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("规划中…").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        case .planned, .playing, .paused, .stopped, .finished:
            if let plan = route.plan {
                HStack(spacing: 16) {
                    metric(route.distanceText, "距离")
                    metric(route.etaText, "预计")
                    if route.phase == .playing || route.phase == .paused || route.currentSpeed > 0 {
                        metric(String(format: "%.1f km/h", route.currentSpeed * 3.6), "当前速度")
                    }
                    Spacer(minLength: 0)
                }
                if route.phase == .stopped {
                    hint("已停止：设备停在当前位置，点「继续」接着走")
                }
                if !plan.warnings.isEmpty {
                    Text(plan.warnings.joined(separator: "；"))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 进度

    private func progress(_ route: RouteSession) -> some View {
        VStack(spacing: 4) {
            ProgressView(value: min(max(route.progress, 0), 1))
                .progressViewStyle(.linear)
            HStack {
                Text("\(Int((route.progress * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if let plan = route.plan, plan.distance > 0 {
                    Text(String(format: "%.0f / %.0f m", route.progress * plan.distance, plan.distance))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 播放控制

    @ViewBuilder
    private func controls(_ route: RouteSession) -> some View {
        HStack(spacing: 8) {
            switch route.phase {
            case .planning:
                EmptyView()
            case .failed:
                Button("重试") { state.routeRetry() }
            case .playing:
                Button { state.routePause() } label: { Label("暂停", systemImage: "pause.fill") }
                Button { state.routeStop() } label: { Label("停止", systemImage: "stop.fill") }
            case .paused:
                Button { state.routeResume() } label: { Label("继续", systemImage: "play.fill") }
                Button { state.routeStop() } label: { Label("停止", systemImage: "stop.fill") }
            case .stopped:
                Button { state.routeStart() } label: { Label("继续", systemImage: "play.fill") }
                Button { state.routeClear() } label: { Label("清空", systemImage: "trash") }
            case .finished:
                Button { state.routeStart() } label: { Label("重播", systemImage: "arrow.counterclockwise") }
                Button { state.routeStop() } label: { Label("停止", systemImage: "stop.fill") }
            default:
                Button { state.routeStart() } label: { Label("开始", systemImage: "play.fill") }
                    .disabled(!route.canStart)
                Button { state.routeClear() } label: { Label("清空", systemImage: "trash") }
                Spacer()
                if route.pointCount < 2 {
                    Text("至少 2 个点").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .controlSize(.small)
    }
}
