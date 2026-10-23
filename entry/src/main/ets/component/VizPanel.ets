import { AudioVizManager } from 'common';
import { VizCanvas } from './VizCanvas';

@Component
export struct VizPanel {
  viz: AudioVizManager | null = null;
  @Prop canvasHeight: number = 130;
  forceDark: boolean = false;

  build() {
    Column() {
      VizCanvas({ viz: this.viz, canvasHeight: this.canvasHeight, showMetrics: false, forceDark: this.forceDark })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 10 })
    .borderRadius(12)
  }
}
