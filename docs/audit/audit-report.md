# 草图 vs 实现全面审计报告（A 阶段 S2 终判汇总）

- **日期**：2026-10-17
- **审计对象**：`docs/design-review/` 10 张定稿草图（2026-10-14 定稿，禁改）vs F0~F11 完成态实现
- **审计方式**：S1 四组并行静态审计（组1 connect+welcome｜组2 live+transition｜组3 viz+meter｜组4 eq+background+arch，30+ 条差异初判）→ S2 逐条终判
- **实现基线**：commit `24a4d66`（A0 = F0~F11 完成态快照）
- **终判原则**：MEMORY/MAINTENANCE 已留档的决策归 B 不修；未留档且草图真源明确的归 A 修
- **结论**：A 类真偏差 **22** 项待修（P0 结构性 3｜P1 功能布局 10｜P2 视觉细节 9）；B 类已留档决策 **18** 项不修；C 类 SDK 限制 **4** 项；D 类口径近似 **4** 项（本轮补留档）
- **执行方式**：S3 按文件簇并行委派子代理修复（簇内文件不相交，避免编辑冲突）；全部簇完成后统一构建验证基线（may-throw 3 + syscap 67 + 0 ERROR），再按簇独立 commit

## 修复进度总览

| 步骤 | 文件簇 | A 项 | 状态 |
|---|---|---|---|
| R1 | common/model/EqStage.ets | A-03 | ✅ 已修 `7d68a14` |
| R2+R6+R8 | pages/Connect.ets + component/ConfigSections.ets | A-01/A-07/A-09/A-17a/A-10/A-12/A-22 | ✅ 已修 `9645f67` |
| R3+R5 | pages/Live.ets + component/VizCanvas.ets + component/VizPanel.ets | A-02/A-06/A-17b/A-18/A-19 | ✅ 已修 `e1141ab` |
| R4 | pages/VizPage.ets | A-04/A-05 | ✅ 已修 `7b7f4e4` |
| R7 | services/StreamService.ets | A-08 | ✅ 已修 `0df0ba6` |
| R9 | pages/Settings.ets | A-11/A-13/A-20/A-21 | ✅ 已修 `3bdfa92` |
| R10 | pages/Welcome.ets | A-14/A-15/A-16 | ✅ 已修 `441fc8f` |

（2026-10-17 S3 完成：8/8 簇 22/22 项已修；统一构建 BUILD SUCCESSFUL，基线核对通过——0 ERROR + may-throw 3 + syscap 67 完全吻合。修复中确认的审计偏差：A-22 折叠态结构以 eq.html mock 实际为准（头行下方独立 eqexp 卡片行，非头行内右侧）；A-12「:723/:764 两处」系行号笔误，实际仅一处 fontSize(16)；A-17a mock 仅呈现 running 绿影，idle 蓝影为同口径跟随填充色的实现选择。）

---

## A 类：真偏差（待修 22 项）

### P0 结构性（3 项）

**A-01 EQ 面板双入口** → 簇 R2
- 草图：arch.html:291「Connect 卡不含 EQ」——EQ 面板唯一入口 = Live 配置 sheet
- 现状：Connect.ets:367 ConfigCard 无条件渲染 `ConfigSections()`，ConfigSections build（:1059 附近）无条件渲染 EqSection → Connect 配置卡与 Live sheet 双入口
- 修复：ConfigSections 增加普通成员 `showEq: boolean = true`，Connect 处传 `ConfigSections({ showEq: false })` 隐藏 EQ 区；Live sheet 默认 true 不动

**A-02 Live VizCard Canvas 未锁深色** → 簇 R3
- 草图：live.html LiveView 恒深（#121212 底，VizCard 深底波形）
- 现状：VizCanvas 合成暗判定 composeDark() 跟随主题（themeMode 1 浅/2 深/0 系统），Live 恒深页内嵌 Canvas 在浅色主题下渲染浅色系（白底面板突兀）；VizPage 恒深设置已有先例（aboutToAppear 内）
- 修复：VizCanvas/VizPanel 增加 `forceDark: boolean = false` 普通成员，Live 传 true——composeDark() 恒返回 true（mediaquery 注册可保留，结果不受影响）；VizPage/Connect 用法不变（默认 false）

**A-03 EqStage Shelf alpha 公式错误** → 簇 R1
- 现状：EqStage.ets:113 `const alpha = sw * Math.SQRT1_2 * Math.sqrt(2);`——数学上 `*Math.sqrt(2)` 恰好抵消 SQRT1_2 的 ÷√2，等效 alpha=sw（Q=0.5 口径）
- 应为：MAINTENANCE F7 决策②「Shelf S=1 alpha=sw√2/2」→ `const alpha = sw * Math.SQRT1_2;`
- 影响：LOW_SHELF/HIGH_SHELF 段实际形状偏窄；听感与 EQ 曲线预览（magnitudeDbAt 同源系数）均偏差

### P1 功能/布局（10 项）

