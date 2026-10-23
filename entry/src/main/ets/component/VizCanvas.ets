import { mediaquery } from '@kit.ArkUI';
import { displaySync } from '@kit.ArkGraphics2D';
import { AudioVizManager } from 'common';
import { VizRenderer, VIZ_CARD_STRIP_H } from './VizRenderer';

@Component
export struct VizCanvas {
  @StorageProp('vizStreaming') streaming: boolean = false;
  @StorageProp('vizDeco') deco: number = 0;
  @StorageProp('vizNrActive') nrActive: boolean = false;
  @StorageProp('themeMode') @Watch('onThemeMode') themeMode: number = 0;
  @State dbText: string = 'RMS -- dB · 峰值 -- dB';
  @State clipping: boolean = false;
  viz: AudioVizManager | null = null;
  @Prop canvasHeight: number = 130;
  showMetrics: boolean = true;
  forceDark: boolean = false;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private renderer: VizRenderer | null = null;
  private frameSync: displaySync.DisplaySync | null = null;
  private darkQuery: mediaquery.MediaQueryListener | null = null;
  private systemDark: boolean = false;

  aboutToAppear(): void {
    this.renderer = new VizRenderer(this.context, (text: string, clip: boolean): void => {
      if (this.dbText !== text) {
        this.dbText = text;
      }
      if (this.clipping !== clip) {
        this.clipping = clip;
      }
    });
    const listener = this.getUIContext().getMediaQuery().matchMediaSync('(prefers-color-scheme: dark)');
    this.systemDark = listener.matches;
    this.applyDark();
    listener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.systemDark = result.matches;
      this.applyDark();
    });
    this.darkQuery = listener;
    this.frameSync = displaySync.create();
    this.frameSync.setExpectedFrameRateRange({ min: 30, max: 120, expected: 60 });
    this.frameSync.on('frame', (info: displaySync.IntervalInfo): void => {
      this.onTick();
    });
    this.frameSync.start();
  }

  aboutToDisappear(): void {
    const sync = this.frameSync;
    if (sync !== null) {
      sync.stop();
      sync.off('frame');
      this.frameSync = null;
    }
    if (this.darkQuery !== null) {
      this.darkQuery.off('change');
      this.darkQuery = null;
    }
  }

  onThemeMode(): void {
    this.applyDark();
  }

  private composeDark(): boolean {
    if (this.forceDark) {
      return true;
    }
    if (this.themeMode === 1) {
      return false;
    }
    if (this.themeMode === 2) {
      return true;
    }
    return this.systemDark;
  }

  private applyDark(): void {
    const r = this.renderer;
    if (r !== null) {
      r.setDark(this.composeDark());
    }
  }

  private onTick(): void {
    const viz = this.viz;
    const renderer = this.renderer;
    if (viz === null || renderer === null) {
      return;
    }
    if (AppStorage.get<boolean>('vizPageActive') === true) {
      return;
    }
    const w = Math.floor(this.context.width);
    const h = Math.floor(this.context.height);
    if (w <= 0 || h <= VIZ_CARD_STRIP_H) {
      return;
    }
    const dh = h - VIZ_CARD_STRIP_H;
    // 说明: 卡片仅渲染单一频谱主图表（撑满卡片），波形图只保留给 VizPage 全屏页。
    renderer.render(viz, {
      streaming: this.streaming,
      showBars: true,
      showWave: false,
      deco: this.deco,
      nrActive: this.nrActive,
      w: w,
      h: dh,
      scale: Math.min(w, dh) / 150,
      pageMode: false
    });
    renderer.drawLiveStrip(viz, w, h);
  }

  build() {
    Column({ space: 8 }) {
      Canvas(this.context)
        .width('100%')
        .height(this.canvasHeight)

      if (this.showMetrics) {
        Row() {
          Text('削波')
            .fontSize(10)
            .fontColor(this.clipping ? $r('app.color.danger') : $r('app.color.clip_idle'))
          Text(this.dbText)
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
            .maxLines(1)
            .margin({ left: 8 })
        }
        .width('100%')
      }
    }
    .width('100%')
  }
}
