# 路线模式设计（Route Mode Design）

> 状态：**设计阶段**，未写业务代码。P0 事实验证已完成大部分，剩余项见第 14 节。
> 目标读者：维护者（自己）。所有结论都标注了「已验证 / 待验证」。

## 1. 目标与非目标

**目标**

- 在地图上选点：起点 + 终点 + 最多 5 个途经点（共 7 点）。
- 按交通方式规划：步行 / 跑步 / 自行车 / 电动自行车 / 开车 / 高速。
- 沿路线播放，速度带轻微随机波动（不是恒定速度）。
- 国内与境外都能用：国内走高德，境外走 Valhalla。
- 规划失败时**不静默降级**，报错并让用户重试。

**非目标（本期不做）**

- 转向提示、语音导航（只做"沿路线移动"）。
- 路线保存 / 收藏 / GPX 导出 UI（后端能力保留，UI 后续再说）。
- 播放中编辑路线（添加/删除/调整点）。
- 多路线方案对比、实时路况。

## 2. 已确认的产品决策

| # | 决策 |
|---|---|
| 1 | 只做沿路线移动，不做转向/语音 |
| 2 | 路线几何必须按交通方式规划（不共用汽车路网） |
| 3 | 国内优先高德；境外先用 Valhalla |
| 4 | 6 种方式：步行、跑步、自行车、电动自行车、开车、高速 |
| 5 | 最多 5 个途经点（总点数 ≤ 7） |
| 6 | 速度用预设 + 轻微随机 |
| 7 | 暂时不做路线保存 |
| 8 | 播放中不允许编辑 |
| 9 | 失败让用户重试，不自动回退直线 |

**关于「高速」（由实现方决定）**：高速只作为**速度档**，几何仍用驾车路网（国内高德 driving / 境外 Valhalla auto）。

- 理由：强制"只走高速"的路线在城市内无解；本工具的目的是模拟移动，不是真实导航。Valhalla 的 auto 在长距离下本身会优先高速，高德也可用 `strategy` 偏好高速。
- 边界：如果将来需要"严格高速路线"，作为独立需求再做，不在本期。

## 3. P0 事实验证结果

### 3.1 高德（国内，真 Key 已验证）

同一组上海起终点（WGS 31.2304,121.4737 → 31.2454,121.4987；GCJ 偏移 481 m）：

| 方式 | 路径数 | 距离 | 耗时 | steps | 折线点 |
|---|---|---|---|---|---|
| driving | 3（含备选） | 4,722 m | 1,127 s（`cost.duration`） | 11 | 119 |
| walking | 1 | 5,831 m | 4,665 s（`cost.duration`） | 19 | 272 |
| bicycling | 1 | 6,394 m | `path.duration`（`cost` 为 null） | 23 | 343 |
| electrobike | 1 | 6,391 m | `path.duration`（`cost` 为 null） | 20 | 341 |

**解析要点（都已实测，按这个实现）**

- 折线在 `route.paths[].steps[].polyline`，格式 `lon,lat;lon,lat`，需要逐 step 拼接；
- **必须传 `show_fields=polyline,cost`**：不传时 path 只有 `distance/restriction/steps`，没有 polyline、没有 cost；
- 耗时字段不统一：**驾车/步行在 `path.cost.duration`，骑行/电动车在 `path.duration`**（骑行/电动车 `cost` 为 null）→ 统一取 `path.duration or path.cost.duration`；
- 距离在 `path.distance`（米）；驾车返回多条备选，取 `paths[0]`；
- 坐标：输入按 **GCJ-02** 解释，输出也是 GCJ-02。实测直接把 WGS 传进去，高德会从偏移约 481 m 的位置起算；回显的 `route.origin/destination` 与输入 GCJ 完全一致；
- **途经点只有驾车支持**；步行/骑行/电动车带 `waypoints` 返回 `21002 HAVE_NO_PERMISSION` → 必须逐段串行（与第 7 节一致）；
- 驾车 5 个途经点可正常返回（未报上限错误）；
- 距离上限：步行 上海→北京（约 1060 km）返回 `20803 OVER_DIRECTION_RANGE`；
- 其他错误：非法坐标/海上点 → `20802 ROUTE_FAIL`；公交端点 `/v5/direction/transit` 不存在（404，本期不接公交）；
- **海外权限：当前 Key 无**。国内端点用巴黎坐标返回 `20802`；海外端点 `sg-restapi.opnavi.com` 返回 `10012 INSUFFICIENT_PRIVILEGES` → 境外必须走 Valhalla（或申请海外权限）；
- 待确认：QPS/日配额以高德控制台为准（代码里做退避与配额错误提示）。

