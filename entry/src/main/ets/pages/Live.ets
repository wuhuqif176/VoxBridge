import { window, mediaquery } from '@kit.ArkUI';
import { StreamService, StartResult } from '../services/StreamService';
import { UiEnvService } from '../services/UiEnvService';
import { MicLogger } from 'common';
import { ConfigSections } from '../component/ConfigSections';
import { Mat } from '../component/Materials';
import { VizPanel } from '../component/VizPanel';
import { VizView } from './VizPage';
const LIVE_CONTENT_FADE_MS = 220;

const LIVE_CONTENT_FADE_DELAY_MS = 130;

// 说明: 入场 stagger 步进——状态区/控制区在上栏之后依次延迟浮现，形成错落节奏。
const LIVE_STAGGER_STEP_MS = 60;

// 说明: 播放器式固定深色组件，由 Connect 以 bindContentCover 全屏承载（F1 一镜到底）。
// 白字与 60% 白为固定色值，不随主题切换；状态行在 @Builder 内直接读取 this 状态，保证 500ms 状态刷新即时生效。
// VizCard 为 geometryTransition('liveCard') 的 anchor 端，与 Connect 的 mini 条（follow 端）成对实现一镜到底。
@Component
export struct LiveView {
  @StorageLink('pcIp') hostIp: string = '';
  @StorageLink('pcPort') hostPort: string = '9000';
  @StorageLink('vizMuted') muted: boolean = false;
  @StorageProp('vizStreaming') streaming: boolean = false;
  @StorageProp('micOccupied') micOccupied: boolean = false;
  @StorageProp('statConn') statConn: string = '未连接';
  @StorageProp('statRecord') statRecord: string = '空闲';
  @StorageProp('statBytes') statBytes: string = '0 B';
  @StorageProp('statQueue') statQueue: string = '队列 0 块 · 丢弃 0 块';
  @StorageProp('netQuality') netQuality: string = 'good';
  @StorageProp('rateDowngraded') rateDowngraded: boolean = false;
  @StorageProp('statElapsedSec') elapsedSec: number = 0;
  @State configOpen: boolean = false;
  @State vizOpen: boolean = false;
  @State liveDotScale: number = 1;
  @State liveDotRingOpacity: number = 0.55;
  @State topPad: number = 0;
  @State leftPad: number = 0;
  @State rightPad: number = 0;
  @State landCardH: number = 260;
  @State isLandscape: boolean = false;
  onExit: () => void = (): void => {};
  private actionLock: boolean = false;
  private orientationQuery: mediaquery.MediaQueryListener | null = null;
  private topPadWin: window.Window | null = null;
  private svc: StreamService = StreamService.getInstance();

