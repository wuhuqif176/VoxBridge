import { curves } from '@kit.ArkUI';

// 说明: 悬浮 Dock——玻璃拟态容器 + 四模式单选项 + PanGesture 拖拽 + springMotion 边缘吸附。
// 首帧 posX=-1000 屏外隐藏，onAreaChange 实测自身尺寸后落默认位（竖屏底部居中/横屏右缘垂直居中）；
// 旋转（isLandscape/bounds 变化）未拖拽过则回默认位，拖拽过仅 clamp 不越界。
const DOCK_LABELS: string[] = ['电平', '波形', '电平表', '涟漪'];
const DOCK_EDGE_MARGIN: number = 12;

@Component
export struct VizDock {
  @Prop selected: number = 0;
  @Prop @Watch('onOrientationChange') isLandscape: boolean = false;
  @Prop @Watch('onBoundsChange') boundsW: number = 360;
  @Prop @Watch('onBoundsChange') boundsH: number = 780;
  @Prop topPad: number = 44;
  onSelect: (index: number) => void = (index: number): void => {};
  @State posX: number = -1000;
  @State posY: number = -1000;
  @State selfW: number = 0;
  @State selfH: number = 0;
  @State enterScale: number = 0.001;
  private hasDragged: boolean = false;
  private dragStartX: number = 0;
  private dragStartY: number = 0;

  aboutToAppear(): void {
    // 说明: Dock 弹性入场——VizView 出现后延迟 100ms 从零弹起（springMotion 自带过冲回弹）。
    this.getUIContext().animateTo({ delay: 100, curve: curves.springMotion(0.5, 0.85) }, (): void => {
      this.enterScale = 1;
    });
  }

  private applyHome(): void {
    if (this.selfW <= 0 || this.boundsW <= 0 || this.boundsH <= 0) {
      return;
    }
    if (this.isLandscape) {
      this.posX = this.clampX(this.boundsW - this.selfW - DOCK_EDGE_MARGIN);
      this.posY = this.clampY(this.boundsH * 0.5 - this.selfH * 0.5);
    } else {
      this.posX = this.clampX((this.boundsW - this.selfW) / 2);
      this.posY = this.clampY(this.boundsH - this.selfH - 130);
    }
  }

  private clampX(x: number): number {
    return Math.max(DOCK_EDGE_MARGIN, Math.min(x, this.boundsW - this.selfW - DOCK_EDGE_MARGIN));
  }

  private clampY(y: number): number {
    const top = this.topPad + 8;
    return Math.max(top, Math.min(y, this.boundsH - this.selfH - 16));
  }

  private onOrientationChange(): void {
    this.hasDragged = false;
    this.applyHome();
  }

  private onBoundsChange(): void {
    if (this.hasDragged) {
      this.posX = this.clampX(this.posX);
      this.posY = this.clampY(this.posY);
    } else {
      this.applyHome();
    }
  }

  private snapToEdge(): void {
    const centerX = this.posX + this.selfW / 2;
    const targetX = centerX < this.boundsW / 2 ? DOCK_EDGE_MARGIN
      : this.boundsW - this.selfW - DOCK_EDGE_MARGIN;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.88) }, (): void => {
      this.posX = this.clampX(targetX);
      this.posY = this.clampY(this.posY);
    });
  }

  build() {
    Row({ space: 2 }) {
      ForEach(DOCK_LABELS, (label: string, index: number) => {
        Text(label)
          .fontSize(11)
          .fontWeight(this.selected === index ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.selected === index ? Color.White : 'rgba(199,199,204,0.9)')
          .textAlign(TextAlign.Center)
          .height(34)
          .constraintSize({ minWidth: 44 })
          .padding({ left: 10, right: 10 })
          .borderRadius(17)
          .backgroundColor(this.selected === index ? $r('app.color.accent') : Color.Transparent)
          .shadow(this.selected === index
            ? { radius: 10, color: 'rgba(10,132,255,0.5)', offsetX: 0, offsetY: 0 }
            : { radius: 0, color: Color.Transparent })
          .scale({ x: this.selected === index ? 1.06 : 1, y: this.selected === index ? 1.06 : 1 })
          .animation({ curve: curves.springMotion(0.38, 0.85) })
          .onClick(() => {
            this.onSelect(index);
          })
      }, (label: string) => label)
    }
    .padding(5)
    .borderRadius(23)
    .backgroundColor('rgba(28,28,34,0.55)')
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
    .border({ width: 0.5, color: 'rgba(255,255,255,0.16)' })
    .shadow({ radius: 18, color: 'rgba(0,0,0,0.35)', offsetY: 4 })
    .scale({ x: this.enterScale, y: this.enterScale })
    .position({ x: this.posX, y: this.posY })
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w = newArea.width;
      const h = newArea.height;
      if (typeof w === 'number' && typeof h === 'number') {
        this.selfW = w;
        this.selfH = h;
        if (this.posX < 0) {
          this.applyHome();
        }
      }
    })
    .gesture(PanGesture({ fingers: 1, direction: PanDirection.All })
      .onActionStart((event: GestureEvent) => {
        this.dragStartX = this.posX;
        this.dragStartY = this.posY;
      })
      .onActionUpdate((event: GestureEvent) => {
        this.posX = this.clampX(this.dragStartX + event.offsetX);
        this.posY = this.clampY(this.dragStartY + event.offsetY);
      })
      .onActionEnd(() => {
        this.hasDragged = true;
        this.snapToEdge();
      }))
  }
}