### 3.2 Valhalla（境外）

- ✅ 真正按方式规划，同一段上海路线三种几何不同：

  | costing | 距离 | 时间 | 折线点数 |
  |---|---|---|---|
  | auto | 4.29 km | 10.0 min | 118 |
  | bicycle | 6.74 km | 32.8 min | 216 |
  | pedestrian | 4.95 km | 66.0 min | 209 |

- ✅ 单次请求支持 7 个点（返回 6 段）；也验证了逐段串行。
- ✅ 逐段拼接：6 段合计 6.79 km，与原生多点一致；接缝 5 处、**最大间距 0.00 m**（坐标完全重合）。
- ✅ 返回 `shape` 为 polyline6（1e6 精度、lat/lon 顺序），可本地解码。
- ✅ 错误规范：`154` 超最大距离（1,500,000 m）、`171` 无可用道路、HTTP 400/429。
- ⚠️ 公共 demo 是演示服务，不保证 SLA/配额；个人使用可接受，产品化需自建或换 Google。

### 3.3 坐标系

- ✅ `core/coord.py` 往返精度：上海/北京/深圳/乌鲁木齐误差 **< 0.001 mm**。
- ✅ GCJ-02 偏移量（必须转换的原因）：上海 481 m、北京 555 m、深圳 606 m、乌鲁木齐 265 m。
- ❌ **现有 `out_of_china()` 不能用**：它只是一个粗矩形（lon 72–137.8 / lat 0.83–55.8），实测把**香港、澳门、台北、首尔、曼谷、新加坡、河内、乌兰巴托**全部误判为"国内"。
- ✅ 替代方案已验证：用 Natural Earth 50m 国界多边形（公共领域）+ RDP 简化（容差 0.05°）→ **725 顶点、约 15 KB**，15/15 判定正确（北京/上海/深圳/乌鲁木齐/拉萨/哈尔滨 为国内；港澳台、首尔、曼谷、新加坡、河内、乌兰巴托、巴黎 为境外）。

### 3.4 其他

- ✅ 公共 OSRM demo 对 profile 不区分（driving/foot/bike 几何完全相同），**不作为方式感知的 provider**。
- ⏳ 待验证：iOS 是否根据 1 Hz 下发坐标给出合理的 `CLLocation.speed`/course。
- ✅ **MapKit 点击坐标不是 WGS-84**（2026-10-26 真机/已知点对比）：macOS MapKit 在中国大陆返回
  **GCJ-02**。点「东方明珠」读数 `31.239257,121.499953`，与高德 GCJ（`31.2397,121.4997`）相差 ~48 m，
  与真实 WGS（`31.2419,121.49526`，Wikipedia/WGS84）相差 ~477 m。App 已用 `ChinaCoordinate`
  在边界转换：点击/拖动 GCJ→WGS，绘制 WGS→GCJ；境外与港澳台不转换。

## 4. Provider 策略

### 4.1 选择粒度：按整条路线，不按段

**规则**：7 个点**全部**落在"中国大陆多边形"内 → 高德；否则 → Valhalla。

为什么不做逐段混合：