  aboutToAppear(): void {
    MicLogger.info('LiveView appear');
    UiEnvService.getInstance().setSystemBarLightContent(true);
    this.showBarThenQueryTopPad();
    this.orientationQuery = this.getUIContext().getMediaQuery().matchMediaSync('(orientation: landscape)');
    this.isLandscape = this.orientationQuery.matches;
    this.orientationQuery.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isLandscape = result.matches;
    });
  }

  // 说明: 显示系统状态栏（时间可见）后再取避让高度，确保顶栏内容不覆盖状态栏文字区域。
  private async showBarThenQueryTopPad(): Promise<void> {
    await UiEnvService.getInstance().showSystemBar();
    this.queryTopPad();
  }

  // 说明: 状态栏已显示，以 TYPE_SYSTEM/TYPE_CUTOUT 避让高度补偿内边距；
  // setWindowSystemBarEnable 与避让区更新存在时序差，注册 avoidAreaChange 监听保证 topPad 最终一致。
  private queryTopPad(): void {
    const ui = this.getUIContext();
    const hostCtx = ui.getHostContext();
    if (hostCtx === undefined) {
      return;
    }
    window.getLastWindow(hostCtx)
      .then((win: window.Window) => {
        this.applyTopPad(win);
        if (this.topPadWin === null) {
          this.topPadWin = win;
          win.on('avoidAreaChange', (): void => {
            this.applyTopPad(win);
          });
        }
      })
      .catch((): void => {
        // 窗口获取失败时保持 0，由基础内边距兜底
      });
  }

  private applyTopPad(win: window.Window): void {
    const ui = this.getUIContext();
    const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const cut = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
    this.topPad = Math.max(ui.px2vp(sys.topRect.height), ui.px2vp(cut.topRect.height));
    // 说明: 横屏下左右避让（曲面屏边缘/侧边状态栏）由 leftPad/rightPad 补偿，配合 expandSafeArea 保证内容不贴死屏幕边缘。
    const lp = Math.max(ui.px2vp(sys.leftRect.width), ui.px2vp(cut.leftRect.width));
    const rp = Math.max(ui.px2vp(sys.rightRect.width), ui.px2vp(cut.rightRect.width));
    if (lp !== this.leftPad) {
      this.leftPad = lp;
    }
    if (rp !== this.rightPad) {
      this.rightPad = rp;
    }
  }

  aboutToDisappear(): void {
    const win = this.topPadWin;
    if (win !== null) {
      win.off('avoidAreaChange');
      this.topPadWin = null;
    }
    if (this.orientationQuery !== null) {
      this.orientationQuery.off('change');
      this.orientationQuery = null;
    }
    // 说明: 恢复沉浸（hideSystemBar）由宿主 bindContentCover onDisappear 执行——
    // aboutToDisappear 在退出转场起点触发，窗口级 setWindowSystemBarEnable 与转场并发
    // 会令导航条区域沉浸失效+底部布局抖动（WMS 避让区重算与转场动画互踩中间帧暴露）。
  }

  private hostText(): string {
    return `${this.hostIp}:${this.hostPort}`;
  }

  // 说明: 直播时长 mm:ss（数据源 statElapsedSec，publishStats 500ms 周期刷新）。
  private elapsedText(): string {
    const total = Math.max(0, Math.floor(this.elapsedSec));
    const mm = Math.floor(total / 60);
    const ss = total % 60;
    const mmText = mm < 10 ? `0${mm}` : `${mm}`;
    const ssText = ss < 10 ? `0${ss}` : `${ss}`;
    return `${mmText}:${ssText}`;
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

  private qualityChipText(): string {
    if (this.netQuality === 'weak' && this.rateDowngraded) {
      return `网络 弱 · 已降级 16kHz`;
    }
    return `网络 ${this.qualityLabel()}`;
  }

  private qualityChipBg(): string {
    if (this.netQuality === 'good') {
      return 'rgba(52,199,89,0.1)';
    }
    if (this.netQuality === 'fair') {
      return 'rgba(255,149,0,0.1)';
    }
    return 'rgba(255,106,106,0.1)';
  }

  // 说明: VizPage 全屏视图以 Stack overlay 承载（弃嵌套 bindContentCover——
  // cover 内再挂 bindContentCover 真机无法打开，与根 Stack 链宿主失败同源），OPACITY 过渡等价 modalTransition ALPHA。
  private openViz(): void {
    this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseOut }, (): void => {
      this.vizOpen = true;
    });
  }

  private closeViz(): void {
    this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseIn }, (): void => {
      this.vizOpen = false;
    });
  }

  private toggleMute(): void {
    this.muted = !this.muted;
  }

  private onClipTap(): void {
    this.svc.getVizManager().clearClipLatch();
  }

  private async doDisconnect(): Promise<void> {
    if (this.actionLock) {
      return;
    }
    this.actionLock = true;
    await this.svc.stop();
    this.actionLock = false;
    this.onExit();
  }

  private async retryStart(): Promise<void> {
    if (this.actionLock) {
      return;
    }
    this.actionLock = true;
    const result = await this.svc.start(this.hostIp, this.hostPort);
    this.actionLock = false;
    if (result !== StartResult.OK) {
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

  @Builder
  TopBar() {
    Row() {
      Column() {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(26)
          .fontColor(['#99FFFFFF'])
      }
      .width(48)
      .height(48)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.onExit();
      })
      Text('直播')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .margin({ left: 4 })
      Blank()
      Text(this.hostText())
        .fontSize(12)
        .fontColor('#99FFFFFF')
        .maxLines(1)
        .constraintSize({ maxWidth: 150 })
    }
    .width('100%')
    .height(56)
    .margin({ top: this.topPad })
    .padding({ left: 8, right: 16 })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 12 }))
      .animation({ duration: LIVE_CONTENT_FADE_MS, delay: LIVE_CONTENT_FADE_DELAY_MS }))
  }

  @Builder
  OccupiedBanner() {
    if (this.micOccupied) {
      Row({ space: 10 }) {
        Text('麦克风被其他应用占用')
          .fontSize(13)
          .fontColor(Color.White)
          .layoutWeight(1)
        Text('重试')
          .fontSize(13)
          .fontColor(Color.White)
          .height(40)
          .padding({ left: 14, right: 14 })
          .borderRadius(20)
          .backgroundColor($r('app.color.danger'))
          .onClick(() => {
            this.retryStart();
          })
      }
      .width('100%')
      .padding(12)
      .borderRadius(15)
      .border({ width: 1, color: $r('app.color.danger') })
      .backgroundColor('#33FF6A6A')
    }
  }

  @Builder
  VizCard() {
    Stack({ alignContent: Alignment.TopEnd }) {
      VizPanel({ viz: this.svc.getVizManager(), canvasHeight: this.isLandscape ? this.landCardH : 348, forceDark: true })
      Column({ space: 10 }) {
        Column() {
          SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
            .fontSize(22)
            .fontWeight(FontWeight.Lighter)
            .fontColor([Color.White])
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
        .justifyContent(FlexAlign.Center)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.8 })
        .onClick(() => {
          this.openViz();
        })
      }
      .margin(12)
      Text('CLIP')
        .fontSize(8)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FF6A6A')
        .letterSpacing(1)
        .height(16)
        .padding({ left: 8, right: 8 })
        .borderRadius(8)
        .border({ width: 1, color: 'rgba(255,106,106,0.4)' })
        .backgroundColor('rgba(255,106,106,0.15)')
        .margin({ top: 14, right: 66 })
        .onClick(() => {
          this.onClipTap();
        })
    }
    .width('100%')
    .borderRadius(15)
    .border({ width: 1, color: 'rgba(255,255,255,0.09)' })
    .systemMaterial(Mat.viz)
    .clip(true)
    .transition(TransitionEffect.opacity(0.99))
    .id('liveVizCard')
  }

  // 说明: LIVE 呼吸灯（流式中扩散涟漪+实心点），竖屏状态区与横屏右栏共用同一动画状态。
  @Builder
  LiveDot() {
    Stack() {
      Circle({ width: 8, height: 8 })
        .fill('rgba(52,199,89,0.55)')
        .scale({ x: this.liveDotScale, y: this.liveDotScale })
        .opacity(this.streaming ? this.liveDotRingOpacity : 0)
      Circle({ width: 8, height: 8 })
        .fill(this.streaming ? $r('app.color.live_green') : '#66FFFFFF')
    }
    .width(8)
    .height(8)
    .onAppear(() => {
      this.getUIContext().animateTo({
        duration: 1600,
        curve: Curve.EaseOut,
        iterations: -1,
        playMode: PlayMode.Normal
      }, (): void => {
        this.liveDotScale = 2.75;
        this.liveDotRingOpacity = 0;
      });
    })
  }

  @Builder
  LiveLabel() {
    Row({ space: 6 }) {
      this.LiveDot()
      Text(this.streaming ? 'LIVE' : '未连接')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.streaming ? $r('app.color.live_green') : '#99FFFFFF')
    }
    .height(20)
  }

  @Builder
  StatusBlock() {
    Column({ space: 6 }) {
      this.LiveLabel()

      Text(this.statRecord)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .maxLines(1)

      Text(this.statConn)
        .fontSize(12)
        .fontColor('#99FFFFFF')
        .maxLines(1)

      Text(`${this.statBytes} · ${this.statQueue}`)
        .fontSize(12)
        .fontColor('#66FFFFFF')
        .maxLines(1)

      Row({ space: 5 }) {
        Circle({ width: 6, height: 6 })
          .fill(this.qualityColor())
        Text(this.qualityChipText())
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.qualityColor())
      }
      .height(20)
      .padding({ left: 10, right: 10 })
      .borderRadius(10)
      .backgroundColor(this.qualityChipBg())
      .margin({ top: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 12 }))
      .animation({ duration: LIVE_CONTENT_FADE_MS, delay: LIVE_CONTENT_FADE_DELAY_MS + LIVE_STAGGER_STEP_MS }))
  }

  @Builder
  ControlRow() {
    Row() {
      Column() {
        Row({ space: 5 }) {
          Circle({ width: 4.5, height: 4.5 })
            .fill(Color.White)
          Circle({ width: 4.5, height: 4.5 })
            .fill(Color.White)
          Circle({ width: 4.5, height: 4.5 })
            .fill(Color.White)
        }
        .justifyContent(FlexAlign.Center)
      }
      .width(48)
      .height(48)
      .justifyContent(FlexAlign.Center)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.8 })
      .onClick(() => {
        this.configOpen = true;
      })

      Stack() {
        SymbolGlyph($r('sys.symbol.phone_down_fill'))
          .fontSize(26)
          .fontColor([Color.White])
      }
      .width(64)
      .height(64)
      .borderRadius(32)
      .backgroundColor($r('app.color.danger'))
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .onClick(() => {
        this.doDisconnect();
      })

      Column() {
        SymbolGlyph(this.muted ? $r('sys.symbol.speaker_slash') : $r('sys.symbol.speaker'))
          .fontSize(26)
          .fontColor([this.muted ? $r('app.color.danger') : Color.White])
      }
      .width(48)
      .height(48)
      .justifyContent(FlexAlign.Center)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.8 })
      .onClick(() => {
        this.toggleMute();
      })
    }
    .width(this.isLandscape ? '100%' : '76%')
    .margin({ bottom: this.isLandscape ? 28 : 46 })
    .justifyContent(FlexAlign.SpaceBetween)
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 14 }))
      .animation({ duration: LIVE_CONTENT_FADE_MS, delay: LIVE_CONTENT_FADE_DELAY_MS + LIVE_STAGGER_STEP_MS * 2 }))
  }

  @Builder
  ConfigSheet() {
    Column() {
      Text('音频配置')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#F0F0F2')
        .width('100%')
        .height(56)
        .padding({ left: 20, right: 20 })
      Scroll() {
        Column() {
          ConfigSections({ forceDark: true })
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 32 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollable(ScrollDirection.Vertical)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  VizCover() {
    VizView({ onExit: (): void => {
      this.closeViz();
    } })
    .transition(TransitionEffect.OPACITY)
  }

  // 说明: 横屏布局——左右分栏约 6:4：左侧 VizCard 上下左右居中（频谱随区域自适应填满，卡内底部保留电平条），
  // 右侧信息与控制中心（顶部标题+IP / 中部 LIVE 灯+时长+参数 / 底部三控制按钮）；
  // 左右 SafeArea 边距由 leftPad/rightPad（避让区实测）+expandSafeArea(LEFT/RIGHT) 保证不贴死屏幕边缘。
  @Builder
  LandscapeBody() {
    Row() {
      Column() {
        this.VizCard()
      }
      .layoutWeight(6)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ right: 16 })
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const h = newArea.height;
        if (typeof h === 'number' && h > 200) {
          const target = Math.max(140, Math.min(460, h - 42));
          if (Math.abs(target - this.landCardH) > 1) {
            this.landCardH = target;
          }
        }
      })

      Column() {
        Row() {
          Column() {
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(24)
              .fontColor(['#99FFFFFF'])
          }
          .width(40)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.onExit();
          })
          Text('直播')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .margin({ left: 2 })
          Blank()
          Text(this.hostText())
            .fontSize(11)
            .fontColor('#99FFFFFF')
            .maxLines(1)
            .constraintSize({ maxWidth: 140 })
        }
        .width('100%')
        .height(48)
        .margin({ top: this.topPad })
        .alignItems(VerticalAlign.Center)

        Column({ space: 6 }) {
          this.LiveLabel()
          Text(this.elapsedText())
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .maxLines(1)
          Text(this.statRecord)
            .fontSize(12)
            .fontColor('#99FFFFFF')
            .maxLines(1)
          Row({ space: 5 }) {
            Circle({ width: 6, height: 6 })
              .fill(this.qualityColor())
            Text(this.qualityChipText())
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.qualityColor())
          }
          .height(20)
          .padding({ left: 10, right: 10 })
          .borderRadius(10)
          .backgroundColor(this.qualityChipBg())
          .margin({ top: 4 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)

        this.ControlRow()
      }
      .layoutWeight(4)
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .padding({
      left: Math.max(20, this.leftPad),
      right: Math.max(20, this.rightPad)
    })
  }

  @Builder
  PortraitBody() {
    Column() {
      this.TopBar()
      Scroll() {
        Column({ space: 16 }) {
          this.OccupiedBanner()
          this.VizCard()
          this.StatusBlock()
        }
        .width('100%')
        .constraintSize({ maxWidth: 500 })
        .padding({ left: 20, right: 20, top: 4, bottom: 32 })
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollable(ScrollDirection.Vertical)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
      this.ControlRow()
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      if (this.isLandscape) {
        this.LandscapeBody()
      } else {
        this.PortraitBody()
      }

      if (this.vizOpen) {
        this.VizCover()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FF000000')
    .radialGradient({
      center: ['50%', '0%'],
      radius: '120%',
      colors: [['#FF151C2C', 0], ['#FF000000', 1]]
    })
    .expandSafeArea([SafeAreaType.SYSTEM], this.isLandscape
      ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END]
      : [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.configOpen, this.ConfigSheet(), {
      preferType: SheetType.CENTER,
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: '#FF1E1E20'
    })
  }
}
