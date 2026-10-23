import { curves } from '@kit.ArkUI';
import { StreamService } from '../services/StreamService';
import { EqStage, EqBandParams, EqBandType, EqPresets, EQ_BAND_COUNT, MicLogger } from 'common';
import { AudioSlider } from './AudioSlider';
import { AudioSwitch } from './AudioSwitch';
import { Mat } from './Materials';

interface EqPresetChip {
  name: string;
  label: string;
}

@Component
export struct ConfigSections {
  @StorageLink('cfgSource') sourceChoice: number = 0;
  @StorageLink('cfgRate') rateChoice: number = 0;
  @StorageLink('cfgBits') bitsChoice: number = 0;
  @StorageLink('cfgChannels') channelChoice: number = 0;
  @StorageLink('cfgNr') nrChoice: number = 0;
  @StorageLink('cfgProNr') proNrMode: boolean = false;
  @StorageLink('cfgDfStrength') dfStrength: number = 0;
  @StorageLink('cfgNoisy') noisyEnvPreset: boolean = false;
  @StorageProp('proNrAvailable') proNrAvailable: boolean = false;
  @StorageProp('probing') probing: boolean = false;
  @StorageProp('matrixLoaded') matrixLoaded: boolean = false;
  @StorageProp('supportMatrix') supportMatrix: boolean[] =
    [true, true, true, true, true, true, true, true, true, true, true, true];
  @StorageProp('nrSupported') nrSupported: boolean[] = [true, true, true, true];
  @StorageProp('probeText') probeText: string = '能力未探测';
  @State expandSource: boolean = false;
  @State expandParam: boolean = false;
  @State expandNr: boolean = false;
  @State expandEq: boolean = false;
  @Prop segmentMode: boolean = false;
  @Prop forceDark: boolean = false;
  @State configExpanded: boolean = false;
  @State eqCurveWidth: number = 0;
  @State eqBodyH: number = 0;
  @State segIndex: number = 0;
  @StorageProp('cfgEqBypass') eqBypass: boolean = true;
  @StorageProp('cfgEqPreset') eqPreset: string = 'flat';
  @StorageProp('cfgGainDb') gainDb: number = 0;
  @StorageProp('cfgLimiterOn') limiterOn: boolean = true;
  @StorageProp('cfgEqBands') eqBands: EqBandParams[] = [];
  @StorageProp('rateDowngraded') rateDowngraded: boolean = false;
  showEq: boolean = true;
  // 说明: 弹出式配置卡传入 true——隐藏摘要折叠行，分段内容常驻展开（不可折叠）。
  segmentFlat: boolean = false;
  private svc: StreamService = StreamService.getInstance();
  private curveEq: EqStage = new EqStage();
  private bandSliderWidths: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
  // 说明: 必须为 @State——onAreaChange 回填后需触发重渲染，否则分段滑块 thumb 初始按 0 宽度计算不可见。
  @State segBarWidth: number = 0;
  private foldCurve: curves.ICurve = curves.springMotion(0.4, 0.9);

  // 说明: forceDark=true 时（Live 深色 sheet 专用）忽略系统主题令牌，改用深色字面量。
  // Connect segmentMode 不传 forceDark，保持系统主题跟随，二者互不影响。
  private txtPrimary(): ResourceColor {
    return this.forceDark ? '#F0F0F2' : $r('app.color.text_primary');
  }

  private txtSecondary(): ResourceColor {
    return this.forceDark ? '#98989F' : $r('app.color.text_secondary');
  }

  private txtHint(): ResourceColor {
    return this.forceDark ? '#8E8E96' : $r('app.color.text_hint');
  }

  private txtChevron(): ResourceColor {
    return this.forceDark ? '#5A5A63' : $r('app.color.text_hint');
  }

  private pillTextColor(selected: boolean): ResourceColor {
    if (selected) {
      return this.forceDark ? Color.White : $r('app.color.btn_selected_text');
    }
    return this.forceDark ? '#C7C7CC' : $r('app.color.text_primary');
  }

  private pillBgColor(selected: boolean): ResourceColor {
    if (selected) {
      return $r('app.color.accent');
    }
    return this.forceDark ? '#1AFFFFFF' : $r('app.color.btn_unselected_bg');
  }

  private pillHeight(): number {
    return this.forceDark ? 34 : 40;
  }

  private pillRadius(): number {
    return this.forceDark ? 17 : 20;
  }

  private pillHPadding(): number {
    return this.forceDark ? 16 : 14;
  }

  private presetBorder(selected: boolean): BorderOptions {
    if (selected && this.forceDark) {
      return { width: 1, color: '#800A84FF' };
    }
    return { width: 0 };
  }

  private sourceName(choice: number): string {
    if (choice === 1) {
      return '原始MIC';
    }
    if (choice === 2) {
      return '语音识别';
    }
    if (choice === 3) {
      return '语音消息(可降噪)';
    }
    return '通话增强';
  }

  private strengthName(tier: number): string {
    if (tier === 1) {
      return '增强';
    }
    if (tier === 2) {
      return '极致';
    }
    return '标准';
  }

  private nrName(choice: number): string {
    if (choice === 1) {
      return '标准降噪';
    }
    if (choice === 2) {
      return '人声降噪';
    }
    if (choice === 3) {
      return '高保真降噪';
    }
    return '设备默认';
  }

  private comboIndex(rateIdx: number, bitsIdx: number, chIdx: number): number {
    return rateIdx * 6 + bitsIdx * 2 + chIdx;
  }

  private isComboSupported(rateIdx: number, bitsIdx: number, chIdx: number): boolean {
    if (!this.matrixLoaded) {
      return true;
    }
    return this.supportMatrix[this.comboIndex(rateIdx, bitsIdx, chIdx)] === true;
  }

  private rateEnabled(rateIdx: number): boolean {
    return !this.probing && this.isComboSupported(rateIdx, this.bitsChoice, this.channelChoice);
  }

  private bitsEnabled(bitsIdx: number): boolean {
    return !this.probing && this.isComboSupported(this.rateChoice, bitsIdx, this.channelChoice);
  }

  private channelEnabled(chIdx: number): boolean {
    return !this.probing && this.isComboSupported(this.rateChoice, this.bitsChoice, chIdx);
  }