- 港澳台/边境的 GCJ 归属不明确，逐段混用会引入"一段 GCJ、一段 WGS"的坐标拼接风险；
- 高德不支持跨境路线，混合时跨境段仍要换 provider；
- 路线级选择更简单、可预测，7 个点的场景足够。

代价：紧贴边境/海岸的国内路线可能被判为境外走 Valhalla（数据质量略差但可用）；这是可接受的保守策略。

### 4.2 矩阵

| 整条路线位置 | 步行/跑步 | 自行车/电动车 | 开车/高速 |
|---|---|---|---|
| 中国大陆 | 高德 walking | 高德 bicycling / electrobike | 高德 driving |
| 其他（含港澳台、境外） | Valhalla pedestrian | Valhalla bicycle | Valhalla auto |

- 跑步复用步行几何（没有独立跑步路网），仅速度不同。
- 港澳台用 Valhalla（WGS-84，不做 GCJ）。
- 未来可选：Google Routes API（需 Key/计费/网络）、高德海外（需授权）。

### 4.3 失败语义

- **不做自动降级**（不自动换 provider、不自动直线）。
- 返回结构化错误：`{ok: false, error, retryable: true/false, provider}`；UI 显示原因 + 「重试」。
- UI 可额外提供**用户主动点击**的「换用其他路线服务重试」（仅海外：Valhalla ↔（未来 Google））；国内只有高德，不提供切换。

## 5. 坐标系规则

| 环节 | 坐标 |
|---|---|
| 地图点击/拖动（macOS MapKit，中国大陆） | **GCJ-02** → App 立即转 WGS-84 |
| 内部 Route、API 响应、设备下发 | **WGS-84** |
| App 绘制（落针 / 路线 / 绿点） | WGS-84 → **GCJ-02** |
| 调用高德前 | WGS-84 → **GCJ-02** |
| 高德返回后 | GCJ-02 → **WGS-84** |
| Valhalla | 直接用 WGS-84，**不转换** |
| 境外/港澳台（点击或绘制） | 原样，**不转换** |

- 后端复用 `core/coord.py`；新增 `core/regions.py` 做国界判定（内嵌简化多边形，来源 Natural Earth，公共领域）。
- App 侧 `macos/Sources/LocPilotKit/ChinaCoordinate.swift` 实现同一套 GCJ 算法与同一份大陆多边形，
  保证点击、拖动、绘制、下发四个边界一致。
- 高德坐标字符串按要求保留 ≤ 6 位小数（`%.6f`）。
- 测试：往返误差、已知点偏移量、多边形 15 个用例（含港澳台/周边国家）。

## 6. 六种方式与速度模型

| 方式 | 国内 profile | 境外 costing | 基准速度 | 波动 | 加速度上限 |
|---|---|---|---|---|---|
| 步行 | walking | pedestrian | 1.3 m/s (4.7 km/h) | ±15% | 0.6 m/s² |
| 跑步 | walking | pedestrian | 3.0 m/s (10.8 km/h) | ±10% | 0.8 m/s² |
| 自行车 | bicycling | bicycle | 4.8 m/s (17.3 km/h) | ±12% | 0.8 m/s² |
| 电动自行车 | electrobike | bicycle | 6.2 m/s (22.3 km/h) | ±12% | 1.0 m/s² |
| 开车 | driving | auto | 12.0 m/s (43.2 km/h) | ±20% | 2.0 m/s² |
| 高速 | driving | auto | 28.0 m/s (100.8 km/h) | ±8% | 2.5 m/s² |

### 随机速度算法（后端）

```
每 3–8 秒（按 mode 配置）：
    target = clamp(current * exp(N(0, sigma)), base*(1-jitter), base*(1+jitter))
每个 tick（1 Hz）：
    v = move_towards(v, target, accel_max * dt)   # 加速度限幅
    distance += v * dt                            # 沿几何推进
```

