import { curves, mediaquery, uiMaterial, window } from '@kit.ArkUI';
import { NetInfoService, MicLogger } from 'common';
import { StreamService, StartResult } from '../services/StreamService';
import { UiEnvService } from '../services/UiEnvService';
import { ConfigSections } from '../component/ConfigSections';
import { Mat } from '../component/Materials';
import { SettingsView } from './Settings';
import { LiveView } from './Live';
import { WelcomeView } from './Welcome';

const TAB_BAR_H = 56;

@Entry
@Component
struct Connect {
  @StorageLink('pcIp') ipInput: string = '';
  @StorageLink('pcPort') portInput: string = '9000';
  @StorageProp('streamBusy') streamBusy: string = 'idle';
  @StorageProp('micOccupied') micOccupied: boolean = false;
  @StorageProp('netOnline') netOnline: boolean = false;
  @StorageProp('netBearer') netBearer: string = 'unknown';
  @StorageProp('netQuality') netQuality: string = 'good';
  @StorageProp('themeMode') @Watch('onThemeModeChanged') themeMode: number = 0;
  @StorageProp('cfgMaterialLevel') @Watch('onMaterialLevelChanged') materialLevel: number = 1;
  @StorageProp('probing') probing: boolean = false;
  @StorageProp('statConn') statConn: string = '未连接';
  @StorageProp('statRecord') statRecord: string = '空闲';
  @State welcomed: number = -1;
  @State currentTab: number = 0;
  @State localIp: string = '...';
  @State sheetOpen: boolean = false;
  @State ipDraft: string = '';
  @State portDraft: string = '';
  @State sheetError: string = '';
  @StorageProp('rxKind') rxKind: string = 'harmonymic';
  @State rxKindDraft: string = 'harmonymic';
  @State liveOpen: boolean = false;
  @State cfgPopOpen: boolean = false;
  @State topPad: number = 0;
  @State bottomPad: number = 0;
  @State dockWidth: number = 0;
  // 说明: dock 材质以被观察状态持有，保证 Tabs（重）建时读取最新实例；
  // 原生页签栏不支持 systemMaterial 热替换，材质变化须经 tabsEpoch 重建子树生效。
  @State barMat: uiMaterial.ImmersiveMaterial = Mat.bar;
  // 说明: 翻转本值即销毁重建 Tabs 子树（if/else 分支切换）——
  // dock 材质在档位/主题变化时随新树创建生效。
  @State tabsEpoch: number = 0;
  private barDark: boolean = false;
  private startLock: boolean = false;
  private darkQuery: mediaquery.MediaQueryListener | null = null;
  private systemDark: boolean = false;
  private svc: StreamService = StreamService.getInstance();

