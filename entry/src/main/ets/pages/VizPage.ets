import { window, mediaquery, curves } from '@kit.ArkUI';
import { displaySync } from '@kit.ArkGraphics2D';
import { AudioVizManager } from 'common';
import { VizRenderer, fmtDb } from '../component/VizRenderer';
import { VizDock } from '../component/VizDock';

@Component
export struct VizView {
  @StorageProp('vizStreaming') streaming: boolean = false;
  @StorageProp('vizNrActive') nrActive: boolean = false;
  @StorageLink('vizMode') @Watch('onModeChange') vizMode: number = 0;
  @StorageLink('vizMuted') muted: boolean = false;
  @State rmsText: string = '--';
  @State peakText: string = '--';
  @State clipWarn: boolean = false;
  @State preRms: string = '--';
  @State prePeak: string = '--';
  @State preTp: string = '--';
  @State postTp: string = '--';
  @State statusBarPad: number = 44;
  @State isLandscape: boolean = false;
  @State pageW: number = 360;
  @State pageH: number = 780;
  @State modeOpacity: number = 1;
  @State modeScale: number = 1;
  @State backPressed: boolean = false;
  onExit: () => void = (): void => {};
  private viz: AudioVizManager | null = null;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private renderer: VizRenderer | null = null;
  private frameSync: displaySync.DisplaySync | null = null;
  private tickCount: number = 0;
  private dotScale: number = 0.8;
  private orientationQuery: mediaquery.MediaQueryListener | null = null;