  private nrEnabled(choice: number): boolean {
    if (choice === 0) {
      return true;
    }
    if (this.sourceChoice !== 3) {
      return false;
    }
    return this.nrSupported[choice] === true;
  }

  private paramSummary(): string {
    const rate = this.rateChoice === 1 ? '48kHz' : '16kHz';
    let bits = '16bit';
    if (this.bitsChoice === 1) {
      bits = '24bit';
    } else if (this.bitsChoice === 2) {
      bits = '32bit';
    }
    const channel = this.channelChoice === 1 ? '立体声' : '单声道';
    return `${rate} · ${bits} · ${channel}`;
  }

  private nrSummary(): string {
    if (this.noisyEnvPreset) {
      return '嘈杂环境模式';
    }
    if (this.proNrMode) {
      return `DF3降噪 · ${this.strengthName(this.dfStrength)}档`;
    }
    return this.nrName(this.nrChoice);
  }

  private eqPresetName(): string {
    if (this.eqPreset === EqPresets.VOICE) {
      return '人声增强';
    }
    if (this.eqPreset === EqPresets.LOW_CUT) {
      return '低切防喷';
    }
    if (this.eqPreset === EqPresets.BRIGHT) {
      return '明亮';
    }
    if (this.eqPreset === EqPresets.FLAT) {
      return '平直';
    }
    return '自定义';
  }

  private eqSummary(): string {
    if (this.eqBypass) {
      return `已旁通 · ${this.bandCount()} 段`;
    }
    return `已启用 · ${this.bandCount()} 段 · 预设 ${this.eqPresetName()}`;
  }

  private eqPresetChips(): EqPresetChip[] {
    return [
      { name: EqPresets.FLAT, label: '平直' },
      { name: EqPresets.VOICE, label: '人声增强' },
      { name: EqPresets.LOW_CUT, label: '低切防喷' },
      { name: EqPresets.BRIGHT, label: '明亮' }
    ];
  }

  private eqBandName(i: number): string {
    const names: string[] = ['低架 · 100 Hz', '峰值 · 180 Hz', '峰值 · 300 Hz', '峰值 · 550 Hz', '峰值 · 1 kHz', '峰值 · 1.8 kHz', '峰值 · 3 kHz', '高架 · 8 kHz'];
    if (i >= 0 && i < names.length) {
      return names[i];
    }
    return '';
  }

  // 说明: 频段数量以 eqBands 实际长度为准（服务层保证 8 段），未就绪时回落常量。
  private bandCount(): number {
    return this.eqBands.length > 0 ? this.eqBands.length : EQ_BAND_COUNT;
  }

  // 说明: 频段下标序列，供 ForEach 动态生成圆点/网格/滑块行（按段数自动伸缩）。
  private eqBandIndices(): number[] {
    const arr: number[] = [];
    for (let i = 0; i < this.bandCount(); i++) {
      arr.push(i);
    }
    return arr;
  }

  // 说明: 频率轴标签：千赫以上用 k 缩写（1k/1.8k/16k），其余原样。
  private eqFreqLabel(freqHz: number): string {
    if (freqHz >= 1000) {
      const k = freqHz / 1000;
      return k === Math.floor(k) ? `${k}k` : `${k.toFixed(1)}k`;
    }
    return `${freqHz}`;
  }

  // 说明: 主曲线竖网格线与频标刻度：边缘 + 全部控制点频率，随段数伸缩。
  private eqGridFreqs(): number[] {
    return [50, 100, 180, 300, 550, 1000, 1800, 3000, 8000, 16000];
  }

  private bandAt(i: number): EqBandParams {
    if (i >= 0 && i < this.eqBands.length) {
      return this.eqBands[i];
    }
    return EqPresets.defaultBands()[i];
  }

  private bandPct(i: number): number {
    return (this.bandAt(i).gainDb + 12) / 24 * 100;
  }

  private bandFillLeft(i: number): string {
    const p = this.bandPct(i);
    return p >= 50 ? '50%' : `${p}%`;
  }

  private bandFillWidth(i: number): string {
    return `${Math.abs(this.bandPct(i) - 50)}%`;
  }

  private bandGainText(i: number): string {
    const g = this.bandAt(i).gainDb;
    return `${g > 0 ? '+' : ''}${g.toFixed(1)}`;
  }

  private isShelf(i: number): boolean {
    return this.bandAt(i).type !== EqBandType.PEAKING;
  }

  private bandQText(i: number): string {
    if (this.isShelf(i)) {
      return 'Q —';
    }
    return `Q ${this.bandAt(i).q.toFixed(2)}`;
  }

  private onBandTouch(event: TouchEvent, index: number): void {
    if (event.type !== TouchType.Down && event.type !== TouchType.Move) {
      return;
    }
    const width = this.bandSliderWidths[index];
    if (width <= 0) {
      return;
    }
    let pct = event.touches[0].x / width;
    if (pct < 0) {
      pct = 0;
    } else if (pct > 1) {
      pct = 1;
    }
    this.svc.setEqBandGain(index, Math.round((pct * 24 - 12) * 10) / 10);
  }

  // 说明: ±0.1dB 微调——步进按钮供手机端精细调节，夹取 ±12 后按 0.1 取整。
  private nudgeBandGain(index: number, delta: number): void {
    const g = Math.max(-12, Math.min(12, this.bandAt(index).gainDb + delta));
    this.svc.setEqBandGain(index, Math.round(g * 10) / 10);
  }

  private eqFreqX(freqHz: number): number {
    const f = Math.max(50, Math.min(16000, freqHz));
    return 18 + Math.log10(f / 50) / Math.log10(320) * (this.eqCurveWidth - 18);
  }

  private eqGainY(gainDb: number): number {
    let y = 60 - gainDb * 4.5;
    if (y < 3) {
      y = 3;
    } else if (y > 121) {
      y = 121;
    }
    return y;
  }

  private eqBandDotX(i: number): number {
    return this.eqFreqX(this.bandAt(i).freqHz);
  }

  private eqBandDotY(i: number): number {
    return this.eqGainY(this.bandAt(i).gainDb);
  }

  private eqPreviewSampleRate(): number {
    if (this.proNrMode && this.proNrAvailable) {
      return 48000;
    }
    if (this.rateDowngraded) {
      return 16000;
    }
    return this.rateChoice === 1 ? 48000 : 16000;
  }