- `jitter = 0` 时退化为恒定速度（兼容现有行为）。
- 支持 `seed`，测试可复现。
- ETA 用 `base` 计算（稳定），UI 另显瞬时速度；不要用瞬时速度算 ETA，否则数字乱跳。
- 速度上下限仍受现有 `MIN_SPEED/MAX_SPEED`（0.1–200 m/s）约束。

## 7. 多点规划（7 点）

- **统一逐段串行**：`P0→P1`、`P1→P2`、…（最多 6 次 provider 调用）。
- 理由：高德步行/骑行不支持途经点；逐段可绕开各 provider 的上限；跨境/跨 provider 天然可扩展；实测拼接接缝 0.00 m、总里程与原生多点一致。
- 拼接规则：
  1. 每段几何转为 WGS-84；
  2. 接缝处去掉重复点；
  3. 若相邻接缝间距 > 30 m 或方向突变 > 90°，记录 warning（数据异常）；
  4. 里程以拼接后的几何累计为准（沿用现有教训：不能用 provider 的 distance 做进度）。
  5. 几何点距 > 20 m 时按 `DENSIFY_STEP_M` 加密，保证播放平滑。
- 请求治理：编辑防抖 400 ms；按「点集 + 方式 + provider」哈希缓存；请求代次令牌丢弃过期结果；最多 6 次调用。

## 8. 后端改动

### 8.1 模块

```
locpilot/core/
  regions.py      新增：中国大陆多边形判定（Natural Earth 简化数据）
  routing/
    base.py       新增：RoutingProvider 协议、RoutePlan/Segment 数据结构、错误类型
    amap.py       新增：高德 v5（国内）+ GCJ 转换
    valhalla.py   新增：Valhalla（境外）
    mock.py       新增：测试用
    service.py    新增：区域判定、逐段编排、拼接、缓存、错误映射
  coord.py        启用
  route.py        调整：几何来源改为 provider；保留直线加密工具
  playback.py     扩展：速度模型（base/jitter/accel/seed）
locpilot/api.py   增量：/api/route 支持 mode/provider/jitter/seed
```

### 8.2 API 契约

`POST /api/route`

```json
{
  "points": [[lat, lon], ...],       // 2–7 个，WGS-84
  "mode": "walk|run|cycle|ebike|drive|highway",
  "provider": "auto|amap|valhalla",  // 可选，默认 auto（按区域）
  "jitter": 0.12,                    // 可选，0 = 恒定
  "seed": 12345                      // 可选，测试复现
}
```

响应（增量字段加粗）：

```json
{
  "loaded": true,
  "mode": "walk",
  "provider": "amap",
  "geometry": [[lat, lon], ...],     // WGS-84
  "waypoints": [[lat, lon], ...],
  "distance": 1234.5,
  "duration": 950.0,                 // 按基准速度估算
  "bounds": {...},
  "routed": true,
  "warnings": []
}
```

错误：

```json
{"ok": false, "error": "高德：无可用路线", "retryable": true, "provider": "amap", "code": "20800"}
```

- 保留现有 `speed` 参数作为手动覆盖（优先于 mode 基准），兼容 CLI/旧客户端。
- `/api/status` 的 `playback` 增加：`mode`、`speed_base`、`speed`（瞬时）、`eta_seconds`。

### 8.3 Key 与配置

- 解析顺序：`LOCPILOT_AMAP_KEY` 环境变量 → `settings.json` 的 `amap_key`。
- `settings.json` 权限 0600；`/api/status` 只回 `amap_key_configured: true/false`，**永不回 Key 本身**；日志脱敏。
- 需要把 `amap_key` 加入配置白名单（现有 `ENGINE_SETTING_KEYS` 的模式）。
- 可选 CLI：`python3 -m locpilot config set-amap-key`（写入 0600 文件，不回显）。

### 8.4 前置修复

- LP-11：`Playback.start()` 未重置里程 → 跑完不能重播，路线模式必踩。
- LP-12：`/api/settings` 改 `tick_interval` 不生效（未来提频平滑时需要）。