**A-04 VizPage appearOp 双重淡入残留** → 簇 R4
- 草图：viz.html anno2 明示删除手写 appearOp 淡入（二级 cover modalTransition:ALPHA 已含系统淡入）
- 现状：VizPage.ets:24 `@State appearOp`、:74-80 aboutToAppear 手写淡入动画、:548 根 opacity 绑定——与 ALPHA 转场叠加双重淡入
- 修复：删除 appearOp 状态、淡入逻辑与根 opacity 绑定

**A-05 VizPage 分段条改单一圆角整条** → 簇 R4
- 草图：viz.html 分段控制器 = 外包容器（高 48/r24/#1C1C22/padding 4）+ 内层分段无间隙，选中段 accent + r20 + fontWeight 600
- 现状：VizPage.ets:460-481 ToggleRow = `Row({space:8})` 内 ForEach 各段独立 borderRadius(20) 背景，段间 8 间隙、无外容器
- 修复：按草图重构；pillSelected/onPillTap 交互逻辑不变

**A-06 Live ControlRow 未钉底** → 簇 R3
- 草图：live.html 控制行 absolute bottom 46、width 76% 居中（不随内容滚动）
- 现状：Live.ets:452-499 ControlRow 在 Scroll 流内，width 90%
- 修复：移出 Scroll 钉底（ArkUI 等效实现：Scroll(layoutWeight 1) + ControlRow 尾部固定 + 底部安全区 padding，视觉等效即可）；width 76% 居中

**A-07 MiniLiveBar 边距与反模式** → 簇 R2
- 草图：connect.html mini 条左右边距 20
- 现状：Connect.ets mini 条边距 10；`width('100%')+margin` 组合为 ArkUI 反模式
- 修复：边距 20，重构为父级 padding 20 + 子 width('100%')；**保留 geometryTransition('liveCard',{follow:true})、弹簧上浮动画与 .id() 一镜到底三件套**

**A-08 muted 分支 PRE 喂静音** → 簇 R7
- 契约：MAINTENANCE §3「静音路径不进管线（静音帧直发保持，POST=-inf、**PRE 正常**）」
- 现状：StreamService.ets:806-817 muted 分支 `feedPre(sil,…)`——静音时 PRE 也归 -inf，PRE 行/电平表失真
- 修复：feedPre 改喂真实 `buffer`（capRate/capBits/capCh）；feedPost 与 enqueueData 维持 sil 不变

**A-09 closeLive restoreSystemBar 时序** → 簇 R2
- 口径：live.html「收起后恢复」+ MAINTENANCE F10 决策①「closeLive() **尾**」
- 现状：Connect.ets:77-82 restoreSystemBar() 在 animateTo **之前**（首行）——收起动画期间状态栏已切回，深色 cover 尾帧闪浅色状态栏
- 修复：移入 animateTo onFinish（350ms 收起完成后恢复）；**onWillDismiss 回调首恢复路径（back 手势）勿动——F10 双汇点互斥机制保持**

**A-10 EqCurve 预览固定 48k** → 簇 R2
- 现状：ConfigSections EQ 曲线预览经 UI 本地 curveEq 实例固定 48000 合成（F7 决策⑧）；直通 16k 配置/弱网降级 16k 时预览与实际滤波曲线不符
- 修复：预览采样率与 syncPipelineParams 同口径——NR 分支 48000 / 直通分支 effectiveSampleRate（降级 16000）；UI 侧从 AppStorage（cfgProNr/proNrAvailable/cfgRate/rateDowngraded）镜像 StreamService.effectiveSampleRate 逻辑（可读其源码对齐，**勿改 StreamService.ets**——该文件属簇 R7）

**A-11 Settings 外观卡缺标题** → 簇 R9
- 草图：connect.html 设置页外观卡有「外观」标题行
- 现状：Settings.ets:117-128 AppearanceCard 直接三行 ThemeRow，无标题行
- 修复：补「外观」标题行（fontSize 16 Medium、height 40，同 StreamingCard/DeviceCard 标题行样式）

**A-12 增益行标题字号 16→14** → 簇 R2
- 草图：connect.html cgain 行标题 14px
- 现状：ConfigSections.ets:723/:764 区域增益行标题 fontSize(16)
- 修复：改 14（范围仅 ConfigSections 两处；Live.ets 增益行为恒深固定样式 F6 决策⑥，不在本项范围）

**A-13 设备卡脚注字号 10→12** → 簇 R9
- 现状：Settings.ets:274-275 脚注 fontSize(10)
- 修复：改 12

### P2 视觉细节（9 项）