  aboutToAppear(): void {
    const mgr = AppStorage.get<AudioVizManager>('vizMgr');
    if (mgr !== undefined) {
      this.viz = mgr;
    }
    this.renderer = new VizRenderer(this.context, null);
    this.renderer.setDark(true);
    this.frameSync = displaySync.create();
    this.frameSync.setExpectedFrameRateRange({ min: 30, max: 120, expected: 60 });
    this.frameSync.on('frame', (info: displaySync.IntervalInfo): void => {
      this.onTick();
    });
    this.frameSync.start();
    AppStorage.setOrCreate('vizPageActive', true);
    this.orientationQuery = this.getUIContext().getMediaQuery().matchMediaSync('(orientation: landscape)');
    this.isLandscape = this.orientationQuery.matches;
    this.orientationQuery.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isLandscape = result.matches;
    });
    const ui = this.getUIContext();
    const hostCtx = ui.getHostContext();
    if (hostCtx !== undefined) {
      window.getLastWindow(hostCtx)
        .then((win: window.Window) => {
          const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          const cut = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
          this.statusBarPad = Math.max(ui.px2vp(sys.topRect.height), ui.px2vp(cut.topRect.height));
        })
        .catch((): void => {
        });
    }
    this.getUIContext().animateTo({
      duration: 600,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, (): void => {
      this.dotScale = 1.2;
    });
  }

  aboutToDisappear(): void {
    const sync = this.frameSync;
    if (sync !== null) {
      sync.stop();
      sync.off('frame');
      this.frameSync = null;
    }
    if (this.orientationQuery !== null) {
      this.orientationQuery.off('change');
      this.orientationQuery = null;
    }
    AppStorage.setOrCreate('vizPageActive', false);
  }

  private onTick(): void {
    const viz = this.viz;
    const renderer = this.renderer;
    if (viz === null || renderer === null) {
      return;
    }
    const w = Math.floor(this.context.width);
    const h = Math.floor(this.context.height);
    if (w <= 0 || h <= 0) {
      return;
    }
    this.tickCount++;
    renderer.render(viz, {
      streaming: this.streaming,
      showBars: this.vizMode === 0,
      showWave: this.vizMode === 1,
      deco: this.vizMode === 2 ? 1 : (this.vizMode === 3 ? 2 : 0),
      nrActive: this.nrActive,
      w: w,
      h: h,
      scale: Math.min(w, h) / 150,
      pageMode: true
    });
    if (!this.streaming) {
      if (this.rmsText !== '--') {
        this.rmsText = '--';
        this.peakText = '--';
        this.preRms = '--';
        this.prePeak = '--';
        this.preTp = '--';
        this.postTp = '--';
      }
      if (this.clipWarn) {
        this.clipWarn = false;
      }
    } else if (this.tickCount % 3 === 0) {
      this.rmsText = fmtDb(viz.getRmsDb(true));
      this.peakText = fmtDb(viz.getPeakDb(true));
      this.clipWarn = viz.isClipping(true);
      this.preRms = fmtDb(viz.getRmsDb(false));
      this.prePeak = fmtDb(viz.getPeakDb(false));
      this.preTp = fmtDb(viz.getTruePeakDb(false));
      this.postTp = fmtDb(viz.getTruePeakDb(true));
    }
  }

  private onMeterReset(): void {
    const viz = this.viz;
    if (viz !== null) {
      viz.resetMeterLatch();
    }
    this.clipWarn = false;
  }

  private onClipTap(): void {
    const viz = this.viz;
    if (viz !== null) {
      viz.clearClipLatch();
    }
    this.clipWarn = false;
  }

  // 说明: 模式切换过渡——先瞬时回落（无动画直赋），再 springMotion 弹性回满，产生「缩一下再弹开」的非线性过场。
  private onModeChange(): void {
    this.modeOpacity = 0.55;
    this.modeScale = 0.985;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.45, 0.9) }, (): void => {
      this.modeOpacity = 1;
      this.modeScale = 1;
    });
  }

  @Builder
  TopBar() {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor($r('app.color.viz_page_text_main'))
        .width(44)
        .height(44)
        .textAlign(TextAlign.Center)
        .scale({ x: this.backPressed ? 0.88 : 1, y: this.backPressed ? 0.88 : 1 })
        .animation({ curve: curves.springMotion(0.4, 0.8) })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.backPressed = true;
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.backPressed = false;
          }
        })
        .onClick(() => {
          this.onExit();
        })
      Blank()
      if (this.streaming) {
        Text(this.muted ? '已静音' : '静音')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.muted ? $r('app.color.danger') : $r('app.color.viz_page_text_sub'))
          .height(26)
          .padding({ left: 12, right: 12 })
          .borderRadius(13)
          .backgroundColor(this.muted ? $r('app.color.viz_live_bg') : $r('app.color.viz_page_pill_bg'))
          .onClick(() => {
            this.muted = !this.muted;
          })
        Row({ space: 6 }) {
          Circle({ width: 8, height: 8 })
            .fill($r('app.color.danger'))
            .scale({ x: this.dotScale, y: this.dotScale })
          Text('LIVE')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.danger'))
        }
        .height(26)
        .padding({ left: 10, right: 14 })
        .borderRadius(13)
        .backgroundColor($r('app.color.viz_live_bg'))
        .alignItems(VerticalAlign.Center)
        .margin({ left: 8 })
      } else {
        Row({ space: 6 }) {
          Circle({ width: 6, height: 6 })
            .fill($r('app.color.viz_page_text_sub'))
          Text('等待音频')
            .fontSize(11)
            .fontColor($r('app.color.viz_page_text_sub'))
        }
        .height(26)
        .padding({ left: 12, right: 14 })
        .borderRadius(13)
        .backgroundColor($r('app.color.viz_page_pill_bg'))
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding({ top: this.statusBarPad, left: 4, right: 12 })
  }

  @Builder
  ReadoutBlock() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.rmsText)
          .fontSize(34)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.viz_page_text_main'))
        Text('dB RMS')
          .fontSize(12)
          .fontColor($r('app.color.viz_page_text_sub'))
          .margin({ bottom: 5 })
      }
      .alignItems(VerticalAlign.Bottom)
      Row({ space: 14 }) {
        Text(`峰值 ${this.peakText} dB`)
          .fontSize(12)
          .fontColor($r('app.color.viz_page_text_sub'))
        if (this.clipWarn) {
          Text('削波')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.danger'))
        }
      }
    }
    .alignItems(HorizontalAlign.Center)
    .margin({ top: 20 })
  }

  @Builder
  MeterReadout() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.rmsText)
          .fontSize(38)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.viz_page_text_main'))
        Text('dB RMS')
          .fontSize(12)
          .fontColor($r('app.color.viz_page_text_sub'))
          .margin({ bottom: 6 })
      }
      .alignItems(VerticalAlign.Bottom)
    }
    .alignItems(HorizontalAlign.Center)
    .margin({ top: 30 })
  }

  @Builder
  MeterActions() {
    Row({ space: 12 }) {
      Text('重置')
        .fontSize(12)
        .fontColor('#E6E6E6')
        .height(30)
        .padding({ left: 16, right: 16 })
        .borderRadius(15)
        .backgroundColor('#1C1C22')
        .onClick(() => {
          this.onMeterReset();
        })
      Text('CLIP')
        .fontSize(9)
        .fontWeight(FontWeight.Bold)
        .letterSpacing(1)
        .fontColor(this.clipWarn ? Color.White : 'rgba(255,106,106,0.6)')
        .height(24)
        .padding({ left: 10, right: 10 })
        .borderRadius(12)
        .border({
          width: 1,
          color: this.clipWarn ? '#FF6A6A' : 'rgba(255,106,106,0.35)'
        })
        .backgroundColor(this.clipWarn ? '#FF6A6A' : Color.Transparent)
        .shadow(this.clipWarn ? { radius: 10, color: 'rgba(255,106,106,0.6)' }
          : { radius: 0, color: Color.Transparent })
        .onClick(() => {
          this.onClipTap();
        })
      Text('LUFS · 预留')
        .fontSize(10)
        .fontColor('rgba(199,199,204,0.55)')
        .height(24)
        .padding({ left: 10, right: 10 })
        .borderRadius(12)
        .border({
          width: 1,
          color: 'rgba(199,199,204,0.4)',
          style: BorderStyle.Dashed
        })
    }
    .margin({ top: 20 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  MeterCardRows(rms: string, peak: string, tp: string) {
    Row() {
      Text('RMS')
        .fontSize(11)
        .fontColor('#8A8A95')
      Blank()
      Text(`${rms} dB`)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor('#E6E6E6')
    }
    .width('100%')
    .margin({ top: 6.5 })
    Row() {
      Text('峰值')
        .fontSize(11)
        .fontColor('#8A8A95')
      Blank()
      Text(`${peak} dB`)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor('#E6E6E6')
    }
    .width('100%')
    .margin({ top: 6.5 })
    Row() {
      Text('TP')
        .fontSize(11)
        .fontColor('#8A8A95')
      Blank()
      Text(`${tp} dB`)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor('#E6E6E6')
    }
    .width('100%')
    .margin({ top: 6.5 })
  }

  @Builder
  MeterCards() {
    Row({ space: 14 }) {
      Column() {
        Row() {
          Text('前置 PRE')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor('#E6E6E6')
          Text(' · 降噪前')
            .fontSize(11)
            .fontColor('#8A8A95')
        }
        .width('100%')
        .padding({ bottom: 6 })
        .border({
          width: { bottom: 1 },
          color: { bottom: 'rgba(255,255,255,0.07)' }
        })
        this.MeterCardRows(this.preRms, this.prePeak, this.preTp)
      }
      .width(150)
      .padding({ top: 13, bottom: 13, left: 15, right: 15 })
      .borderRadius(12)
      .backgroundColor('#131319')
      .border({
        width: 1,
        color: 'rgba(255,255,255,0.06)'
      })
      Column() {
        Row() {
          Text('后置 POST')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor('#E6E6E6')
          Text(' · 处理后')
            .fontSize(11)
            .fontColor('#8A8A95')
        }
        .width('100%')
        .padding({ bottom: 6 })
        .border({
          width: { bottom: 1 },
          color: { bottom: 'rgba(255,255,255,0.07)' }
        })
        this.MeterCardRows(this.rmsText, this.peakText, this.postTp)
      }
      .width(150)
      .padding({ top: 13, bottom: 13, left: 15, right: 15 })
      .borderRadius(12)
      .backgroundColor('#131319')
      .border({
        width: 1,
        color: 'rgba(255,255,255,0.06)'
      })
    }
    .margin({ top: 26 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  NrHint() {
    if (this.nrActive && (this.vizMode === 0 || this.vizMode === 1)) {
      Text('亮=降噪后 · 暗=原始')
        .fontSize(11)
        .fontColor($r('app.color.viz_page_text_sub'))
        .margin({ top: 10 })
    }
  }

  @Builder
  PortraitBody() {
    Column() {
      Canvas(this.context)
        .width('100%')
        .height(this.vizMode === 2 ? 200 : 380)
        .margin({ top: 12 })
        .opacity(this.modeOpacity)
        .scale({ x: this.modeScale, y: this.modeScale })
      if (this.vizMode === 2) {
        this.MeterReadout()
        this.MeterActions()
        this.MeterCards()
      } else {
        this.ReadoutBlock()
        this.NrHint()
      }
      Blank()
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  LandscapeReadout() {
    Column({ space: 10 }) {
      Text(this.rmsText)
        .fontSize(40)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.viz_page_text_main'))
      Text('dB RMS')
        .fontSize(12)
        .fontColor($r('app.color.viz_page_text_sub'))
      Row({ space: 12 }) {
        Text(`峰值 ${this.peakText} dB`)
          .fontSize(12)
          .fontColor($r('app.color.viz_page_text_sub'))
        if (this.clipWarn) {
          Text('削波')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.danger'))
        }
      }
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  LandscapeBody() {
    Row({ space: 20 }) {
      Canvas(this.context)
        .layoutWeight(7)
        .height('100%')
        .opacity(this.modeOpacity)
        .scale({ x: this.modeScale, y: this.modeScale })
      Column() {
        Blank()
        this.LandscapeReadout()
        this.NrHint()
      }
      .layoutWeight(3)
      .height('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8 })
  }

  build() {
    Stack() {
      Column() {
        this.TopBar()
        if (this.isLandscape) {
          this.LandscapeBody()
        } else {
          this.PortraitBody()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.viz_page_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .padding({ left: 20, right: 20 })

      VizDock({
        selected: this.vizMode,
        isLandscape: this.isLandscape,
        boundsW: this.pageW,
        boundsH: this.pageH,
        topPad: this.statusBarPad,
        onSelect: (index: number): void => {
          this.vizMode = index;
        }
      })
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w = newArea.width;
      const h = newArea.height;
      if (typeof w === 'number' && typeof h === 'number') {
        this.pageW = w;
        this.pageH = h;
      }
    })
  }
}
