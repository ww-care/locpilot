import LocPilotKit
import MapKit
import SwiftUI

/// 唯一主界面：Apple 地图铺满窗口，点击即改定位，右上控件簇，左下坐标读数。
/// 路线模式下：点击加点、画路线、底部路线面板。
struct MapScreen: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        MapReader { proxy in
            Map(position: $state.camera, interactionModes: [.pan, .zoom]) {
                if state.mapMode == .teleport, let marker = state.marker {
                    // anchor: .bottom = 组件的底边中心（也就是针尖）钉在坐标上，
                    // 所有缩放/旋转都以它为轴，保证针尖不动（规格 §3 / §13）。
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lon), anchor: .bottom) {
                        MapLocationPin(animator: state.pin, label: marker.label)
                    }
                }

                if state.mapMode == .route, let route = state.routeSession {
                    if let plan = route.plan {
                        MapPolyline(coordinates: plan.geometry.map {
                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                        })
                        .stroke(Color.accentColor.opacity(0.9),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                    ForEach(route.points) { point in
                        let index = route.points.firstIndex(where: { $0.id == point.id }) ?? 0
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon), anchor: .center) {
                            RoutePointMarker(
                                index: index,
                                count: route.pointCount,
                                draggable: route.isEditingAllowed,
                                onDrag: { location in
                                    guard route.isEditingAllowed,
                                          let coordinate = proxy.convert(location, from: .global) else { return }
                                    state.routeMove(point.id, lat: coordinate.latitude, lon: coordinate.longitude)
                                })
                                .contextMenu {
                                    Button("删除这个点", role: .destructive) {
                                        state.routeRemove(point.id)
                                    }
                                }
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .all))
            .mapControlVisibility(.hidden)
            // 官方方式拿当前可见区域：MapCameraPosition 是 struct，取不回 region
            .onMapCameraChange(frequency: .continuous) { context in
                state.updateVisibleRegion(context.region)
            }
            .onTapGesture { point in
                // MapReader 把屏幕点换算成地理坐标：这是 SwiftUI Map 里取得点击位置的官方方式。
                // 传送模式：先落针（带动效）并显示地址，落稳后才下发；
                // 路线模式：直接追加一个途经点。
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                Task { await state.handleMapTap(lat: coordinate.latitude, lon: coordinate.longitude) }
            }
            .onChange(of: state.routeSession?.planRevision) { _, _ in
                state.fitRoute()
            }
            // 顶部：先铺悬停遮罩，再铺拖拽热区（遮罩 allowsHitTesting=false，不会挡拖拽）。
            // 都必须在控件簇之前叠加 —— 后叠加的控件簇层级更高，按钮照常可点。
            .overlay(alignment: .top) {
                if state.titlebarHovered { TitlebarVeil() }
            }
            .overlay(alignment: .top) {
                TitlebarDragArea { state.setTitlebarHovered($0) }
                    .frame(height: TitlebarVeil.height)   // 与悬停条同高：整条都能拖窗口
            }
            // 设备图标中心与红绿灯中心对齐（都在距顶 22pt），悬停条以这条线上下等长；
            // 下面的定位/缩放胶囊自然落在悬停条之外，不侵占它。
            .overlay(alignment: .topTrailing) {
                ControlsCluster()
                    .padding(.top, ControlsCluster.topInset)
                    .padding(.trailing, ControlsCluster.trailingInset)
            }
            .overlay(alignment: .bottomLeading) {
                // 贴在系统「高德地图」归属标注后面（实测标注占 x 2.5–65pt、离底 0–13pt）
                CoordinateReadout()
                    .padding(.leading, CoordinateReadout.leadingInset)
                    .padding(.bottom, CoordinateReadout.bottomInset)
            }
            .overlay(alignment: .bottom) {
                if state.mapMode == .route {
                    RoutePanel()
                        .padding(.bottom, 18)
                } else {
                    RouteEntryButton()
                        .padding(.bottom, 18)
                }
            }
            .overlay(alignment: .top) {
                if let message = state.lastMessage { MessagePill(text: message).padding(.top, 58) }
            }
        }
        .ignoresSafeArea()
    }
}

/// 路线途经点标记：起点/终点/中间点不同颜色，可拖动（高优先级手势，避免被地图平移抢走）。
private struct RoutePointMarker: View {
    let index: Int
    let count: Int
    let draggable: Bool
    let onDrag: (CGPoint) -> Void

    private var isStart: Bool { index == 0 }
    private var isEnd: Bool { index == count - 1 && count > 1 }

    private var title: String {
        if isStart { return "起" }
        if isEnd { return "终" }
        return "\(index)"
    }

    private var fill: Color {
        if isStart { return .green }
        if isEnd { return .red }
        return .accentColor
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .contentShape(Circle())
            // 吞掉点击，避免穿透到地图又追加一个点
            .onTapGesture { }
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if draggable { onDrag(value.location) }
                    }
            )
    }
}

/// 左下角坐标读数。
///
/// 两个约束都来自实测（截图量像素，因为 MapKit 的归属标注没有 API 可查）：
/// 1. **位置**：接在系统「高德地图」标注之后 —— 标注占 x 2.5–65pt、离窗口底 0–13pt，
///    所以读数从 68pt 起、离底 3pt，与标注同一行。
/// 2. **颜色**：与标注一致 —— 半透明白（会随底图颜色微变）+ 极轻的暗描边，
///    而不是此前的纯色/白色泛光。
/// 没有定位时**什么都不画**（早期用 "—" 占位，看起来就是左下角多了一根横杠）。
private struct CoordinateReadout: View {
    /// 起点 = 标注宽度(≈65pt) + 3pt 间隙
    static let leadingInset: CGFloat = 68
    /// 与标注垂直居中对齐
    static let bottomInset: CGFloat = 3

    @EnvironmentObject var state: AppState

    var body: some View {
        if let position = state.position {
            Text(AppState.format(lat: position.lat, lon: position.lon))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
        }
    }
}

/// 顶部临时提示（2.4s 自动消失）。
private struct MessagePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .modifier(GlassChrome(shape: Capsule()))
            .transition(.opacity)
    }
}