**A-14 Welcome 图标圆** → 簇 R10：welcome.html feature 行 = 图标圆（sys.symbol 图标、直径 40、底色 12%、间距 20）；现状 Welcome.ets:63-88 数字序号圆 32。图标名须对照 sysResource.js 验证存在（已知存在：wifi/waveform）
**A-15 Welcome 文案字号与对齐** → 簇 R10：标题 13→14、副文 11.5→12，文案逐句与 welcome.html 对齐
**A-16 Welcome CTA** → 簇 R10：按钮补阴影 + letterSpacing 1px + bottom 44（值以 welcome.html mock 为准）
**A-17 主按钮/断开钮阴影** → 簇 R2（Connect 主按钮）/簇 R3（Live 断开钮）：mock .bigbtn 口径 `0 10px 26px rgba(52,199,89,.35)`（各页 mock 值为准：connect.html / live.html）
**A-18 LIVE 圆点 pulse** → 簇 R3：LIVE 徽章圆点 1.6s 呼吸循环动画（live.html mock）
**A-19 VizCard 高 344→320** → 簇 R3：Live.ets:359 canvasHeight 320→296（+VizPanel padding 12×2 = 卡高 320，live.html mock 口径）
**A-20 运行日志高 180→120** → 簇 R9：Settings.ets:335 height(180)→120
**A-21 单选圈描边 token** → 簇 R9：ThemeRow/DeviceRow 未选中圈描边 clip_idle→text_hint（Settings.ets:103/:216）
**A-22 EQ 折叠行迷你曲线预览** → 簇 R2：eq.html 折叠行右侧 170×44 迷你曲线；现状 EqHeader 折叠行仅文字摘要——复用既有 Path 曲线方案缩小几何（170×44），折叠态显示

---

## B 类：已留档决策（终判不修，18 项）

| 项 | 留档出处 |
|---|---|
| 电平表线性刻度 (db+60)/60（计划文本「对数」误） | MEMORY F8 条 ⚠️ |
| dark accent=#007AFF（计划文本 #0A84FF 误） | MEMORY F10 条 ⚠️ |
| divider token 统一（eq.html .05 恒深线不分级） | MEMORY F10 条 |
| transition.html follow/anchor 标反（草图示意错误，实现正确） | MEMORY F1 条 |
| Live 增益行固定深色 literal | MAINTENANCE §0 F6 决策⑥ |
| VizCard 底→Mat.viz 材质（#FF212121 弃） | MAINTENANCE §0 F3 决策⑦ |
| 卡面文字指标行移除（图形表条+CLIP LED 取代） | MAINTENANCE §0 F8 决策⑧ |
| EQ 旁通态仍画曲线（编辑器预览语义） | MAINTENANCE §0 F7 决策⑨ |
| LUFS 预留（MeterMode 枚举，本期不实现） | MAINTENANCE §0 F8 决策⑪ |
| rateDowngraded 第 14 AppStorage key 契约例外 | MEMORY F4 条 |
| 锁屏 play/pause 直接映射（非盲切换） | MAINTENANCE §0 F9 决策② |
| 元数据 artist/subtitle 双写兼容 | MAINTENANCE §0 F9 决策③ |
| PlaybackState 数值枚举 PLAY=2/PAUSED=3 | MAINTENANCE §0 F9 决策⑤ |
| 三开关默认值（常亮关/恢复开/降级开） | MAINTENANCE §0 F9 决策⑧ |
| 通话打断挂起保监听（非全拆） | MAINTENANCE §0 F9 决策⑨ |
| 弱网迟滞降级参数（10s 持续/30s 间隔） | MAINTENANCE §0 F4 决策③④ |
| mock eqhead 重复标题去重 | MAINTENANCE §0 F7 决策⑩ |
| BandRow 显式 5 次调用非 ForEach | MAINTENANCE §0 F7 决策⑪ |

## C 类：SDK 限制（4 项）

1. **selectMediaInputDevice 不适用 VOICE_COMMUNICATION 源**（默认 cfgSource=0 即该源，设备选择可能被系统忽略；currentInputDeviceChanged 仍反馈实际路由）——F5 MEMORY ⚠️ 已知限制，真机验证待做
2. **barFloatingStyle 与自定义 tabBar Builder 共存性**未证实——F3 MEMORY 待真机确认，异常退化=移除 barFloatingStyle
3. **eq.html brow 间线 .05** 为 sheet 恒深浏览器近似——真机 systemMaterial(ULTRA_THICK) 自适应明暗，恒深 literal 浅色主题白线不可见，统一 divider token（F10）
4. **CanvasRenderingContext2D.strokeStyle/fillStyle 不含 Resource**（canvas.d.ts:1629/1663）——EQ 曲线弃 Canvas 改 Path 组件绕开（F7 SDK 定论）

## D 类：口径近似（本轮补留档，不修）

1. **OfflineBanner「或数据连接」**：草图断网横幅文案含「或数据连接」措辞，代码 OfflineBanner 为简化文案——低保真文案非精确规格，以代码为准
2. **sheet「音频配置」标题行**：草图 Live 配置 sheet 顶部有「音频配置」标题行，实现 sheet 直接承载 ConfigSections（F2 材质+内容直载决策），不补标题行
3. **字重口径**：草图 CSS font-weight:600 对应实现统一 FontWeight.Medium(500)——字重档位非一一映射，全项目一致口径
4. **--unsel 双 token 微差**：草图两个未选中态色 token 存在草稿演化微差，实现统一单一 token，以实现为准