## 9. 原生 UI

- 模式切换：传送 / 路线（底部「路线」入口；路线面板右上 × 退出）。
- 路线编辑：点击加点（≤7）、拖动移动、右键删除、清空；起点/终点/途经点用不同颜色 + 编号。
- 交通方式选择：6 个预设（菜单）；切换后自动重新规划。
- 规划状态：编辑后防抖自动规划；规划中显示 spinner；失败显示原因 + 「重试」。
- 绘制：`MapPolyline`，规划完成后按 bounds 自动取景。
- 播放：开始/暂停/继续/停止；进度条 + 距离 + ETA + 瞬时速度；播放时跟随，停止后恢复原镜头。
- 播放中禁用编辑（符合决策 8）。
- 代码组织：`RouteSession` 在 LocPilotKit（@MainActor、可测试），`AppState` 做绑定与相机；`EngineClient` 增加 planRoute/start/pause/resume/stop；`StatusSnapshot` 增加 `route`/`playback` 解析。
- 实现状态：✅ 已完成（见第 18 节）。

## 10. 错误与重试

| 来源 | 处理 |
|---|---|
| 无 Key / Key 无效（高德 `10001`） | 配置错误，`retryable:false`，提示去配置 |
| 无海外权限（高德 `10012`，实测当前 Key 就是） | `retryable:false`，提示改用境外路线服务 |
| 方式不支持途经点（高德 `21002`） | 内部路由，不暴露给用户（一律逐段规划） |
| 配额超限 / QPS 过高（高德 `10003` / `10004`） | `retryable:true`，退避后重试；提示明日额度 |
| 无可用路线（Valhalla `171`、高德 `20802`） | `retryable:true`，提示换点/换方式 |
| 超距离上限（Valhalla `154` 1,500 km、高德 `20803`） | `retryable:false`，提示路线过长 |
| 网络超时 | `retryable:true`，自动退避 1 次后报错 |
| 拼接接缝异常 | warning，不阻断；必要时报错 |

原则：**不自动换 provider、不自动直线**；UI 必须展示 provider 与失败原因。

## 11. 安全与隐私

- 高德 Key 只存本机（0600），不进 App 二进制、不进日志/状态接口。
- 路线坐标会发送到高德（国内）或 Valhalla 公共 demo（境外）；UI 的 provider 标识要可见。
- 端口/API 鉴权沿用现有 Origin/Host 校验与可选 token；新接口自动受保护。

## 12. 测试策略

**Python（unittest，无第三方依赖）**

- `coord`：往返误差、已知点偏移量。
- `regions`：多边形 15 个用例（国内/港澳台/周边国家/境外）。
- provider 解析：用真实响应 fixture（高德 v5、Valhalla）离线测试，不打网络。
- service：逐段拼接、接缝去重、错误映射、缓存、代次。
- playback：速度模型确定性（seed）、jitter=0 退化为恒定、加速度限幅、ETA。
- API：请求/响应契约、参数校验（2–7 点、mode 枚举）。

**Swift**

- `RouteSession` 状态机（idle/editing/planning/playing/paused/finished）、代次丢弃、失败重试。
- `StatusSnapshot` 新字段解码 fixture。
- `EngineClient` 请求构造。

**真机/真实网络**

- 6 种方式 × 国内/境外各 2 条路线；检查移动平滑度、iOS 侧速度上报、长路线稳定性。

## 13. 风险