  // 说明: 曲线锚定——级联响应叠加各控制点残差修正（对数频率 smoothstep 插值，首尾向原始响应锥形收敛），
  // 保证曲线 C1 连续平滑穿过全部 5 个控制点；残差为 0 时与纯级联响应完全一致。
  private eqAnchorResiduals(): number[] {
    const residuals: number[] = [];
    for (let i = 0; i < this.bandCount(); i++) {
      const band = this.bandAt(i);
      residuals.push(band.gainDb - this.curveEq.magnitudeDbAt(band.freqHz));
    }
    return residuals;
  }

  // 说明: smoothstep 三次插值——端点值保持不变、端点斜率为 0（C1 连续），
  // 残差修正经它插值后在频段频率处不再产生折角，且仍精确穿过全部控制点。
  private eqSmoothstep(t: number): number {
    return t * t * (3 - 2 * t);
  }

  private eqAnchoredDb(freqHz: number, residuals: number[]): number {
    const raw = this.curveEq.magnitudeDbAt(freqHz);
    const n = this.bandCount();
    const firstHz = this.bandAt(0).freqHz;
    const lastHz = this.bandAt(n - 1).freqHz;
    let correction = 0;
    if (freqHz <= firstHz) {
      const span = Math.log10(firstHz / 50);
      let w = span > 0 ? Math.log10(Math.max(50, freqHz) / 50) / span : 1;
      if (w < 0) {
        w = 0;
      }
      correction = residuals[0] * this.eqSmoothstep(w);
    } else if (freqHz >= lastHz) {
      const span = Math.log10(16000 / lastHz);
      let w = span > 0 ? 1 - Math.log10(freqHz / lastHz) / span : 1;
      if (w < 0) {
        w = 0;
      }
      correction = residuals[n - 1] * this.eqSmoothstep(w);
    } else {
      for (let i = 0; i < n - 1; i++) {
        const fa = this.bandAt(i).freqHz;
        const fb = this.bandAt(i + 1).freqHz;
        if (freqHz >= fa && freqHz <= fb) {
          const span = Math.log10(fb) - Math.log10(fa);
          const t = span > 0 ? (Math.log10(freqHz) - Math.log10(fa)) / span : 0;
          correction = residuals[i] + (residuals[i + 1] - residuals[i]) * this.eqSmoothstep(t);
          break;
        }
      }
    }
    return raw + correction;
  }

  // 说明: Path.commands 官方文档规定单位为 px（物理像素），而图表几何全部按 vp 计算，
  // 必须用 vp2px 换算后再拼命令串，否则曲线按 1/密度 比例缩小渲染，永远拟合不了圆点。
  private eqCmdScale(): number {
    const s = this.getUIContext().vp2px(1);
    return s > 0 ? s : 1;
  }

