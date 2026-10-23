import { StreamService } from '../services/StreamService';

@Component
export struct WelcomeView {
  onDone: () => void = (): void => {};
  private tapLock: boolean = false;
  private svc: StreamService = StreamService.getInstance();

  private enterApp(): void {
    if (this.tapLock) {
      return;
    }
    this.tapLock = true;
    this.svc.markWelcomed().then((): void => {
      this.onDone();
    });
  }

  @Builder
  HeroArt() {
    Stack() {
      Circle({ width: 220, height: 220 })
        .fill(Color.Transparent)
        .stroke($r('app.color.accent'))
        .strokeWidth(1)
        .opacity(0.25)
      Circle({ width: 168, height: 168 })
        .fill(Color.Transparent)
        .stroke($r('app.color.accent'))
        .strokeWidth(1.5)
        .opacity(0.4)
      Circle({ width: 116, height: 116 })
        .fill($r('app.color.accent_10'))
      Row({ space: 10 }) {
        Rect({ width: 22, height: 38 })
          .radiusWidth(4)
          .radiusHeight(4)
          .fill($r('app.color.accent'))
        Text('→')
          .fontSize(20)
          .fontColor($r('app.color.accent'))
        Column({ space: 4 }) {
          Rect({ width: 46, height: 30 })
            .radiusWidth(3)
            .radiusHeight(3)
            .fill($r('app.color.accent'))
            .opacity(0.85)
          Rect({ width: 14, height: 3 })
            .radiusWidth(1.5)
            .radiusHeight(1.5)
            .fill($r('app.color.accent'))
            .opacity(0.5)
        }
        .justifyContent(FlexAlign.Center)
      }
      .alignItems(VerticalAlign.Center)
    }
    .width(240)
    .height(240)
  }

  @Builder
  FeatureRow(icon: Resource, title: string, desc: string) {
    Row({ space: 14 }) {
      Stack() {
        Circle({ width: 40, height: 40 })
          .fill($r('app.color.accent_12'))
        SymbolGlyph(icon)
          .fontSize(20)
          .fontColor([$r('app.color.accent')])
      }
      Column({ space: 2 }) {
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(desc)
          .fontSize(11.5)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
  }

  build() {
    Column({ space: 12 }) {
      Blank()
      this.HeroArt()
      Text('VoxBridge')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('把手机变成 PC 的网络麦克风')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Column({ space: 20 }) {
        this.FeatureRow($r('sys.symbol.wifi'), '无线串流', '同一 Wi-Fi 下把手机麦克风实时传给 PC')
        this.FeatureRow($r('sys.symbol.waveform'), '可视化监听', '频谱与音量实时反馈，听得见的都在看')
        this.FeatureRow($r('sys.symbol.headphones'), '双重降噪', '系统通话增强 + AI 深度滤波双重加持')
      }
      .width('100%')
      .padding({ left: 8, right: 8 })
      .margin({ top: 12 })
      Blank()
      Button() {
        Text('开始使用')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .letterSpacing(1)
      }
      .width('100%')
      .height(52)
      .borderRadius(15)
      .backgroundColor($r('app.color.accent'))
      .shadow({ radius: 24, offsetY: 8, color: 'rgba(0,122,255,0.35)' })
      .onClick(() => {
        this.enterApp();
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: 44 })
    .backgroundColor($r('app.color.page_bg'))
    .transition(TransitionEffect.OPACITY)
  }
}