| 风险 | 影响 | 应对 |
|---|---|---|
| 高德 Key 无海外权限 | 境外不能用高德 | 境外用 Valhalla（已定） |
| Valhalla demo 不稳定/限流 | 境外规划失败 | 错误可重试；将来可换 Google/自建 |
| 区域多边形误判边境 | 走错 provider | 路线级保守判定 + 多边形测试；真机抽查 |
| 高德耗时字段不统一（`cost.duration` / `path.duration`） | 解析错误 | 已实测，统一取 `path.duration or path.cost.duration` |
| GCJ 转换错误 | 定位整体偏移 | 边界转换 + 单测 + 真机抽查 |
| 6 次调用超配额 | 规划失败 | 防抖 + 缓存 + 配额提示 |
| 1 Hz 高速移动观感 | 每跳 14–28 m | 与真实 GPS 一致；必要时提频（需修 LP-12） |
| 长路线 DVT 稳定性 | 断线暂停 | 复用现有暂停/续播 |

## 14. 分阶段计划

| 阶段 | 内容 | 估算 | 状态 |
|---|---|---|---|
| P0（已完成） | Valhalla、坐标系、区域多边形、高德端点可达性 | 0.5 天 | ✅ |
| P0（真 Key 验证） | 高德四种方式真实调用、`show_fields`、耗时字段、途经点限制、错误码、海外权限 | 0.5 天 | ✅ |
| P1 | provider 抽象 + 高德 + Valhalla + 区域判定 + 逐段拼接 + 速度模型 + API + 前置修复 | 2–2.5 天 | ✅ 已完成 |
| P2 | RouteSession + EngineClient + 路线 UI | 2–3 天 | ✅ 已完成 |
| P3 | 真机/境外联调、速度观感、错误与重试 | 1–1.5 天 | 待开始 |

## 15. 待办 / 待确认

1. ✅ 高德真 Key 验证已完成（Key 存于 `~/Library/Application Support/LocPilot/settings.json`，0600；不进仓库/安装包）。
2. **MapKit 坐标**：真机确认点击坐标是 WGS-84（拿已知点与高德 GCJ 点对比）。
3. **iOS 速度上报**：真机确认 1 Hz 下发时 `CLLocation.speed`/course 是否合理。
4. **QPS/日配额**：以高德控制台为准；P1 实现退避与配额提示。
5. 高德海外权限是否申请（决定未来境外是否统一回高德）；Google 是否接入（备用）。

## 16. 数据与许可

- 国界多边形：Natural Earth 50m Admin 0 Countries（公共领域），RDP 简化后内嵌，仅用于**路线服务区域选择**，不渲染、不代表任何边界主张。
- 高德/Valhalla/Google 的使用受各自服务条款约束；公共 demo 仅用于个人/验证用途。

## 17. P1 实现记录（2026-10-26）

**新增文件**

- `locpilot/core/regions.py` + `china_mainland.json`：Natural Earth 50m + RDP(0.05) → 13 环 / 725 顶点 / 13.5 KB，15/15 判定正确；
- `locpilot/core/speed.py`：`SpeedModel`（基准 + 慢随机游走 + 加速度限幅 + seed）；
- `locpilot/core/routing/`：`base.py`（协议 / 错误 / 拼接 / polyline6）、`amap.py`（v5 + GCJ）、`valhalla.py`（polyline6）、`mock.py`、`service.py`（区域选择 + 逐段编排）。

**修改**

- `config.py`：`TRAVEL_MODES` / `MODE_PROFILES`（6 种方式）/ `ROUTING_SETTING_KEYS` / `speed_jitter` / `VALHALLA_URL` / 环境变量；
- `route.py`：`mode` / `provider` / `warnings` / `duration` 字段（`to_dict` 增量输出）；
- `playback.py`：接入 `SpeedModel`；`status()` 增加 `speed_base` / `mode` / `jitter`；**修复 LP-11**（finished 后 start 重置里程）；
- `session.py`：`set_route(mode/provider/jitter/seed)`；无 `mode` 时保留旧 OSRM/直线行为；**修复 LP-12**（ticker 每轮读 `tick_interval`）；快照增加 `routing` 状态；
- `api.py`：`/api/route` 支持 `mode/provider/jitter/seed`，限制 7 点；`RoutingError → 502 + retryable/code/provider`；`/api/settings` 接受路由配置；
- `server.py`：错误体透传 `extra`（retryable/code/provider）；
- `cli.py`：`route --mode/--provider/--jitter/--seed`，捕获 `RoutingError` 输出友好错误；
- `README.md`：补路线模式参数与 Key 配置说明。