  aboutToAppear(): void {
    this.refreshLocalIp();
    this.svc.hasWelcomed().then((seen: boolean) => {
      if (seen) {
        this.welcomed = 1;
      } else {
        this.welcomed = 0;
      }
    });
    const listener = this.getUIContext().getMediaQuery().matchMediaSync('(prefers-color-scheme: dark)');
    this.systemDark = listener.matches;
    listener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.systemDark = result.matches;
      this.syncBarMaterial();
      this.restoreSystemBar();
    });
    this.darkQuery = listener;
    this.restoreSystemBar();
    // 说明: dock 栏材质随主题（浅色加厚）——aboutToAppear 先于首帧 build 校准。
    this.syncBarMaterial();
    this.queryAvoidPads();
  }

  aboutToDisappear(): void {
    if (this.darkQuery !== null) {
      this.darkQuery.off('change');
      this.darkQuery = null;
    }
  }

  private refreshLocalIp(): void {
    this.localIp = '...';
    NetInfoService.getInstance().getLocalIp().then((ip: string) => {
      this.localIp = ip;
    });
  }

  private openLive(): void {
    MicLogger.info('openLive');
    this.liveOpen = true;
    MicLogger.info(`liveOpen set: ${this.liveOpen}`);
  }

  private closeLive(): void {
    MicLogger.info('closeLive');
    this.liveOpen = false;
    this.restoreSystemBar();
  }

  private currentDark(): boolean {
    if (this.themeMode === 1) {
      return false;
    }
    if (this.themeMode === 2) {
      return true;
    }
    return this.systemDark;
  }

  private restoreSystemBar(): void {
    UiEnvService.getInstance().setSystemBarLightContent(this.currentDark());
  }

  // 说明: dock 材质刷新唯一入口——先按主题重建 Mat.bar（浅色加厚/深色保持），
  // 再写入被观察的 barMat；主题实际翻转时重建 Tabs 子树让原生页签栏读到新材质
  //（原生不支持 systemMaterial 热替换，仅属性更新不重绘）。
  private syncBarMaterial(): void {
    const dark = this.currentDark();
    Mat.setBarTheme(dark);
    this.barMat = Mat.bar;
    if (dark !== this.barDark) {
      this.barDark = dark;
      this.tabsEpoch = this.tabsEpoch + 1;
    }
  }

  private onThemeModeChanged(): void {
    this.syncBarMaterial();
    this.restoreSystemBar();
  }

  // 说明: 档位切换时 setMaterialLevel 已先重建 Mat.bar（applyLevel→rebuildBar）；
  // 深色下柔和=标准为同厚度，重建无视觉差异但统一重建（用户显式操作，代价可接受）。
  private onMaterialLevelChanged(): void {
    this.barMat = Mat.bar;
    this.tabsEpoch = this.tabsEpoch + 1;
  }

  // 说明: 状态栏已隐藏，顶部以挖孔避让区、底部以导航/手势避让区为准补偿内边距
  // （顶部防首卡被挖孔遮挡；底部防 dock 贴屏底/内容滚入手势区）。
  private queryAvoidPads(): void {
    const ui = this.getUIContext();
    const hostCtx = ui.getHostContext();
    if (hostCtx === undefined) {
      return;
    }
    window.getLastWindow(hostCtx)
      .then((win: window.Window) => {
        const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const cut = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
        this.topPad = Math.max(ui.px2vp(sys.topRect.height), ui.px2vp(cut.topRect.height));
        this.bottomPad = Math.max(ui.px2vp(sys.bottomRect.height), ui.px2vp(cut.bottomRect.height));
        // 说明: 官方 FloatingTabBarWidth 不支持百分比（tabs.d.ts:785），
        // dock 宽度改运行时按窗口宽计算——铺满屏宽、左右各留 barSideMargin(16)。
        this.dockWidth = Math.max(0, ui.px2vp(win.getWindowProperties().windowRect.width) - 32);
      })
      .catch((): void => {
        // 窗口获取失败时保持 0，由基础内边距兜底
      });
  }

  // 说明: dock 铺满屏宽留边距（官方 barWidth 不支持百分比，运行时算 vp 值）；
  // 窗口宽度查询完成前用通用手机宽兜底，查询完成后状态驱动刷新为精确值。
  private dockBarWidth(): number {
    if (this.dockWidth > 0) {
      return this.dockWidth;
    }
    return 356;
  }

  // 说明: 官方 FAQ 口径——卡片不在 systemMaterial 生效范围（仅标题栏/底部 TabBar/弹窗类），
  // 卡面玻璃感由背景模糊承载：柔和不模糊、标准薄模糊、浓郁厚模糊，半透明字面色叠在模糊之上。
  private matCardBlur(): BlurStyle {
    if (this.materialLevel === 0) {
      return BlurStyle.NONE;
    }
    if (this.materialLevel === 2) {
      return BlurStyle.COMPONENT_THICK;
    }
    return BlurStyle.COMPONENT_THIN;
  }

  // 说明: 卡面字面色随沉浸光感档位联动（柔和更实/浓郁更透），叠在背景模糊之上构成毛玻璃。
  private matCardColor(): Resource {
    if (this.materialLevel === 0) {
      return $r('app.color.mat_card_soft');
    }
    if (this.materialLevel === 2) {
      return $r('app.color.mat_card_rich');
    }
    return $r('app.color.mat_card');
  }

  private async doStart(): Promise<void> {
    if (this.startLock) {
      return;
    }
    this.startLock = true;
    const result = await this.svc.start(this.ipInput, this.portInput);
    this.startLock = false;
    MicLogger.info(`doStart result: ${result}`);
    if (result === StartResult.OK) {
      this.openLive();
    } else {
      try {
        this.getUIContext().getPromptAction().showToast({
          message: StreamService.resultText(result),
          duration: 2500,
          systemMaterial: Mat.toast
        });
      } catch (error) {
        // 提示展示失败时忽略，不影响主流程
      }
    }
  }

  private buttonLabel(): string {
    if (this.streamBusy === 'running') {
      return '进入直播';
    }
    if (this.streamBusy === 'starting') {
      return '连接中';
    }
    if (this.streamBusy === 'restarting') {
      return '切换中';
    }
    return '连接';
  }

  private buttonSubLabel(): string {
    if (this.streamBusy === 'running') {
      return '串流进行中';
    }
    if (this.streamBusy === 'starting') {
      return '正在连接';
    }
    if (this.streamBusy === 'restarting') {
      return '参数切换中';
    }
    return '开始串流';
  }

  private buttonEnabled(): boolean {
    return this.streamBusy === 'idle' && !this.probing && this.netOnline;
  }

  private onMainButton(): void {
    if (this.streamBusy === 'running') {
      this.openLive();
      return;
    }
    if (this.streamBusy === 'idle' && !this.probing && this.netOnline) {
      this.doStart();
    }
  }

  // 说明: 本软件仅内网（LAN/WiFi）连接——DeviceCard 只显示 WiFi 质量与本机 WiFi IP，
  // 蜂窝承载不显示质量与 IP（蜂窝 IP 对内网串流无意义）。
  private wifiIpDisplay(): string {
    if (this.netBearer !== 'wifi') {
      return '未连接 WiFi';
    }
    return this.localIp;
  }

  private wifiIpColor(): Resource {
    return this.netBearer === 'wifi' ? $r('app.color.accent') : $r('app.color.text_hint');
  }

  private qualityLabel(): string {
    if (this.netQuality === 'good') {
      return '优';
    }
    if (this.netQuality === 'fair') {
      return '中';
    }
    return '弱';
  }

  private qualityColor(): string {
    if (this.netQuality === 'good') {
      return '#34C759';
    }
    if (this.netQuality === 'fair') {
      return '#FF9500';
    }
    return '#FF6A6A';
  }

  private qualityBgColor(): string {
    if (this.netQuality === 'good') {
      return '#2434C759';
    }
    if (this.netQuality === 'fair') {
      return '#24FF9500';
    }
    return '#24FF6A6A';
  }

  private miniTitle(): string {
    if (this.streamBusy === 'running') {
      return '正在直播';
    }
    if (this.streamBusy === 'starting') {
      return '正在连接';
    }
    return '参数切换中';
  }

  private openSheet(): void {
    this.ipDraft = this.ipInput;
    this.portDraft = this.portInput;
    this.rxKindDraft = this.rxKind;
    this.sheetError = '';
    this.sheetOpen = true;
  }

  // 说明: 接收端类型切换——端口默认值联动（9000↔9123），用户已手改端口则保留。
  private pickRxKind(kind: string): void {
    if (this.rxKindDraft === kind) {
      return;
    }
    if (kind === 'micyou' && this.portDraft === '9000') {
      this.portDraft = '9123';
    } else if (kind === 'harmonymic' && this.portDraft === '9123') {
      this.portDraft = '9000';
    }
    this.rxKindDraft = kind;
    this.sheetError = '';
  }

  private confirmSheet(): void {
    this.svc.updateEndpoint(this.ipDraft, this.portDraft).then((ok: boolean) => {
      if (ok) {
        this.svc.setRxKind(this.rxKindDraft);
        this.sheetOpen = false;
      } else {
        this.sheetError = 'IP 或端口不合法';
      }
    });
  }

  @Builder
  OccupiedBanner() {
    if (this.micOccupied) {
      Row({ space: 10 }) {
        Text('麦克风被其他应用占用')
          .fontSize(13)
          .fontColor($r('app.color.danger'))
          .layoutWeight(1)
        Text('重试')
          .fontSize(13)
          .fontColor($r('app.color.btn_selected_text'))
          .height(40)
          .padding({ left: 14, right: 14 })
          .borderRadius(20)
          .backgroundColor($r('app.color.danger'))
          .onClick(() => {
            this.doStart();
          })
      }
      .width('100%')
      .padding(12)
      .borderRadius(15)
      .border({ width: 1, color: $r('app.color.danger') })
      .backgroundColor($r('app.color.card_bg'))
    }
  }

  @Builder
  OfflineBanner() {
    if (!this.netOnline) {
      Row({ space: 8 }) {
        Text('网络不可用 · 请检查 WiFi 或数据连接')
          .fontSize(12)
          .fontColor($r('app.color.text_warn'))
          .layoutWeight(1)
          .maxLines(1)
      }
      .width('100%')
      .padding(10)
      .borderRadius(12)
      .border({ width: 1, color: '#FF9500' })
    }
  }

  @Builder
  DeviceCard() {
    Row({ space: 12 }) {
      // 说明: layered 图标在应用内合成（背景层+前景层，暗色自动取 dark\media\foreground）——
      // 复刻启动器应用图标外观。
      Stack() {
        Image($r('app.media.background'))
          .width(44)
          .height(44)
        Image($r('app.media.foreground'))
          .width(44)
          .height(44)
      }
      .width(44)
      .height(44)
      .borderRadius(10)
      .clip(true)
      Column({ space: 2 }) {
        Text('VoxBridge')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text('手机 → PC 网络麦克风')
          .fontSize(12)
          .fontColor($r('app.color.text_subtitle'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Column({ space: 2 }) {
        Text('本机 WiFi IP')
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
        Text(this.wifiIpDisplay())
          .fontSize(12)
          .fontColor(this.wifiIpColor())
          .maxLines(1)
          .constraintSize({ maxWidth: 120 })
        Row({ space: 6 }) {
          if (this.netBearer === 'wifi') {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.wifi'))
                .fontSize(10)
                .fontColor([$r('app.color.text_secondary')])
              Text('WiFi')
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
            }
            .height(17)
            .padding({ left: 8, right: 8 })
            .borderRadius(9)
            .backgroundColor($r('app.color.btn_unselected_bg'))
            Row({ space: 4 }) {
              Circle({ width: 5, height: 5 })
                .fill(this.qualityColor())
              Text(this.qualityLabel())
                .fontSize(10)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.qualityColor())
            }
            .height(17)
            .padding({ left: 8, right: 8 })
            .borderRadius(9)
            .backgroundColor(this.qualityBgColor())
          } else {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.wifi'))
                .fontSize(10)
                .fontColor([$r('app.color.text_hint')])
              Text('WiFi 未连接')
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
            }
            .height(17)
            .padding({ left: 8, right: 8 })
            .borderRadius(9)
            .backgroundColor($r('app.color.btn_unselected_bg'))
          }
        }
        .margin({ top: 5 })
      }
      .alignItems(HorizontalAlign.End)
      .padding(8)
      .onClick(() => {
        this.refreshLocalIp();
      })
    }
    .width('100%')
    .padding(14)
    .borderRadius(15)
    .backgroundBlurStyle(this.matCardBlur())
    .backgroundColor(this.matCardColor())
    .border({ width: 1, color: $r('app.color.mat_line') })
    .systemMaterial(Mat.card)
  }

  // 说明: 弹出/收起必须包在 animateTo 内——geometryTransition 边界过渡依赖同一动画批次内的出现/消失。
  private openCfgPop(): void {
    this.getUIContext().animateTo({ duration: 350, curve: curves.springMotion(0.42, 0.88) }, (): void => {
      this.cfgPopOpen = true;
    });
  }

  private closeCfgPop(): void {
    this.getUIContext().animateTo({ duration: 350, curve: curves.springMotion(0.42, 0.88) }, (): void => {
      this.cfgPopOpen = false;
    });
  }

  @Builder
  ConfigCard() {
    // 说明: 弹出期间入口行卸载（geometryTransition 要求同 id 组件互斥出现），
    // 容器塌陷为零高——下方卡片随 animateTo 弹簧补位上移，收回时挤回原位。
    Column() {
      if (!this.cfgPopOpen) {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text('连接配置')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text('音源 · 参数 · 降噪')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          if (this.probing) {
            Text('检测中...')
              .fontSize(12)
              .fontColor($r('app.color.text_warn'))
          }
          Text('›')
            .fontSize(18)
            .fontColor($r('app.color.text_hint'))
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding(12)
        .borderRadius(15)
        .backgroundBlurStyle(this.matCardBlur())
        .backgroundColor(this.matCardColor())
        .border({ width: 1, color: $r('app.color.mat_line') })
        .systemMaterial(Mat.card)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
        // 说明: 与弹出卡共享几何转场 id——打开时弹出卡从本行边界生长，关闭时缩回原位。
        .geometryTransition('cfgPopGeo')
        .transition(TransitionEffect.OPACITY.animation({ duration: 250, curve: curves.springMotion(0.4, 0.85) }))
        .onClick(() => {
          this.openCfgPop();
        })
      }
    }
    .width('100%')
  }

  // 说明: 弹出式配置卡遮罩——点击空白关闭；与卡体分离为根 Stack 平级子节点，
  // 卡体容器 HitTestMode.Transparent 让空白区命中遮罩、卡内不误关。
  @Builder
  CfgPopDim() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#66000000')
      .transition(TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseOut }))
      .onClick(() => {
        this.closeCfgPop();
      })
  }

  @Builder
  CfgPopCard() {
    Column() {
      Column() {
        Row({ space: 8 }) {
          Text('连接配置')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Text('✕')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
            .borderRadius(16)
            .backgroundColor($r('app.color.btn_unselected_bg'))
            .onClick(() => {
              this.closeCfgPop();
            })
        }
        .width('100%')
        .height(44)

        ConfigSections({ showEq: false, segmentMode: true, segmentFlat: true })
      }
      .width('100%')
      .padding(14)
      .borderRadius(20)
      .backgroundBlurStyle(this.matCardBlur())
      .backgroundColor(this.matCardColor())
      .border({ width: 1, color: $r('app.color.mat_line') })
      .systemMaterial(Mat.card)
      // 说明: 与入口行共享几何转场 id（互斥出现）——卡体从点击位置边界生长/缩回，内容随 OPACITY 交叉淡化。
      .geometryTransition('cfgPopGeo')
      .transition(TransitionEffect.OPACITY.animation({ duration: 250, curve: curves.springMotion(0.4, 0.85) }))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 20, right: 20, top: this.topPad + 20, bottom: this.bottomPad + 20 })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  ConnectButton() {
    Column({ space: 2 }) {
      Text(this.buttonLabel())
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
      Text(this.buttonSubLabel())
        .fontSize(12)
        .fontColor(Color.White)
        .opacity(0.85)
    }
    .width(96)
    .height(96)
    .borderRadius(48)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.streamBusy === 'running' ? $r('app.color.live_green') : $r('app.color.accent'))
    .shadow({
      radius: 26,
      offsetY: 10,
      color: this.streamBusy === 'running' ? '#5934C759' : '#59007AFF'
    })
    .opacity(this.buttonEnabled() ? 1 : 0.45)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .onClick(() => {
      this.onMainButton();
    })
  }

  @Builder
  ConnectCard() {
    Column({ space: 14 }) {
      Row({ space: 6 }) {
        Text('目标端点')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Text(`${this.ipInput}:${this.portInput}`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
        Text('›')
          .fontSize(16)
          .fontColor($r('app.color.text_hint'))
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height(44)
      .onClick(() => {
        this.openSheet();
      })
      this.ConnectButton()
      Text(this.statConn)
        .fontSize(12)
        .fontColor($r('app.color.text_hint'))
    }
    .width('100%')
    .padding(16)
    .borderRadius(15)
    .backgroundBlurStyle(this.matCardBlur())
    .backgroundColor(this.matCardColor())
    .border({ width: 1, color: $r('app.color.mat_line') })
    .systemMaterial(Mat.card)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  EndpointSheet() {
    Column({ space: 14 }) {
      Text('编辑目标端点')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text('接收端类型')
        .fontSize(12)
        .fontColor($r('app.color.text_hint'))
        .width('100%')
      Row({ space: 8 }) {
        Text('VoxBridge 接收器')
          .fontSize(13)
          .height(40)
          .layoutWeight(1)
          .padding({ left: 6, right: 6 })
          .borderRadius(20)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .fontColor(this.rxKindDraft === 'harmonymic' ? $r('app.color.btn_selected_text') : $r('app.color.text_primary'))
          .backgroundColor(this.rxKindDraft === 'harmonymic' ? $r('app.color.accent') : $r('app.color.btn_unselected_bg'))
          .onClick(() => {
            this.pickRxKind('harmonymic');
          })
        Text('MicYou 桌面端')
          .fontSize(13)
          .height(40)
          .layoutWeight(1)
          .padding({ left: 6, right: 6 })
          .borderRadius(20)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .fontColor(this.rxKindDraft === 'micyou' ? $r('app.color.btn_selected_text') : $r('app.color.text_primary'))
          .backgroundColor(this.rxKindDraft === 'micyou' ? $r('app.color.accent') : $r('app.color.btn_unselected_bg'))
          .onClick(() => {
            this.pickRxKind('micyou');
          })
      }
      .width('100%')
      if (this.rxKindDraft === 'micyou') {
        Text('需在电脑安装 MicYou 桌面端（官方 Releases），与本机同一网络，默认端口 9123')
          .fontSize(11)
          .fontColor($r('app.color.text_hint'))
          .width('100%')
      }
      TextInput({ placeholder: 'PC 端 IP 地址', text: this.ipDraft })
        .onChange((value: string) => {
          this.ipDraft = value;
          this.sheetError = '';
        })
        .maxLength(15)
        .borderRadius(12)
        .width('100%')
      TextInput({ placeholder: '端口 (1-65535)', text: this.portDraft })
        .onChange((value: string) => {
          this.portDraft = value;
          this.sheetError = '';
        })
        .type(InputType.Number)
        .maxLength(5)
        .borderRadius(12)
        .width('100%')
      if (this.sheetError.length > 0) {
        Text(this.sheetError)
          .fontSize(12)
          .fontColor($r('app.color.danger'))
          .width('100%')
      }
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(50)
          .borderRadius(15)
          .backgroundColor($r('app.color.btn_unselected_bg'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.sheetOpen = false;
          })
        Button('保存')
          .layoutWeight(1)
          .height(50)
          .borderRadius(15)
          .backgroundColor($r('app.color.accent'))
          .onClick(() => {
            this.confirmSheet();
          })
      }
      .width('100%')
    }
    .padding(20)
    .width('100%')
  }

  // 说明: 底部 dock=真实 Tabs 悬浮页签（官方 arkts-immersive-light-sample 模式）——页签栏
  // 处于沉浸光感生效范围，systemMaterial 真实渲染，按压/划动有光感交互反馈（光流）。
  @Builder
  TabItem(index: number, label: string, activeIcon: Resource, inactiveIcon: Resource) {
    Column({ space: 3 }) {
      SymbolGlyph(this.currentTab === index ? activeIcon : inactiveIcon)
        .fontSize(25)
        .fontColor([this.currentTab === index ? $r('app.color.accent') : $r('app.color.text_secondary')])
      Text(label)
        .fontSize(10)
        .fontColor(this.currentTab === index ? $r('app.color.accent') : $r('app.color.text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onClick(() => {
      MicLogger.info(`tab tap: ${index}`);
      this.currentTab = index;
    })
  }

  @Builder
  MiniLiveBar() {
    Column() {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.waveform'))
          .fontSize(22)
          .fontColor([$r('app.color.live_green')])
        Column({ space: 2 }) {
          Text(this.miniTitle())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.statRecord)
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(20)
          .fontColor([$r('app.color.text_secondary')])
          .rotate({ angle: 180 })
      }
      .width('100%')
      .height(60)
      .padding({ left: 14, right: 14 })
      .borderRadius(15)
      .backgroundBlurStyle(this.matCardBlur())
      .backgroundColor(this.matCardColor())
      .border({ width: 1, color: $r('app.color.mat_line') })
      .systemMaterial(Mat.card)
      .transition(
        TransitionEffect.translate({ y: 40 })
          .combine(TransitionEffect.OPACITY)
          .animation({ curve: curves.springMotion(0.6, 0.85) })
      )
      .id('liveMiniBar')
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
      .onClick(() => {
        this.openLive();
      })
    }
    .width('100%')
    .padding({ left: 20, right: 20, bottom: this.bottomPad + TAB_BAR_H + 16 + 6 })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  LiveCover() {
    LiveView({ onExit: (): void => {
      this.closeLive();
    } })
  }

  @Builder
  MainTabs() {
    Tabs({ barPosition: BarPosition.End, index: $$this.currentTab }) {
      TabContent() {
        Scroll() {
          Column({ space: 12 }) {
            this.OfflineBanner()
            this.OccupiedBanner()
            this.DeviceCard()
            this.ConfigCard()
            this.ConnectCard()
          }
          .width('100%')
          .constraintSize({ maxWidth: 500 })
          .padding({ left: 20, right: 20, top: this.topPad + 20, bottom: this.bottomPad + 100 })
        }
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        .scrollable(ScrollDirection.Vertical)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
      .tabBar(this.TabItem(0, '连接', $r('sys.symbol.mic_fill'), $r('sys.symbol.mic')))
      TabContent() {
        SettingsView()
      }
      .tabBar(this.TabItem(1, '设置', $r('sys.symbol.gearshape_fill'), $r('sys.symbol.gearshape')))
    }
    .width('100%')
    .height('100%')
    .barMode(BarMode.Fixed)
    .barOverlap(true)
    .barHeight(TAB_BAR_H)
    .barFloatingStyle({
      barWidth: {
        smallBarWidth: this.dockBarWidth(),
        mediumBarWidth: this.dockBarWidth(),
        largeBarWidth: this.dockBarWidth()
      },
      barSideMargin: 16,
      barBottomMargin: this.bottomPad + 16,
      systemMaterial: this.barMat
    })
    .onChange((index: number) => {
      this.currentTab = index;
    })
    // 说明: LiveCover 宿主必须挂 Tabs 链——挂根 Stack 链真机两次实证无法打开（S4-RoundH 时代故障、Round V 误移回归）。
    // epoch 重建仅由主题翻转/材质档位切换触发（入口均在 Settings，cover 打开时不可达）；
    // 唯一边缘场景：跟随系统主题下系统自动换肤会令封面关闭，可接受。
    .bindContentCover($$this.liveOpen, this.LiveCover(), {
      modalTransition: ModalTransition.DEFAULT,
      onWillDismiss: (action: DismissContentCoverAction) => {
        action.dismiss();
        this.restoreSystemBar();
      },
      // 说明: 窗口级系统栏恢复必须在退出转场结束后执行（onDisappear=动画结束回调）——
      // 若在转场起点（aboutToDisappear/onWillDismiss）调 setWindowSystemBarEnable，
      // WMS 避让区重算与转场动画并发，导航条区域沉浸会短暂失效（露窗口底色）+底部布局抖动。
      onDisappear: () => {
        this.restoreSystemBar();
        UiEnvService.getInstance().hideSystemBar();
      }
    })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.welcomed === 1) {
        // 说明: 原生页签栏材质不支持热替换——epoch 翻转经 if/else 分支切换销毁重建 Tabs 子树。
        if (this.tabsEpoch % 2 === 0) {
          this.MainTabs()
        } else {
          this.MainTabs()
        }
        if (this.streamBusy !== 'idle') {
          this.MiniLiveBar()
        }
        // 说明: 连接配置弹出层——挂根 Stack 平级子节点（同 MiniLiveBar 形态），
        // 弃 bindContentCover（根 Stack 链宿主真机无法打开，同 LiveCover 宿主约束）。
        if (this.cfgPopOpen) {
          this.CfgPopDim()
          this.CfgPopCard()
        }
      }
      if (this.welcomed === 0) {
        WelcomeView({ onDone: (): void => {
          this.welcomed = 1;
        } })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .radialGradient({
      center: ['50%', '12%'],
      radius: '80%',
      colors: [[$r('app.color.bg_glow'), 0], [$r('app.color.page_bg'), 1]]
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.sheetOpen, this.EndpointSheet(), {
      height: 460,
      dragBar: true,
      showClose: false,
      backgroundColor: Color.Transparent,
      systemMaterial: Mat.sheet
    })
  }
}
