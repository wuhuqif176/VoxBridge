// 说明: 自定义音频开关（绿色胶囊 + 白色圆钮）。
// 纯展示组件：切换由宿主行的 onClick 调用 svc 完成后经 @Prop isOn 回流刷新，
// 避免开关自身与父行 onClick 嵌套双触发（见 Round Z 决策）。
// compact=true 为 LIMIT 小尺寸（34x20，钮 16）；默认为旁通/降噪行尺寸（40x24，钮 20）。
@Component
export struct AudioSwitch {
  @Prop isOn: boolean = false;
  compact: boolean = false;
  dark: boolean = false;

  private shellWidth(): number {
    return this.compact ? 34 : 40;
  }

  private shellHeight(): number {
    return this.compact ? 20 : 24;
  }

  private knobSize(): number {
    return this.compact ? 16 : 20;
  }

  private knobShift(): number {
    return this.compact ? 7 : 8;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Circle({ width: this.knobSize(), height: this.knobSize() })
        .fill(Color.White)
        .shadow({ radius: 3, color: '#40000000', offsetY: 1 })
        .translate({ x: this.isOn ? this.knobShift() : -this.knobShift() })
        .animation({ duration: 150, curve: Curve.EaseOut })
    }
    .width(this.shellWidth())
    .height(this.shellHeight())
    .borderRadius(this.shellHeight() / 2)
    .backgroundColor(this.isOn ? $r('app.color.live_green') : (this.dark ? '#2EFFFFFF' : $r('app.color.clip_idle')))
    .animation({ duration: 150, curve: Curve.EaseOut })
  }
}