**与设计一致的取舍**

- 按整条路线选 provider（非逐段混合）；
- 统一逐段串行（即使 Valhalla 支持 7 点原生多点，也走逐段，保证与高德一致、跨境可控）；
- 不做自动降级/自动重试：错误统一返回 `retryable`，由用户点重试（按产品决策）。

**验证**

- 本地 43 项 unittest 全过（`python3 -m unittest discover -s tests`；`tests/` 按仓库策略不入库）；
- 真实网络冒烟（上海同一起终点）：walk 5894 m / cycle 6466 m / ebike 6468 m / drive 4792 m；
- 3 点逐段拼接：2 段、6575 m、0 warning、端点吸附 17.2 / 10.0 m；
- 境外（巴黎）：Valhalla walk 1458 m / drive 2373 m；跨境 深圳→香港 40.2 km 走 Valhalla；
- `Session + /api/route` 真实高德：200 / mode=walk / provider=amap / 5894 m；
- MockEngine 回放：5 s 推进 6.37 m；跑完后重播 distance 归零并重新推进（LP-11）；
- `macos/build.sh --selftest` 通过（打包后的后端包含新模块与数据文件）。

**已知未做**

- 自动重试/退避：按"让用户重试"的产品决策，只做错误分类，不做自动重试；
- 高德 QPS/配额：以控制台为准，错误码已映射；
- 路线保存 / GPX UI、转向提示：本期非目标。

## 18. P2 实现记录（2026-10-26）

**新增**

- `LocPilotKit/RouteSession.swift`：@MainActor 状态机
  - `Phase`：editing / planning / planned / failed / playing / paused / finished；
  - 编辑（加点 / 拖点 / 删点 / 清空，≤7）、模式切换、400ms 防抖规划、代次令牌丢弃过期结果；
  - 播放控制（start / pause / resume / stop）与 SSE 进度同步；
  - `planRevision` 供界面自动取景；`isEditingAllowed` 保证播放中禁止编辑。
- `LocPilotApp/RoutePanel.swift`：底部路线面板（交通方式菜单、点数、规划状态、距离 / ETA / 速度、进度条、播放控制）+ 传送模式的「路线」入口胶囊。

**修改**

- `EngineClient.swift`：`StatusSnapshot` 增加 `route` / `playback`；新增 `RoutePlanResult` 与播放状态类型；新增 planRoute / start / pause / resume / stop；`EngineClient` 实现 `RouteServicing`；
- `MapScreen.swift`：`MapPolyline` 画路线；起点 / 终点 / 途经点编号标记（可拖拽 / 右键删除）；点击地图按模式分流；规划完成自动取景；
- `AppState.swift`：`mapMode`、`routeSession`、嵌套 ObservableObject 变化转发、路线动作转发与 `fitRoute()`；`LOCPILOT_MAP_MODE=route` 调试入口；
- 后端 `session.route_summary(include_geometry=False)`：SSE 快照不再携带完整几何（规划响应仍带），避免每秒推几百个点。

**验证**

- Swift 测试：260 项全部通过（新增 7 项 RouteSession 用例：7 点上限、规划成功 / 失败重试、防抖合并、模式切换重规划、播放状态机、SSE 进度）；
  - 新增 `testMainActorAsync`：主线程跑 RunLoop 等待，避免 `testAsync` 的信号量阻塞 MainActor 造成死等；