  // 说明: 三次样条曲线生成——以控制点为骨架的 Catmull-Rom/Hermite 样条转为三次贝塞尔（C 命令）串：
  // 极值控制点（左右斜率异号）切线置 0，隆起/凹陷的圆顶正好落在控制点上（圆润过渡无 V 字折角）；
  // 非极值点切线取 Fritsch-Carlson 调和平均（防过冲），并按该频段 Q 值调制幅度（1/√q，高 Q 收紧低 Q 平缓）；
  // 端点用单侧差分。全曲线 C1 连续平滑穿过全部控制点。
  private eqSplineCommands(xs: number[], ys: number[], qs: number[], s: number): string {
    const n = xs.length;
    const ms: number[] = [];
    for (let i = 0; i < n; i++) {
      let m = 0;
      if (i > 0 && i < n - 1 && xs[i] > xs[i - 1] && xs[i + 1] > xs[i]) {
        const dl = (ys[i] - ys[i - 1]) / (xs[i] - xs[i - 1]);
        const dr = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]);
        if (dl * dr > 0) {
          m = 3 * dl * dr / (dl + dr);
          const q = Math.max(0.5, Math.min(4, qs[i]));
          const qf = Math.min(1.4, Math.max(0.6, 1 / Math.sqrt(q)));
          m *= qf;
        }
      } else if (i === 0 && n > 1 && xs[1] > xs[0]) {
        m = (ys[1] - ys[0]) / (xs[1] - xs[0]);
      } else if (i === n - 1 && n > 1 && xs[n - 1] > xs[n - 2]) {
        m = (ys[n - 1] - ys[n - 2]) / (xs[n - 1] - xs[n - 2]);
      }
      ms.push(m);
    }
    let cmd = `M${(xs[0] * s).toFixed(1)},${(ys[0] * s).toFixed(1)}`;
    for (let i = 0; i < n - 1; i++) {
      const dx = xs[i + 1] - xs[i];
      const c1x = (xs[i] + dx / 3) * s;
      const c1y = (ys[i] + ms[i] * dx / 3) * s;
      const c2x = (xs[i + 1] - dx / 3) * s;
      const c2y = (ys[i + 1] - ms[i + 1] * dx / 3) * s;
      const px = xs[i + 1] * s;
      const py = ys[i + 1] * s;
      cmd += ` C${c1x.toFixed(1)},${c1y.toFixed(1)} ${c2x.toFixed(1)},${c2y.toFixed(1)} ${px.toFixed(1)},${py.toFixed(1)}`;
    }
    return cmd;
  }

  // 说明: 主曲线骨架=边缘+全部控制点：左右边缘取级联响应边界值（shelf 台阶），中间 N 个为控制点圆点坐标。
  private eqCurveStrokeCommands(): string {
    this.curveEq.setBands(this.eqBands, this.eqPreviewSampleRate());
    const residuals = this.eqAnchorResiduals();
    const s = this.eqCmdScale();
    const xs: number[] = [18];
    const ys: number[] = [this.eqGainY(this.eqAnchoredDb(50, residuals))];
    const qs: number[] = [1];
    for (let i = 0; i < this.bandCount(); i++) {
      xs.push(this.eqBandDotX(i));
      ys.push(this.eqBandDotY(i));
      qs.push(this.bandAt(i).q);
    }
    xs.push(this.eqCurveWidth);
    ys.push(this.eqGainY(this.eqAnchoredDb(16000, residuals)));
    qs.push(1);
    return this.eqSplineCommands(xs, ys, qs, s);
  }

  private eqCurveFillCommands(): string {
    const s = this.eqCmdScale();
    return `${this.eqCurveStrokeCommands()} L${(this.eqCurveWidth * s).toFixed(1)},${(114 * s).toFixed(1)} L${(18 * s).toFixed(1)},${(114 * s).toFixed(1)} Z`;
  }

  private eqMiniFreqX(freqHz: number): number {
    const f = Math.max(50, Math.min(16000, freqHz));
    return 8 + Math.log10(f / 50) / Math.log10(320) * 154;
  }

  private eqMiniGainY(gainDb: number): number {
    let y = 24 - gainDb * 1.5;
    if (y < 6) {
      y = 6;
    } else if (y > 40) {
      y = 40;
    }
    return y;
  }

  // 说明: mini 预览曲线与主曲线同源样条，仅坐标映射不同（8~162 宽 44 高小图）。
  private eqMiniCurveCommands(): string {
    this.curveEq.setBands(this.eqBands, this.eqPreviewSampleRate());
    const residuals = this.eqAnchorResiduals();
    const s = this.eqCmdScale();
    const xs: number[] = [8];
    const ys: number[] = [this.eqMiniGainY(this.eqAnchoredDb(50, residuals))];
    const qs: number[] = [1];
    for (let i = 0; i < this.bandCount(); i++) {
      const band = this.bandAt(i);
      xs.push(this.eqMiniFreqX(band.freqHz));
      ys.push(this.eqMiniGainY(band.gainDb));
      qs.push(band.q);
    }
    xs.push(162);
    ys.push(this.eqMiniGainY(this.eqAnchoredDb(16000, residuals)));
    qs.push(1);
    return this.eqSplineCommands(xs, ys, qs, s);
  }

  private pickSource(choice: number): void {
    if (this.sourceChoice !== choice) {
      this.sourceChoice = choice;
      this.svc.onConfigChanged();
    }
  }

  private pickRate(idx: number): void {
    if (this.rateEnabled(idx) && this.rateChoice !== idx) {
      this.rateChoice = idx;
      this.svc.onConfigChanged();
    }
  }

  private pickBits(idx: number): void {
    if (this.bitsEnabled(idx) && this.bitsChoice !== idx) {
      this.bitsChoice = idx;
      this.svc.onConfigChanged();
    }
  }

  private pickChannels(idx: number): void {
    if (this.channelEnabled(idx) && this.channelChoice !== idx) {
      this.channelChoice = idx;
      this.svc.onConfigChanged();
    }
  }

  private pickNr(choice: number): void {
    if (this.nrEnabled(choice) && this.nrChoice !== choice) {
      this.nrChoice = choice;
      this.svc.onConfigChanged();
    }
  }

  // 说明: @Builder 按值传递状态变量不会触发 UI 刷新（官方文档规则），
  // 因此以下 Pill/Header 均为专用 Builder，仅在内部直接读取 this 状态，
  // 参数只传常量（索引/文案），保证选中态、禁用态、展开态实时刷新。

  @Builder
  SourcePill(idx: number, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.pillTextColor(this.sourceChoice === idx))
      .height(this.pillHeight())
      .padding({ left: this.pillHPadding(), right: this.pillHPadding() })
      .margin({ right: 8, bottom: 8 })
      .borderRadius(this.pillRadius())
      .backgroundColor(this.pillBgColor(this.sourceChoice === idx))
      .opacity(this.probing ? 0.35 : 1)
      .onClick(() => {
        if (!this.probing) {
          this.pickSource(idx);
        }
      })
  }

  @Builder
  RatePill(idx: number, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.pillTextColor(this.rateChoice === idx))
      .height(this.pillHeight())
      .padding({ left: this.pillHPadding(), right: this.pillHPadding() })
      .margin({ right: 8, bottom: 8 })
      .borderRadius(this.pillRadius())
      .backgroundColor(this.pillBgColor(this.rateChoice === idx))
      .opacity(this.rateEnabled(idx) ? 1 : 0.35)
      .onClick(() => {
        if (this.rateEnabled(idx)) {
          this.pickRate(idx);
        }
      })
  }

  @Builder
  BitsPill(idx: number, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.pillTextColor(this.bitsChoice === idx))
      .height(this.pillHeight())
      .padding({ left: this.pillHPadding(), right: this.pillHPadding() })
      .margin({ right: 8, bottom: 8 })
      .borderRadius(this.pillRadius())
      .backgroundColor(this.pillBgColor(this.bitsChoice === idx))
      .opacity(this.bitsEnabled(idx) ? 1 : 0.35)
      .onClick(() => {
        if (this.bitsEnabled(idx)) {
          this.pickBits(idx);
        }
      })
  }

  @Builder
  ChannelPill(idx: number, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.pillTextColor(this.channelChoice === idx))
      .height(this.pillHeight())
      .padding({ left: this.pillHPadding(), right: this.pillHPadding() })
      .margin({ right: 8, bottom: 8 })
      .borderRadius(this.pillRadius())
      .backgroundColor(this.pillBgColor(this.channelChoice === idx))
      .opacity(this.channelEnabled(idx) ? 1 : 0.35)
      .onClick(() => {
        if (this.channelEnabled(idx)) {
          this.pickChannels(idx);
        }
      })
  }

  @Builder
  NrPill(idx: number, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.pillTextColor(this.nrChoice === idx))
      .height(this.pillHeight())
      .padding({ left: this.pillHPadding(), right: this.pillHPadding() })
      .margin({ right: 8, bottom: 8 })
      .borderRadius(this.pillRadius())
      .backgroundColor(this.pillBgColor(this.nrChoice === idx))
      .opacity(this.nrEnabled(idx) ? 1 : 0.35)
      .onClick(() => {
        if (this.nrEnabled(idx)) {
          this.pickNr(idx);
        }
      })
  }

  @Builder
  DfPill(tier: number, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.pillTextColor(this.dfStrength === tier))
      .height(this.pillHeight())
      .padding({ left: this.pillHPadding(), right: this.pillHPadding() })
      .margin({ right: 8, bottom: 8 })
      .borderRadius(this.pillRadius())
      .backgroundColor(this.pillBgColor(this.dfStrength === tier))
      .onClick(() => {
        this.svc.setDfStrength(tier);
      })
  }

  @Builder
  SourceHeader() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('音源')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.txtPrimary())
        Text(this.sourceName(this.sourceChoice))
          .fontSize(12)
          .fontColor(this.txtHint())
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('›')
        .fontSize(18)
        .fontColor(this.txtChevron())
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .rotate({ angle: this.expandSource ? 90 : 0 })
        .animation({ curve: this.foldCurve })
    }
    .width('100%')
    .height(48)
    .onClick(() => {
      MicLogger.info('fold tap: source');
      this.expandSource = !this.expandSource;
    })
  }

  @Builder
  ParamHeader() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('音频参数')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.txtPrimary())
        Text(this.paramSummary())
          .fontSize(12)
          .fontColor(this.txtHint())
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('›')
        .fontSize(18)
        .fontColor(this.txtChevron())
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .rotate({ angle: this.expandParam ? 90 : 0 })
        .animation({ curve: this.foldCurve })
    }
    .width('100%')
    .height(48)
    .onClick(() => {
      MicLogger.info('fold tap: param');
      this.expandParam = !this.expandParam;
    })
  }

  @Builder
  NrHeader() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('降噪')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.txtPrimary())
        Text(this.nrSummary())
          .fontSize(12)
          .fontColor(this.txtHint())
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('›')
        .fontSize(18)
        .fontColor(this.txtChevron())
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .rotate({ angle: this.expandNr ? 90 : 0 })
        .animation({ curve: this.foldCurve })
    }
    .width('100%')
    .height(48)
    .onClick(() => {
      MicLogger.info('fold tap: nr');
      this.expandNr = !this.expandNr;
    })
  }

  @Builder
  EqHeader() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('参数均衡器')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.txtPrimary())
        Text(this.eqSummary())
          .fontSize(12)
          .fontColor(this.txtHint())
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('›')
        .fontSize(18)
        .fontColor(this.txtChevron())
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .rotate({ angle: this.expandEq ? 90 : 0 })
        .animation({ curve: this.foldCurve })
    }
    .width('100%')
    .height(48)
    .onClick(() => {
      MicLogger.info('fold tap: eq');
      this.expandEq = !this.expandEq;
    })
  }

  @Builder
  SourcePills() {
    Flex({ wrap: FlexWrap.Wrap }) {
      this.SourcePill(0, '通话增强')
      this.SourcePill(1, '原始MIC')
      this.SourcePill(2, '语音识别')
      this.SourcePill(3, '语音消息(可降噪)')
    }
    .width('100%')
    .padding({ top: 4 })
    .transition(TransitionEffect.OPACITY.animation({ curve: this.foldCurve }))
  }

  @Builder
  SourceCell(idx: number, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.sourceChoice === idx ? $r('app.color.btn_selected_text') : $r('app.color.text_primary'))
      .height(40)
      .layoutWeight(1)
      .borderRadius(20)
      .backgroundColor(this.sourceChoice === idx ? $r('app.color.accent') : $r('app.color.btn_unselected_bg'))
      .opacity(this.probing ? 0.35 : 1)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        if (!this.probing) {
          this.pickSource(idx);
        }
      })
  }

  @Builder
  SourceGrid() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        this.SourceCell(0, '通话增强')
        this.SourceCell(1, '原始MIC')
      }
      .width('100%')
      Row({ space: 8 }) {
        this.SourceCell(2, '语音识别')
        this.SourceCell(3, '语音消息')
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  SourceSection() {
    Column() {
      this.SourceHeader()
      if (this.expandSource) {
        this.SourcePills()
      }
    }
    .width('100%')
  }

  @Builder
  ParamPills() {
    Column() {
      Row({ space: 8 }) {
        Text('采样率')
          .fontSize(12)
          .fontColor(this.txtSecondary())
          .width(52)
        Flex({ wrap: FlexWrap.Wrap }) {
          this.RatePill(0, '16kHz')
          this.RatePill(1, '48kHz')
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 8 }) {
        Text('位深')
          .fontSize(12)
          .fontColor(this.txtSecondary())
          .width(52)
        Flex({ wrap: FlexWrap.Wrap }) {
          this.BitsPill(0, '16bit')
          this.BitsPill(1, '24bit')
          this.BitsPill(2, '32bit')
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 8 }) {
        Text('声道')
          .fontSize(12)
          .fontColor(this.txtSecondary())
          .width(52)
        Flex({ wrap: FlexWrap.Wrap }) {
          this.ChannelPill(0, '单声道')
          this.ChannelPill(1, '立体声')
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .transition(TransitionEffect.OPACITY.animation({ curve: this.foldCurve }))
  }

  @Builder
  ParamSection() {
    Column() {
      this.ParamHeader()
      if (this.expandParam) {
        this.ParamPills()
      }
    }
    .width('100%')
  }

  @Builder
  NrPills() {
    Column() {
      Row({ space: 8 }) {
        Text('模式')
          .fontSize(12)
          .fontColor(this.txtSecondary())
          .width(52)
        Flex({ wrap: FlexWrap.Wrap }) {
          this.NrPill(0, '默认')
          this.NrPill(1, '标准')
          this.NrPill(2, '人声')
          this.NrPill(3, '高保真')
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 10 }) {
        AudioSwitch({ isOn: this.proNrMode, dark: this.forceDark })
          .opacity(this.proNrAvailable ? 1 : 0.4)
        Text('DeepFilterNet3 神经网络降噪 (强制48kHz单声道)')
          .fontSize(12)
          .fontColor(this.txtPrimary())
          .layoutWeight(1)
      }
      .width('100%')
      .height(48)
      .onClick(() => {
        if (this.proNrAvailable) {
          this.proNrMode = !this.proNrMode;
          this.svc.onConfigChanged();
        }
      })

      if (this.proNrMode) {
        Row({ space: 8 }) {
          Text('强度')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width(52)
          Flex({ wrap: FlexWrap.Wrap }) {
            this.DfPill(0, '标准')
            this.DfPill(1, '增强')
            this.DfPill(2, '极致')
          }
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }

      Row({ space: 10 }) {
        AudioSwitch({ isOn: this.noisyEnvPreset, dark: this.forceDark })
        Text('嘈杂环境模式 (语音消息源+人声降噪+DF3极致，两级串联降噪)')
          .fontSize(12)
          .fontColor(this.txtPrimary())
          .layoutWeight(1)
      }
      .width('100%')
      .height(48)
      .onClick(() => {
        this.svc.applyNoisyEnvPreset(!this.noisyEnvPreset);
      })

      Text(this.probeText)
        .fontSize(12)
        .fontColor(this.probing ? $r('app.color.text_warn') : this.txtSecondary())
        .width('100%')
      if (!this.proNrAvailable) {
        Text('当前设备不支持 DeepFilterNet3 神经网络降噪')
          .fontSize(12)
          .fontColor(this.txtHint())
          .width('100%')
      }
      Text('注: DeepFilterNet3 为端侧神经网络离线降噪，强度档实时生效；降噪模式单选仅对「语音消息」音源生效')
        .fontSize(12)
        .fontColor($r('app.color.text_hint'))
        .width('100%')
      if (this.channelChoice === 1) {
        Text('提示: 部分机型立体声为伪立体声，请实测左右声道差异')
          .fontSize(12)
          .fontColor(this.txtHint())
          .width('100%')
      }
    }
    .width('100%')
    .transition(TransitionEffect.OPACITY.animation({ curve: this.foldCurve }))
  }

  @Builder
  NrSection() {
    Column() {
      this.NrHeader()
      if (this.expandNr) {
        this.NrPills()
      }
    }
    .width('100%')
  }

  private gainText(): string {
    return `${this.gainDb > 0 ? '+' : ''}${this.gainDb.toFixed(1)} dB`;
  }

  private showLimiterHint(): void {
    try {
      this.getUIContext().getPromptAction().showToast({
        message: '当声音过大导致破音时，自动压低音量保护听感。',
        duration: 2500,
        systemMaterial: Mat.toast
      });
    } catch (error) {
      // 提示展示失败时忽略，不影响主流程
    }
  }

  @Builder
  GainRow() {
    Column({ space: 12 }) {
      Row() {
        Text('输入增益')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.txtPrimary())
        Blank()
        Text(this.gainText())
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      AudioSlider({
        value: this.gainDb,
        onValue: (v: number): void => {
          this.svc.setGainDb(v);
        },
        dark: this.forceDark
      })

      Row() {
        Column({ space: 2 }) {
          Row({ space: 4 }) {
            Text('LIMIT 限制器')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.txtPrimary())
            Column() {
              SymbolGlyph($r('sys.symbol.questionmark_circle'))
                .fontSize(14)
                .fontColor([this.txtHint()])
            }
            .width(20)
            .height(20)
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.showLimiterHint();
            })
          }
          .alignItems(VerticalAlign.Center)
          Text('平滑过载峰值，防止声音破音')
            .fontSize(12)
            .fontColor(this.txtHint())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row({ space: 6 }) {
          Text('LIMIT')
            .fontSize(9)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.forceDark ? '#80FFFFFF' : $r('app.color.text_hint'))
            .letterSpacing(0.5)
          AudioSwitch({ isOn: this.limiterOn, compact: true, dark: this.forceDark })
        }
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.svc.setLimiterOn(!this.limiterOn);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  @Builder
  EqCurve() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.eqCurveWidth >= 40) {
        Column().width(this.eqCurveWidth - 18).height(1).backgroundColor(this.forceDark ? '#0FFFFFFF' : $r('app.color.card_bg_alt')).position({ x: 18, y: 6 })
        Column().width(this.eqCurveWidth - 18).height(1).backgroundColor(this.forceDark ? '#0FFFFFFF' : $r('app.color.card_bg_alt')).position({ x: 18, y: 33 })
        Column().width(this.eqCurveWidth - 18).height(1).backgroundColor(this.forceDark ? '#21FFFFFF' : $r('app.color.clip_idle')).position({ x: 18, y: 60 })
        Column().width(this.eqCurveWidth - 18).height(1).backgroundColor(this.forceDark ? '#0FFFFFFF' : $r('app.color.card_bg_alt')).position({ x: 18, y: 87 })
        Column().width(this.eqCurveWidth - 18).height(1).backgroundColor(this.forceDark ? '#0FFFFFFF' : $r('app.color.card_bg_alt')).position({ x: 18, y: 114 })
        ForEach(this.eqGridFreqs(), (f: number) => {
          Column().width(1).height(108).backgroundColor(this.forceDark ? '#0DFFFFFF' : $r('app.color.card_bg_alt')).position({ x: this.eqFreqX(f), y: 6 })
        }, (f: number): string => `grid${f}`)
        Text('+12').fontSize(7.5).fontColor(this.forceDark ? '#6A6A72' : $r('app.color.text_hint')).position({ x: 0, y: 2 })
        Text('0').fontSize(7.5).fontColor(this.forceDark ? '#6A6A72' : $r('app.color.text_hint')).position({ x: 0, y: 56 })
        Text('-12').fontSize(7.5).fontColor(this.forceDark ? '#6A6A72' : $r('app.color.text_hint')).position({ x: 0, y: 110 })
        Path()
          .commands(this.eqCurveFillCommands())
          .fill(this.forceDark ? '#120A84FF' : $r('app.color.accent_10'))
          .strokeOpacity(0)
          .width(this.eqCurveWidth)
          .height(124)
          .position({ x: 0, y: 0 })
        Path()
          .commands(this.eqCurveStrokeCommands())
          .fillOpacity(0)
          .stroke(this.forceDark ? '#FF0A84FF' : $r('app.color.accent'))
          .strokeWidth(2)
          .strokeLineCap(LineCapStyle.Round)
          .width(this.eqCurveWidth)
          .height(124)
          .position({ x: 0, y: 0 })
        ForEach(this.eqBandIndices(), (i: number) => {
          Circle({ width: 9, height: 9 })
            .fill($r('app.color.accent'))
            .stroke(Color.White)
            .strokeWidth(1.5)
            .position({ x: this.eqBandDotX(i), y: this.eqBandDotY(i) })
            .markAnchor({ x: 4.5, y: 4.5 })
        }, (i: number): string => `dot${i}`)
        ForEach(this.eqGridFreqs(), (f: number) => {
          Text(this.eqFreqLabel(f)).fontSize(8).fontColor(this.forceDark ? '#6A6A72' : $r('app.color.text_hint')).position({ x: this.eqFreqX(f), y: 116 }).markAnchor({ x: '50%' })
        }, (f: number): string => `lab${f}`)
      }
    }
    .width('100%')
    .height(124)
    .margin({ top: 8 })
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w = newArea.width;
      if (typeof w === 'number' && w > 40) {
        this.eqCurveWidth = w;
      }
    })
  }

  @Builder
  BandRow(i: number) {
    Column() {
      if (i > 0) {
        Divider()
          .strokeWidth(0.5)
          .color($r('app.color.divider'))
      }
      Row({ space: 8 }) {
        Text(`${i + 1}`)
          .width(20)
          .height(20)
          .borderRadius(10)
          .fontSize(10.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.forceDark ? '#FF409CFF' : $r('app.color.accent'))
          .backgroundColor(this.forceDark ? '#260A84FF' : $r('app.color.accent_10'))
          .textAlign(TextAlign.Center)
        Text(this.eqBandName(i))
          .fontSize(11)
          .fontColor(this.forceDark ? '#C7C7CC' : $r('app.color.text_hint'))
          .layoutWeight(1)
          .maxLines(1)
        Row() {
          Text(this.bandGainText(i))
            .fontSize(12.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.forceDark ? '#E6E6E6' : $r('app.color.text_primary'))
          Text('dB')
            .fontSize(9)
            .fontColor(this.txtHint())
            .margin({ left: 2 })
        }
        .alignItems(VerticalAlign.Center)
        Text(this.bandQText(i))
          .width(46)
          .fontSize(10.5)
          .textAlign(TextAlign.End)
          .fontColor(this.isShelf(i) ? (this.forceDark ? '#FF55555F' : $r('app.color.text_subtitle')) : (this.forceDark ? '#8A8A95' : $r('app.color.text_hint')))
      }
      .width('100%')
      .height(22)
      .alignItems(VerticalAlign.Center)
      .margin({ top: 6 })

      Row({ space: 10 }) {
        Text('−')
          .width(26)
          .height(26)
          .borderRadius(13)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.forceDark ? '#C7C7CC' : $r('app.color.text_subtitle'))
          .backgroundColor(this.forceDark ? '#14FFFFFF' : $r('app.color.clip_idle'))
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.nudgeBandGain(i, -0.1);
          })
        Stack({ alignContent: Alignment.Start }) {
          Column()
            .width('100%')
            .height(3)
            .borderRadius(1.5)
            .backgroundColor(this.forceDark ? '#21FFFFFF' : $r('app.color.clip_idle'))
            .position({ x: 0, y: 11.5 })
          Column()
            .width(1)
            .height(9)
            .backgroundColor(this.forceDark ? '#47FFFFFF' : $r('app.color.text_subtitle'))
            .position({ x: '50%', y: 8.5 })
          Column()
            .height(3)
            .borderRadius(1.5)
            .backgroundColor($r('app.color.accent'))
            .position({ x: this.bandFillLeft(i), y: 11.5 })
            .width(this.bandFillWidth(i))
          Circle({ width: 14, height: 14 })
            .fill(Color.White)
            .shadow({ radius: 4, color: '#59333333', offsetY: 1 })
            .position({ x: `${this.bandPct(i)}%`, y: 6 })
            .markAnchor({ x: 7 })
        }
        .layoutWeight(1)
        .height(26)
        .onAreaChange((oldArea: Area, newArea: Area) => {
          const w = newArea.width;
          if (typeof w === 'number') {
            this.bandSliderWidths[i] = w;
          }
        })
        .onTouch((event: TouchEvent) => {
          this.onBandTouch(event, i);
        })
        Text('+')
          .width(26)
          .height(26)
          .borderRadius(13)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.forceDark ? '#C7C7CC' : $r('app.color.text_subtitle'))
          .backgroundColor(this.forceDark ? '#14FFFFFF' : $r('app.color.clip_idle'))
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.nudgeBandGain(i, 0.1);
          })
      }
      .width('100%')
      .height(26)
      .alignItems(VerticalAlign.Center)
      .margin({ top: 4, bottom: 6 })
    }
    .width('100%')
  }

  @Builder
  EqMiniPreview() {
    Row({ space: 14 }) {
      Stack({ alignContent: Alignment.Start }) {
        Column().width(154).height(1).backgroundColor('#17FFFFFF').position({ x: 8, y: 24 })
        Column().width(1).height(32).backgroundColor('#0DFFFFFF').position({ x: 47, y: 6 })
        Column().width(1).height(32).backgroundColor('#0DFFFFFF').position({ x: 86, y: 6 })
        Column().width(1).height(32).backgroundColor('#0DFFFFFF').position({ x: 125, y: 6 })
        Path()
          .commands(this.eqMiniCurveCommands())
          .fillOpacity(0)
          .stroke(this.eqBypass ? '#FF55555F' : $r('app.color.accent'))
          .strokeWidth(1.8)
          .strokeLineCap(LineCapStyle.Round)
          .width(170)
          .height(44)
          .position({ x: 0, y: 0 })
        Circle({ width: 6, height: 6 })
          .fill(this.eqBypass ? '#FF55555F' : $r('app.color.accent'))
          .stroke(this.eqBypass ? '#4DFFFFFF' : Color.White)
          .strokeWidth(1.2)
          .position({ x: this.eqMiniFreqX(this.bandAt(Math.floor(this.bandCount() / 2)).freqHz), y: this.eqMiniGainY(this.bandAt(Math.floor(this.bandCount() / 2)).gainDb) })
          .markAnchor({ x: 3, y: 3 })
      }
      .width(170)
      .height(44)
      Blank()
      Text('调节 ›')
        .fontSize(12.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.eqBypass ? '#FF55555F' : $r('app.color.accent'))
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor('#E6161619')
    .margin({ top: 2 })
    .transition(TransitionEffect.OPACITY.animation({ curve: this.foldCurve }))
    .onClick(() => {
      this.expandEq = true;
    })
  }

  @Builder
  EqSection() {
    Column() {
      this.EqHeader()
      if (!this.expandEq) {
        this.EqMiniPreview()
      }
      // 说明: 展开体常挂载——Scroll 对子组件施加无限高度约束，内容恒按自然高度测量（onAreaChange 回填 eqBodyH），
      // 外层在 0 与自然高度之间做高度/透明度动画并裁剪，实现展开/折叠卡片动画（替代 if 挂载的瞬时跳变）。
      Scroll() {
        Column() {
          Row({ space: 8 }) {
            Text('旁通')
              .fontSize(12)
              .fontColor(this.txtHint())
            AudioSwitch({ isOn: this.eqBypass, dark: this.forceDark })
          }
          .width('100%')
          .height(44)
          .justifyContent(FlexAlign.End)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.svc.setEqBypass(!this.eqBypass);
          })

          this.EqCurve()

          ForEach(this.eqBandIndices(), (i: number) => {
            this.BandRow(i)
          }, (i: number): string => `row${i}`)

          Row({ space: 8 }) {
            ForEach(this.eqPresetChips(), (chip: EqPresetChip) => {
              Text(chip.label)
                .fontSize(12)
                .height(32)
                .borderRadius(16)
                .padding({ left: 15, right: 15 })
                .fontColor(chip.name === this.eqPreset ? (this.forceDark ? '#FF409CFF' : $r('app.color.accent')) : (this.forceDark ? '#C7C7CC' : $r('app.color.text_secondary')))
                .fontWeight(chip.name === this.eqPreset ? FontWeight.Medium : FontWeight.Normal)
                .backgroundColor(chip.name === this.eqPreset ? (this.forceDark ? '#290A84FF' : $r('app.color.accent_10')) : (this.forceDark ? '#FF2A2A31' : $r('app.color.btn_unselected_bg')))
                .border(this.presetBorder(chip.name === this.eqPreset))
                .onClick(() => {
                  this.svc.setEqPreset(chip.name);
                })
            }, (chip: EqPresetChip): string => chip.name)
          }
          .width('100%')
          .padding({ top: 16 })
        }
        .width('100%')
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const h = newArea.height;
          if (typeof h === 'number' && h > 0) {
            this.eqBodyH = h;
          }
        })
      }
      .width('100%')
      .height(this.expandEq ? this.eqBodyH : 0)
      .opacity(this.expandEq ? 1 : 0)
      .clip(true)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      // 说明: 展开体高度恒等于内容高度（自身无滚动余量），嵌套滚动手势全部转发父级页面，避免拦截滑动。
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.PARENT_FIRST })
      .animation({ duration: 300, curve: Curve.EaseInOut })
    }
    .width('100%')
  }

  private cfgSummaryText(): string {
    return `${this.sourceName(this.sourceChoice)} · ${this.paramSummary()} · ${this.nrSummary()}`;
  }

  private segThumbW(): number {
    return (this.segBarWidth - 8) / 3;
  }

  private segThumbOffset(): number {
    return this.segIndex * this.segThumbW();
  }

  private segHeight(): number {
    if (this.segIndex === 0) {
      return 100;
    }
    if (this.segIndex === 1) {
      return 150;
    }
    return 280;
  }

  @Builder
  SegmentSummary() {
    Row({ space: 8 }) {
      Text(this.cfgSummaryText())
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('›')
        .fontSize(18)
        .fontColor(this.txtChevron())
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .rotate({ angle: this.configExpanded ? 90 : 0 })
        .animation({ curve: this.foldCurve })
    }
    .width('100%')
    .height(44)
    .onClick(() => {
      MicLogger.info(this.configExpanded ? 'cfg card fold' : 'cfg card expand');
      this.getUIContext().animateTo({ duration: 300, curve: Curve.Friction }, (): void => {
        this.configExpanded = !this.configExpanded;
      });
    })
  }

  @Builder
  SegmentItem(index: number, label: string) {
    Column() {
      Text(label)
        .fontSize(12.5)
        .fontWeight(this.segIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.segIndex === index ? $r('app.color.accent') : $r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      MicLogger.info(`seg tap: ${index}`);
      this.getUIContext().animateTo({ duration: 300, curve: Curve.Friction }, (): void => {
        this.segIndex = index;
      });
    })
  }

  @Builder
  SegmentBar() {
    Stack({ alignContent: Alignment.Start }) {
      Column()
        .width(this.segThumbW())
        .height(28)
        .borderRadius(14)
        .margin({ left: 4 })
        .backgroundColor($r('app.color.seg_thumb_bg'))
        .translate({ x: this.segThumbOffset() })
        .animation({ curve: curves.springMotion(0.35, 0.85) })
      Row() {
        this.SegmentItem(0, '音源')
        this.SegmentItem(1, '参数')
        this.SegmentItem(2, '降噪')
      }
      .width('100%')
      .height(36)
      .padding({ left: 4, right: 4 })
    }
    .width('100%')
    .height(36)
    .borderRadius(18)
    .backgroundColor($r('app.color.btn_unselected_bg'))
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w = newArea.width;
      if (typeof w === 'number') {
        this.segBarWidth = w;
      }
    })
  }

  @Builder
  SegmentTabs() {
    Tabs({ index: this.segIndex }) {
      TabContent() {
        Column() {
          this.SourceGrid()
        }
        .width('100%')
      }
      TabContent() {
        Column() {
          this.ParamPills()
        }
        .width('100%')
      }
      TabContent() {
        Column() {
          this.NrPills()
        }
        .width('100%')
      }
    }
    .width('100%')
    .height(this.segHeight())
    .barHeight(0)
    .onChange((index: number) => {
      this.getUIContext().animateTo({ duration: 300, curve: Curve.Friction }, (): void => {
        this.segIndex = index;
      });
    })
  }

  build() {
    Column() {
      if (this.segmentMode) {
        if (!this.segmentFlat) {
          this.SegmentSummary()
        }
        if (this.segmentFlat || this.configExpanded) {
          Column({ space: 10 }) {
            this.SegmentBar()
            this.SegmentTabs()
          }
          .width('100%')
          .transition(TransitionEffect.OPACITY.animation({ curve: this.foldCurve }))
        }
      } else {
        Column({ space: this.forceDark ? 16 : 0 }) {
          this.SourceSection()
          if (!this.forceDark) {
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ top: 2, bottom: 2 })
          }
          this.ParamSection()
          if (!this.forceDark) {
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ top: 2, bottom: 2 })
          }
          this.NrSection()
          if (!this.forceDark) {
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ top: 2, bottom: 2 })
          }
          this.GainRow()
          if (this.showEq) {
            if (!this.forceDark) {
              Divider()
                .strokeWidth(0.5)
                .color($r('app.color.divider'))
                .margin({ top: 2, bottom: 2 })
            }
            this.EqSection()
          }
        }
      }
    }
    .width('100%')
  }
}
