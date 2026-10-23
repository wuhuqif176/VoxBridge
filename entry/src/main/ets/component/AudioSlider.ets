// 说明: 自定义音频滑块组件（-24~+24 dB，0.5dB 步进，双击归零）。
// 供 ConfigSheet 增益行使用；主题令牌配色（accent 填充/clip_idle 轨道/白 thumb），
// 刻度行与 Live 增益行同构（-24/-12/0/+12/+24 五档定位）。
@Component
export struct AudioSlider {
  @Prop value: number = 0;
  onValue: (v: number) => void = (v: number): void => {};
  dark: boolean = false;
  private sliderWidth: number = 0;
  private lastTapAt: number = 0;

  private trackIdleColor(): ResourceColor {
    return this.dark ? '#2EFFFFFF' : $r('app.color.clip_idle');
  }

  private scaleColor(): ResourceColor {
    return this.dark ? '#59FFFFFF' : $r('app.color.text_hint');
  }

  private pct(): number {
    return (this.value + 24) / 48 * 100;
  }

  private fillLeft(): string {
    const p = this.pct();
    return p >= 50 ? '50%' : `${p}%`;
  }

  private fillWidth(): string {
    return `${Math.abs(this.pct() - 50)}%`;
  }

  private updateFromTouch(x: number): void {
    if (this.sliderWidth <= 0) {
      return;
    }
    let p = x / this.sliderWidth;
    if (p < 0) {
      p = 0;
    } else if (p > 1) {
      p = 1;
    }
    const v = Math.round((p * 48 - 24) * 2) / 2;
    if (v !== this.value) {
      this.onValue(v);
    }
  }

  private handleTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      const now = Date.now();
      if (now - this.lastTapAt < 300) {
        this.lastTapAt = 0;
        this.onValue(0);
        return;
      }
      this.lastTapAt = now;
      this.updateFromTouch(event.touches[0].x);
    } else if (event.type === TouchType.Move) {
      this.updateFromTouch(event.touches[0].x);
    }
  }

  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Start }) {
        Column()
          .width('100%')
          .height(4)
          .borderRadius(2)
          .backgroundColor(this.trackIdleColor())
          .position({ x: 0, y: 6 })
        Column()
          .height(4)
          .borderRadius(2)
          .backgroundColor($r('app.color.accent'))
          .position({ x: this.fillLeft(), y: 6 })
          .width(this.fillWidth())
        Circle({ width: 16, height: 16 })
          .fill(Color.White)
          .shadow({ radius: 4, color: '#59333333', offsetY: 1 })
          .position({ x: `${this.pct()}%`, y: 0 })
          .markAnchor({ x: 8 })
      }
      .width('100%')
      .height(16)
      .onAreaChange((oldArea: Area, newArea: Area) => {
        const w = newArea.width;
        if (typeof w === 'number') {
          this.sliderWidth = w;
        }
      })
      .onTouch((event: TouchEvent) => {
        this.handleTouch(event);
      })

      Stack({ alignContent: Alignment.Start }) {
        Text('-24')
          .fontSize(7.5)
          .fontColor(this.scaleColor())
          .position({ x: 0, y: 0 })
        Text('-12')
          .fontSize(7.5)
          .fontColor(this.scaleColor())
          .position({ x: '25%', y: 0 })
          .markAnchor({ x: '50%' })
        Text('0')
          .fontSize(7.5)
          .fontColor(this.scaleColor())
          .position({ x: '50%', y: 0 })
          .markAnchor({ x: '50%' })
        Text('+12')
          .fontSize(7.5)
          .fontColor(this.scaleColor())
          .position({ x: '75%', y: 0 })
          .markAnchor({ x: '50%' })
        Text('+24')
          .fontSize(7.5)
          .fontColor(this.scaleColor())
          .position({ x: '100%', y: 0 })
          .markAnchor({ x: '100%' })
      }
      .width('100%')
      .height(10)
    }
    .width('100%')
  }
}