- `swift build`（debug）与 `macos/build.sh`（release + ad-hoc 签名）均通过；
- 后端 43 项 unittest 通过；确认快照 `route` 不含 `geometry`、`/api/route` 响应仍含几何；
- 视觉验证受限：当前环境无屏幕录制权限（`screencapture` 报 "could not create image from display"），界面细节需在桌面手动确认；
- 已安装到 `/Applications/LocPilot.app` 并用真机验证：iPhone（iOS 27.2）自动连接 `worker:dvt`，包内后端为新代码
  （`runtime.package` 指向 App 内 `backend/locpilot`）；通过 `/api/route` 用真实高德规划成功（walk 5894 m / 383 点）；
- **构建脚本修复**：本机 Desktop 由 iCloud/FileProvider 管理，会反复给 `.app` 打上 `FinderInfo`，
  原地 `codesign` 必然失败。`build.sh` / `dist.sh` 改为在 `/tmp` 暂存副本里清理并签名、再以
  `ditto --noextattr` 放回，校验以暂存副本为准。

**P2 未做（按范围）**

- 转向提示 / 语音、路线保存 / GPX UI、播放中编辑；
- 真实设备联调中的「沿路线移动/速度观感/拖动交互」需要人工在界面上确认（P3）。

## 19. P2.1 修正（2026-10-26）

**问题**：真机上感觉「手机定位与 App 设定偏差有点远」；路线播放时手机停在原地，不跟着绿点走。

**排查结论（两个独立问题）**

1. **坐标系（最初"偏 500 m"的根因）**：macOS MapKit 在中国大陆返回/使用 **GCJ-02**，不是 WGS-84。
   - 点「东方明珠」App 读数 `31.239257,121.499953`，这正是高德 GCJ（`31.2397,121.4997` 附近）；
     东方明珠真实 WGS 是 `31.2419,121.49526`（Wikipedia/WGS84），两者差 **~477 m**；
   - App 把 GCJ 当 WGS 下发 → 手机显示在 GCJ 数值对应的物理位置（东侧 ~477 m 的公共厕所），
     所以看起来"手机和 App 设的不一样"；
   - 反证：直接调后端 API 下发 WGS（人民广场 `31.2304,121.4737`），手机落在大世界站 4 号口 /
     西藏中路×延安东路，分毫不差。设备与后端链路是准的，错在 App 地图边界没转换。
2. **DVT 定位通道闲置失效**：iOS 27.2 上通道长时间空闲后，`set` 仍返回成功但设备不再更新
   （表现为绿点在走、手机停在常熟路）。已改为 worker 闲置超过 TTL 自动重建定位通道。

**修正**

- 新增 App 侧 `ChinaCoordinate`：标准 GCJ-02 算法 + 与后端同一份 Natural Earth 中国大陆多边形；
  - 地图点击/拖动：GCJ-02 → WGS-84 后再存/发；
  - 绘制落针 / 路线 / 绿点：WGS-84 → GCJ-02；
  - 境外与港澳台不转换（东京/香港/台北/首尔/新加坡用例）。
- worker：拆分出可重建的定位通道（保留 RSD/lockdown），闲置超过 `location_session_ttl`
  （默认 120 s）自动重建，日志记录「定位通道已自动刷新」。
- 路线模式 UI：新增设备当前位置绿点；停止保留位置与进度（`Playback.stop(keep_distance=True)`）；
  `RouteSession.stopped` 阶段，面板提示"设备停在当前位置"，进度条不再归零。
- 路线回放时不再逐点逆地理编码（避免每秒请求 Nominatim）。

**验证**

- Swift 303 项（新增坐标转换 6 项）、Python 45 项全过；
- 已知点校验：WGS(天安门)→GCJ 与标准算法一致；高德 GCJ(静安寺)→WGS 反解误差 < 1 m；
  东方明珠 WGS→GCJ 落在高德坐标 20 m 内；
- 真机：WGS 直发时手机位置准确；闲置刷新后 `set` 立即生效（外滩→静安寺→人民广场均能跳转）；
- release 构建 + 签名安装到 `/Applications`，最终以 App 内点击「东方明珠」与路线回放做目视验收。
