import { AudioVizManager, VIZ_MIN_FREQ } from 'common';

export interface RenderOpts {
  streaming: boolean;
  showBars: boolean;
  showWave: boolean;
  deco: number;
  nrActive: boolean;
  w: number;
  h: number;
  scale: number;
  pageMode: boolean;
}

const VIZ_BAR_BARS = 48;
const VIZ_CHART_DB_FLOOR = -90;
const VIZ_GRID_DB: number[] = [0, -30, -60, -90];
const VIZ_FREQ_MARKS: number[] = [100, 1000, 4000, 16000];
const VIZ_WAVE_REF_DB: number[] = [-6, -12];

export function fmtDb(db: number): string {
  if (db <= -99) {
    return '-∞';
  }
  return db.toFixed(1);
}

export class VizRenderer {
  private context: CanvasRenderingContext2D;
  private onDbText: ((text: string, clip: boolean) => void) | null;
  private tickCount: number = 0;
  private wavePhaseDeg: number = 0;
  private smoothLevel: number = 0;
  private isDark: boolean = false;
  private peakHold: Float32Array = new Float32Array(VIZ_BAR_BARS);
  private waveCacheMin: Float32Array = new Float32Array(400);
  private waveCacheMax: Float32Array = new Float32Array(400);

  constructor(context: CanvasRenderingContext2D, onDbText: ((text: string, clip: boolean) => void) | null) {
    this.context = context;
    this.onDbText = onDbText;
    this.peakHold.fill(VIZ_CHART_DB_FLOOR);
  }

  setDark(isDark: boolean): void {
    this.isDark = isDark;
  }

  render(viz: AudioVizManager, opts: RenderOpts): void {
    const w = opts.w;
    const h = opts.h;
    if (w <= 0 || h <= 0) {
      return;
    }
    if (!opts.streaming) {
      this.tickCount++;
      this.wavePhaseDeg = (this.wavePhaseDeg + 2.4) % 360;
      this.peakHold.fill(VIZ_CHART_DB_FLOOR);
      this.drawIdle(w, h, opts.scale, opts.pageMode);
      this.emitDb('RMS -- dB · 峰值 -- dB', false);
      return;
    }
    viz.tick();
    this.tickCount++;
    this.wavePhaseDeg = (this.wavePhaseDeg + 4.7) % 360;
    let rms = viz.getRmsDb(true);
    if (rms > 0) {
      rms = 0;
    }
    if (rms < -60) {
      rms = -60;
    }
    const target = (rms + 60) / 60;
    this.smoothLevel += (target - this.smoothLevel) * 0.33;
    if (opts.deco === 1) {
      this.drawMeter(viz, w, h, opts.scale, opts.pageMode);
    } else if (opts.deco === 2) {
      this.drawRipple(w, h, opts.scale, opts.pageMode);
    } else if (opts.showBars) {
      this.drawBarsChart(viz, opts, 0, 0, w, h);
    } else if (opts.showWave) {
      this.drawWaveChart(viz, opts, 0, 0, w, h);
    } else {
      this.drawIdle(w, h, opts.scale, opts.pageMode);
    }
    if (this.tickCount % 3 === 0) {
      this.emitDb(`RMS ${fmtDb(viz.getRmsDb(true))} dB · 峰值 ${fmtDb(viz.getPeakDb(true))} dB`,
        viz.isClipping(true));
    }
  }

  private emitDb(text: string, clip: boolean): void {
    const cb = this.onDbText;
    if (cb !== null) {
      cb(text, clip);
    }
  }

  private pick(light: string, dark: string): string {
    return this.isDark ? dark : light;
  }

  private accent(alpha: number): string {
    const rgb = this.isDark ? '58,155,255' : '0,125,255';
    return `rgba(${rgb},${alpha})`;
  }

  private levelColor(t: number, alpha: number): string {
    let rgb = this.isDark ? '58,155,255' : '0,125,255';
    if (t > 0.9) {
      rgb = '244,67,54';
    } else if (t > 0.7) {
      rgb = '255,152,0';
    }
    return `rgba(${rgb},${alpha})`;
  }

  private fontScale(scale: number): number {
    if (scale < 0.9) {
      return 0.9;
    }
    if (scale > 1.6) {
      return 1.6;
    }
    return scale;
  }

  // 说明: 网格刻度统一字号——频谱 dB 刻度/频率刻度/波形参考线标签共用，保证两图观感一致。
  private gridLabelSize(fs: number): number {
    return Math.max(11, Math.round(9 * fs));
  }

  private strokeScale(scale: number): number {
    if (scale < 1) {
      return 1;
    }
    if (scale > 1.5) {
      return 1.5;
    }
    return scale;
  }

  private panelColor(pageMode: boolean): string {
    if (pageMode) {
      return '#14141A';
    }
    return this.pick('#FFFFFF', '#1E1E1E');
  }

  private gridColor(pageMode: boolean): string {
    if (pageMode) {
      return 'rgba(255,255,255,0.06)';
    }
    return this.pick('rgba(0,0,0,0.06)', 'rgba(255,255,255,0.06)');
  }

  private labelColor(pageMode: boolean): string {
    if (pageMode) {
      return '#8A8A93';
    }
    return 'rgba(255,255,255,0.5)';
  }

  private titleColor(pageMode: boolean): string {
    if (pageMode) {
      return '#6E6E78';
    }
    return this.pick('#666666', '#999999');
  }

  private drawPanel(x: number, y: number, w: number, h: number, pageMode: boolean, title: string,
    showText: boolean, pad: number, fs: number): void {
    const ctx = this.context;
    ctx.clearRect(x, y, w, h);
    if (pageMode) {
      // 全屏页保留实心面板底；卡片态不填充，透出 systemMaterial 卡片材质与光晕背景
      ctx.fillStyle = this.panelColor(pageMode);
      ctx.beginPath();
      ctx.roundRect(x, y, w, h, 16);
      ctx.fill();
    }
    if (showText) {
      ctx.textAlign = 'left';
      ctx.fillStyle = this.titleColor(pageMode);
      ctx.font = `${Math.round(9 * fs)}vp sans-serif`;
      ctx.fillText(title, x + pad, y + pad + 9 * fs);
    }
  }

  private drawBarsChart(viz: AudioVizManager, opts: RenderOpts, x: number, y: number, w: number,
    hh: number): void {
    if (hh < 24 || w < 40) {
      return;
    }
    const ctx = this.context;
    const ss = this.strokeScale(opts.scale);
    const fs = this.fontScale(opts.scale);
    const pad = 8 * ss;
    const showText = hh >= 110;
    this.drawPanel(x, y, w, hh, opts.pageMode, '电平图', showText, pad, fs);
    const labelW = showText ? 26 * fs : 4 * ss;
    const bottomH = showText ? 15 * fs : 4 * ss;
    const titleH = showText ? 16 * fs : 3 * ss;
    const px = x + pad + labelW;
    const py = y + pad + titleH;
    const pw = w - pad * 2 - labelW - 4 * ss;
    const ph = hh - pad * 2 - titleH - bottomH;
    if (pw < 16 || ph < 8) {
      return;
    }
    const dbRange = -VIZ_CHART_DB_FLOOR;
    ctx.font = `${this.gridLabelSize(fs)}vp sans-serif`;
    ctx.lineWidth = 1;
    if (showText) {
      // 刻度基线统一: middle 基线让 dB 标签精确垂直居中于网格线
      ctx.textBaseline = 'middle';
    }
    for (let gi = 0; gi < VIZ_GRID_DB.length; gi++) {
      const gdb = VIZ_GRID_DB[gi];
      const gy = py + (-gdb / dbRange) * ph;
      ctx.strokeStyle = this.gridColor(opts.pageMode);
      ctx.beginPath();
      ctx.moveTo(px, gy);
      ctx.lineTo(px + pw, gy);
      ctx.stroke();
      if (showText) {
        ctx.textAlign = 'right';
        ctx.fillStyle = this.labelColor(opts.pageMode);
        ctx.fillText(`${gdb}`, px - 4 * ss, gy);
      }
    }
    if (opts.nrActive) {
      const preBars = viz.getBarDb(false);
      ctx.fillStyle = this.accent(0.16);
      for (let i = 0; i < VIZ_BAR_BARS; i++) {
        let db = preBars[i];
        if (db > 0) {
          db = 0;
        }
        if (db < VIZ_CHART_DB_FLOOR) {
          db = VIZ_CHART_DB_FLOOR;
        }
        const bh = ((db - VIZ_CHART_DB_FLOOR) / dbRange) * ph;
        if (bh < 1) {
          continue;
        }
        ctx.fillRect(px + (pw / VIZ_BAR_BARS) * i, py + ph - bh, Math.max(1, pw / VIZ_BAR_BARS - 1), bh);
      }
    }
    const bars = viz.getBarDb(true);
    const slot = pw / VIZ_BAR_BARS;
    const barW = Math.max(1, slot - 1);
    for (let i = 0; i < VIZ_BAR_BARS; i++) {
      let db = bars[i];
      if (db > 0) {
        db = 0;
      }
      if (db < VIZ_CHART_DB_FLOOR) {
        db = VIZ_CHART_DB_FLOOR;
      }
      const t = (db - VIZ_CHART_DB_FLOOR) / dbRange;
      const bh = t * ph;
      if (bh >= 1) {
        ctx.fillStyle = t >= 0.9 ? 'rgba(244,67,54,0.95)' : this.accent(0.35 + 0.55 * t);
        ctx.fillRect(px + slot * i, py + ph - bh, barW, bh);
      }
      let pk = this.peakHold[i] - 0.8;
      if (db > pk) {
        pk = db;
      }
      this.peakHold[i] = pk;
      const pkT = (pk - VIZ_CHART_DB_FLOOR) / dbRange;
      if (pkT > 0.004) {
        ctx.fillStyle = this.accent(0.6);
        ctx.fillRect(px + slot * i, py + ph - pkT * ph, barW, 2);
      }
    }
    if (showText) {
      const fmax = viz.getMaxFreq();
      const lden = Math.log(fmax / VIZ_MIN_FREQ);
      ctx.fillStyle = this.labelColor(opts.pageMode);
      for (let mi = 0; mi < VIZ_FREQ_MARKS.length; mi++) {
        const f = VIZ_FREQ_MARKS[mi];
        if (f <= VIZ_MIN_FREQ || f > fmax) {
          continue;
        }
        const t = Math.log(f / VIZ_MIN_FREQ) / lden;
        const fx = px + t * pw;
        ctx.strokeStyle = this.gridColor(opts.pageMode);
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(fx, py + ph);
        ctx.lineTo(fx, py + ph + 3 * ss);
        ctx.stroke();
        const label = f >= 1000 ? `${f / 1000}k` : `${f}`;
        if (t > 0.92) {
          ctx.textAlign = 'right';
          ctx.fillText(label, px + pw, py + ph + 13 * fs);
        } else {
          ctx.textAlign = 'center';
          ctx.fillText(label, fx, py + ph + 13 * fs);
        }
      }
      ctx.textAlign = 'left';
      ctx.textBaseline = 'alphabetic';
    }
  }

  private drawWaveChart(viz: AudioVizManager, opts: RenderOpts, x: number, y: number, w: number,
    hh: number): void {
    if (hh < 24 || w < 40) {
      return;
    }
    const ctx = this.context;
    const ss = this.strokeScale(opts.scale);
    const fs = this.fontScale(opts.scale);
    const pad = 8 * ss;
    const showText = hh >= 110;
    this.drawPanel(x, y, w, hh, opts.pageMode, '波形图', showText, pad, fs);
    const labelW = showText ? 26 * fs : 4 * ss;
    const bottomH = 3 * ss;
    const titleH = showText ? 16 * fs : 3 * ss;
    const px = x + pad + labelW;
    const py = y + pad + titleH;
    const pw = w - pad * 2 - labelW - 4 * ss;
    const ph = hh - pad * 2 - titleH - bottomH;
    if (pw < 16 || ph < 8) {
      return;
    }
    const midY = py + ph / 2;
    const halfH = ph / 2 - 2;
    const refLabelSize = this.gridLabelSize(fs);
    ctx.font = `${refLabelSize}vp sans-serif`;
    ctx.lineWidth = 1;
    ctx.strokeStyle = this.gridColor(opts.pageMode);
    ctx.beginPath();
    ctx.moveTo(px, midY);
    ctx.lineTo(px + pw, midY);
    ctx.stroke();
    if (showText) {
      ctx.textBaseline = 'middle';
    }
    // 说明: 参考线标签垂直间距不足字高 1.3 倍时跳过后者（-6dB 优先保留），防卡片高度不足时 -6dB/-12dB 文字重叠。
    let lastRefLabelY = -Number.MAX_VALUE;
    for (let ri = 0; ri < VIZ_WAVE_REF_DB.length; ri++) {
      const amp = Math.pow(10, VIZ_WAVE_REF_DB[ri] / 20);
      const yOff = amp * halfH;
      ctx.strokeStyle = this.gridColor(opts.pageMode);
      ctx.setLineDash([3, 3]);
      ctx.beginPath();
      ctx.moveTo(px, midY - yOff);
      ctx.lineTo(px + pw, midY - yOff);
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(px, midY + yOff);
      ctx.lineTo(px + pw, midY + yOff);
      ctx.stroke();
      ctx.setLineDash([]);
      if (showText) {
        const labelY = midY - yOff;
        if (labelY - lastRefLabelY >= refLabelSize * 1.3) {
          ctx.textAlign = 'right';
          ctx.fillStyle = this.labelColor(opts.pageMode);
          ctx.fillText(`${VIZ_WAVE_REF_DB[ri]}dB`, px - 4 * ss, labelY);
          lastRefLabelY = labelY;
        }
      }
    }
    let n = Math.floor(pw);
    if (n > 400) {
      n = 400;
    }
    if (n < 2) {
      return;
    }
    viz.getWaveform(true, n);
    this.waveCacheMin.set(viz.getWaveMin().subarray(0, n));
    this.waveCacheMax.set(viz.getWaveMax().subarray(0, n));
    viz.getWaveform(false, n);
    const step = pw / n;
    if (opts.nrActive) {
      this.fillEnvelope(viz.getWaveMin(), viz.getWaveMax(), n, px, midY, halfH, step);
      ctx.fillStyle = this.accent(0.12);
      ctx.fill();
      ctx.strokeStyle = this.accent(0.3);
      ctx.lineWidth = 1;
      ctx.stroke();
    }
    this.fillEnvelope(this.waveCacheMin, this.waveCacheMax, n, px, midY, halfH, step);
    ctx.fillStyle = this.accent(0.3);
    ctx.fill();
    ctx.strokeStyle = this.accent(0.9);
    ctx.lineWidth = Math.max(1, 1.5 * ss);
    ctx.stroke();
    ctx.textAlign = 'left';
    ctx.textBaseline = 'alphabetic';
  }

  private fillEnvelope(mins: Float32Array, maxs: Float32Array, count: number, x0: number, midY: number,
    halfH: number, step: number): void {
    const ctx = this.context;
    ctx.beginPath();
    for (let i = 0; i < count; i++) {
      const x = x0 + i * step;
      const y = midY - maxs[i] * halfH;
      if (i === 0) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    for (let i = count - 1; i >= 0; i--) {
      ctx.lineTo(x0 + i * step, midY - mins[i] * halfH);
    }
    ctx.closePath();
  }

  private drawIdle(w: number, h: number, scale: number, pageMode: boolean): void {
    const ctx = this.context;
    ctx.clearRect(0, 0, w, h);
    const cx = w / 2;
    const cy = h / 2;
    const ss = this.strokeScale(scale);
    const fs = this.fontScale(scale);
    if (!pageMode) {
      // 卡片态: 透明底仅居中浅灰占位文案，透出卡片材质
      ctx.textAlign = 'center';
      ctx.fillStyle = this.pick('#AAAAAA', '#8E8E96');
      ctx.font = `${Math.round(12 * fs)}vp sans-serif`;
      ctx.fillText('等待音频...', cx, cy + 4 * fs);
      ctx.textAlign = 'left';
      return;
    }
    const base = Math.min(w, h) / 2 - 8 * ss;
    for (let i = 0; i <= 2; i++) {
      const r = base * (0.35 + i * 0.18);
      const a = 0.22 - i * 0.06;
      ctx.strokeStyle = this.accent(a);
      ctx.lineWidth = 2 * ss;
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.stroke();
    }
    const barCount = 36;
    ctx.lineCap = 'round';
    ctx.lineWidth = 2 * ss;
    for (let i = 0; i < barCount; i++) {
      const angleDeg = (i / barCount) * 360 + this.wavePhaseDeg;
      const rad = angleDeg * Math.PI / 180;
      const inner = base * 0.62;
      const hgt = base * 0.08 * (0.5 + 0.5 * Math.sin(angleDeg * 0.08));
      ctx.strokeStyle = this.accent(0.25);
      ctx.beginPath();
      ctx.moveTo(cx + inner * Math.cos(rad), cy + inner * Math.sin(rad));
      ctx.lineTo(cx + (inner + hgt) * Math.cos(rad), cy + (inner + hgt) * Math.sin(rad));
      ctx.stroke();
    }
  }

  private drawRing(w: number, h: number, scale: number, pageMode: boolean): void {
    const ctx = this.context;
    ctx.clearRect(0, 0, w, h);
    if (!pageMode) {
      ctx.fillStyle = this.pick('#FFFFFF', '#1E1E1E');
      ctx.fillRect(0, 0, w, h);
    }
    const cx = w / 2;
    const cy = h / 2;
    const ss = this.strokeScale(scale);
    const fs = this.fontScale(scale);
    const base = Math.min(w, h) / 2 - 14 * ss;
    const level = this.smoothLevel;
    const strokeW = 8 * ss;
    const a0 = -Math.PI / 2;

    if (pageMode) {
      const glow = ctx.createRadialGradient(cx, cy, 0, cx, cy, base * 1.05);
      glow.addColorStop(0, this.accent(0.10 + 0.12 * level));
      glow.addColorStop(1, this.accent(0));
      ctx.fillStyle = glow;
      ctx.fillRect(cx - base * 1.05, cy - base * 1.05, base * 2.1, base * 2.1);
    }

    ctx.strokeStyle = this.accent(0.15);
    ctx.lineWidth = strokeW;
    ctx.lineCap = 'butt';
    ctx.beginPath();
    ctx.arc(cx, cy, base, 0, Math.PI * 2);
    ctx.stroke();

    if (level > 0.003) {
      ctx.lineCap = 'round';
      ctx.strokeStyle = this.levelColor(level, 1);
      ctx.beginPath();
      ctx.arc(cx, cy, base, a0, a0 + Math.PI * 2 * level);
      ctx.stroke();
    }

    if (level > 0.05) {
      const ea = a0 + Math.PI * 2 * level;
      ctx.fillStyle = this.levelColor(level, 0.9);
      ctx.beginPath();
      ctx.arc(cx + Math.cos(ea) * base, cy + Math.sin(ea) * base, strokeW * 0.8, 0, Math.PI * 2);
      ctx.fill();
    }

    const tickCount = 60;
    ctx.lineCap = 'butt';
    for (let i = 0; i < tickCount; i++) {
      const p = i / tickCount;
      const ta = a0 + p * Math.PI * 2;
      const major = i % 5 === 0;
      const tickLen = major ? 6 * ss : 3 * ss;
      const alpha = p <= level ? 0.4 : 0.1;
      const c = Math.cos(ta);
      const s = Math.sin(ta);
      ctx.strokeStyle = this.accent(alpha);
      ctx.lineWidth = major ? Math.max(2, 2 * ss) : 1;
      ctx.beginPath();
      ctx.moveTo(cx + c * (base + strokeW * 0.5), cy + s * (base + strokeW * 0.5));
      ctx.lineTo(cx + c * (base + strokeW * 0.5 + tickLen), cy + s * (base + strokeW * 0.5 + tickLen));
      ctx.stroke();
    }

    const glowR = base * 0.6 * level;
    if (glowR > 0.5) {
      ctx.fillStyle = this.levelColor(level, 0.15 * level);
      ctx.beginPath();
      ctx.arc(cx, cy, glowR, 0, Math.PI * 2);
      ctx.fill();
    }

    if (!pageMode) {
      ctx.textAlign = 'center';
      ctx.fillStyle = this.pick('#333333', '#E6E6E6');
      ctx.font = `bold ${Math.round(20 * fs)}vp sans-serif`;
      const db = -60 + level * 60;
      ctx.fillText(fmtDb(db), cx, cy + 6 * fs);
      ctx.fillStyle = this.pick('#999999', '#888888');
      ctx.font = `${Math.round(9 * fs)}vp sans-serif`;
      ctx.fillText('dB RMS', cx, cy + 18 * fs);
      ctx.textAlign = 'left';
    }
  }

  private drawRipple(w: number, h: number, scale: number, pageMode: boolean): void {
    const ctx = this.context;
    ctx.clearRect(0, 0, w, h);
    const cx = w / 2;
    const cy = h / 2;
    const ss = this.strokeScale(scale);
    const fs = this.fontScale(scale);
    const base = Math.min(w, h) / 2 - 8 * ss;
    const level = Math.max(this.smoothLevel, 0.06);
    const phaseDeg = this.wavePhaseDeg;

    for (let i = 0; i <= 4; i++) {
      const r = base * (0.5 + i * 0.15 * level);
      let a = (0.35 - i * 0.07) * level;
      if (a < 0) {
        a = 0;
      }
      ctx.strokeStyle = this.accent(a);
      ctx.lineWidth = Math.max((4 - i * 0.7) * ss, 1);
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.stroke();
    }

    const barCount = 48;
    ctx.lineCap = 'round';
    ctx.lineWidth = 3 * ss;
    for (let i = 0; i < barCount; i++) {
      const angleDeg = (i / barCount) * 360 + phaseDeg;
      const rad = angleDeg * Math.PI / 180;
      const dyn = level * (0.4 + 0.6 * Math.sin(angleDeg * 0.08 + phaseDeg * 0.025));
      const inner = base * 0.45;
      const hgt = base * 0.18 * dyn;
      ctx.strokeStyle = this.accent(0.5 * level);
      ctx.beginPath();
      ctx.moveTo(cx + inner * Math.cos(rad), cy + inner * Math.sin(rad));
      ctx.lineTo(cx + (inner + hgt) * Math.cos(rad), cy + (inner + hgt) * Math.sin(rad));
      ctx.stroke();
    }

    const glowA = 0.35;
    const steps = 8;
    for (let i = 0; i < steps; i++) {
      const p = i / steps;
      let a = glowA * (1 - p) * level;
      if (a > 0.3) {
        a = 0.3;
      }
      ctx.fillStyle = this.accent(a);
      ctx.beginPath();
      ctx.arc(cx, cy, base * 0.3 * (1 + p * 0.5), 0, Math.PI * 2);
      ctx.fill();
    }

    if (!pageMode) {
      ctx.textAlign = 'center';
      ctx.fillStyle = this.levelColor(this.smoothLevel, 0.9);
      ctx.font = `bold ${Math.round(16 * fs)}vp sans-serif`;
      ctx.fillText(fmtDb(-60 + this.smoothLevel * 60), cx, cy + 5 * fs);
      ctx.textAlign = 'left';
    }
  }

  private meterPos(db: number): number {
    let v = db;
    if (v < -60) {
      v = -60;
    }
    if (v > 0) {
      v = 0;
    }
    return (v + 60) / 60;
  }

  // 说明: 胶囊路径（圆角 = 高度一半），配合 clip() 使用
  private capsulePath(bx: number, by: number, bw: number, bh: number): void {
    const ctx = this.context;
    const r = bh / 2;
    ctx.beginPath();
    ctx.arc(bx + r, by + r, r, Math.PI / 2, Math.PI * 1.5);
    ctx.lineTo(bx + bw - r, by);
    ctx.arc(bx + bw - r, by + r, r, -Math.PI / 2, Math.PI / 2);
    ctx.closePath();
  }

  private meterTrack(bx: number, by: number, bw: number, bh: number, pre: boolean): void {
    const ctx = this.context;
    const r = bh / 2;
    ctx.save();
    ctx.beginPath();
    ctx.arc(bx + r, by + r, r, Math.PI / 2, Math.PI * 1.5);
    ctx.lineTo(bx + bw - r, by);
    ctx.arc(bx + bw - r, by + r, r, -Math.PI / 2, Math.PI / 2);
    ctx.closePath();
    ctx.clip();
    if (pre) {
      ctx.fillStyle = '#55555F';
      ctx.fillRect(bx, by, bw, bh);
    } else {
      const g1 = bw * (40 / 60);
      const g2 = bw * (54 / 60);
      ctx.fillStyle = '#34C759';
      ctx.fillRect(bx, by, g1, bh);
      ctx.fillStyle = '#FFB800';
      ctx.fillRect(bx + g1, by, g2 - g1, bh);
      ctx.fillStyle = '#FF6A6A';
      ctx.fillRect(bx + g2, by, bw - g2, bh);
    }
    ctx.restore();
  }

  private meterCover(bx: number, by: number, bw: number, bh: number, rmsDb: number): void {
    const ctx = this.context;
    const r = bh / 2;
    const coverX = bx + this.meterPos(rmsDb) * bw;
    ctx.save();
    ctx.beginPath();
    ctx.arc(bx + r, by + r, r, Math.PI / 2, Math.PI * 1.5);
    ctx.lineTo(bx + bw - r, by);
    ctx.arc(bx + bw - r, by + r, r, -Math.PI / 2, Math.PI / 2);
    ctx.closePath();
    ctx.clip();
    ctx.fillStyle = 'rgba(12,12,16,0.82)';
    ctx.fillRect(coverX, by, bx + bw - coverX, bh);
    ctx.restore();
  }

  private meterHoldLine(bx: number, by: number, bw: number, bh: number, holdDb: number, dim: boolean): void {
    const ctx = this.context;
    const x = bx + this.meterPos(holdDb) * bw;
    if (x <= bx + 1) {
      return;
    }
    if (!dim) {
      ctx.shadowColor = 'rgba(255,255,255,0.55)';
      ctx.shadowBlur = 4;
      ctx.fillStyle = '#FFFFFF';
    } else {
      ctx.fillStyle = 'rgba(255,255,255,0.45)';
    }
    ctx.fillRect(x - 1, by, 2, bh);
    ctx.shadowBlur = 0;
    ctx.shadowColor = 'rgba(0,0,0,0)';
  }

  private meterTpLine(bx: number, by: number, bw: number, bh: number, tpDb: number): void {
    const ctx = this.context;
    const x = bx + this.meterPos(tpDb) * bw;
    if (x <= bx + 1) {
      return;
    }
    ctx.shadowColor = 'rgba(100,210,255,0.6)';
    ctx.shadowBlur = 5;
    ctx.fillStyle = '#64D2FF';
    ctx.fillRect(x - 1.25, by - 4, 2.5, bh + 8);
    ctx.shadowBlur = 0;
    ctx.shadowColor = 'rgba(0,0,0,0)';
  }

  private meterScale(bx: number, by: number, bw: number, pre: boolean, fs: number = 9.5,
    col: string = '#8A8A95'): void {
    const ctx = this.context;
    const marks: number[] = [-60, -40, -20, -12, -6, -3, 0];
    ctx.font = `${fs}vp sans-serif`;
    ctx.fillStyle = col;
    for (let i = 0; i < marks.length; i++) {
      const db = marks[i];
      const t = this.meterPos(db);
      const x = bx + t * bw;
      if (i === 0) {
        ctx.textAlign = 'left';
      } else if (i === marks.length - 1) {
        ctx.textAlign = 'right';
      } else {
        ctx.textAlign = 'center';
      }
      if (pre && i === 0) {
        continue;
      }
      ctx.fillText(`${db}`, x, by);
    }
    ctx.textAlign = 'left';
  }

  private drawMeterCompact(viz: AudioVizManager, w: number, h: number): void {
    const ctx = this.context;
    const bh = 14;
    const by = Math.floor((h - bh) / 2);
    if (by < 2 || w < 40) {
      return;
    }
    this.meterTrack(0, by, w, bh, false);
    this.meterCover(0, by, w, bh, viz.getRmsDb(true));
    this.meterHoldLine(0, by, w, bh, viz.getPeakDb(true), false);
  }

  private drawMeter(viz: AudioVizManager, w: number, h: number, scale: number, pageMode: boolean): void {
    const ctx = this.context;
    ctx.clearRect(0, 0, w, h);
    if (!pageMode) {
      this.drawMeterCompact(viz, w, h);
      return;
    }
    const labelW = 64;
    const gap = 10;
    const barH = 28;
    const rowGap = 22;
    const bx = labelW + gap;
    const bw = w - bx;
    if (bw < 80) {
      return;
    }
    const contentH = 26 + barH + rowGap + barH + 8 + 14 + 12 + 10;
    let y0 = Math.floor((h - contentH) / 2);
    if (y0 < 0) {
      y0 = 0;
    }
    ctx.textAlign = 'left';
    const preY = y0 + 26;
    const postY = preY + barH + rowGap;
    ctx.font = '600 11vp sans-serif';
    ctx.fillStyle = '#E6E6E6';
    ctx.fillText('PRE', 0, preY + 12);
    ctx.fillText('POST', 0, postY + 12);
    ctx.font = '11vp sans-serif';
    ctx.fillStyle = '#8A8A95';
    ctx.fillText('降噪前', 0, preY + 26);
    ctx.fillText('处理后', 0, postY + 26);
    this.meterTrack(bx, preY, bw, barH, true);
    this.meterCover(bx, preY, bw, barH, viz.getRmsDb(false));
    this.meterHoldLine(bx, preY, bw, barH, viz.getPeakDb(false), true);
    this.meterTrack(bx, postY, bw, barH, false);
    this.meterCover(bx, postY, bw, barH, viz.getRmsDb(true));
    this.meterHoldLine(bx, postY, bw, barH, viz.getPeakDb(true), false);
    this.meterTpLine(bx, postY, bw, barH, viz.getTruePeakDb(true));
    this.meterScale(bx, postY + barH + 8 + 9.5, bw, false);
    const legendY = postY + barH + 8 + 14 + 12;
    const items: string[] = ['RMS', '峰值保持', 'True Peak'];
    ctx.font = '10vp sans-serif';
    ctx.fillStyle = '#8A8A95';
    const widths: number[] = [8 + 4 + ctx.measureText(items[0]).width,
      2.5 + 4 + ctx.measureText(items[1]).width, 2.5 + 4 + ctx.measureText(items[2]).width];
    const totalW = widths[0] + 12 + widths[1] + 12 + widths[2];
    let lx = (w - totalW) / 2;
    const grad = ctx.createLinearGradient(lx, 0, lx + 8, 0);
    grad.addColorStop(0, '#34C759');
    grad.addColorStop(1, '#FFB800');
    ctx.fillStyle = grad;
    ctx.fillRect(lx, legendY, 8, 8);
    ctx.fillStyle = '#8A8A95';
    ctx.fillText(items[0], lx + 12, legendY + 8);
    lx += widths[0] + 12;
    ctx.fillStyle = '#FFFFFF';
    ctx.fillRect(lx, legendY, 2.5, 8);
    ctx.fillStyle = '#8A8A95';
    ctx.fillText(items[1], lx + 6.5, legendY + 8);
    lx += widths[1] + 12;
    ctx.fillStyle = '#64D2FF';
    ctx.fillRect(lx, legendY, 2.5, 8);
    ctx.fillStyle = '#8A8A95';
    ctx.fillText(items[2], lx + 6.5, legendY + 8);
    ctx.textAlign = 'left';
  }

  // 说明: Live 卡片底部电平条（Round Z 语义）——胶囊暗底轨全宽 rgba(12,12,16,0.82)，
  // 三段色带（绿 0-66.7% / 黄 66.7-90% / 红 90-100%）仅填充至 RMS 位置（动态变宽），
  // 白色 2px 发光峰值保持线，下方 dB 刻度行。
  drawLiveStrip(viz: AudioVizManager, w: number, h: number): void {
    const ctx = this.context;
    if (w < 40 || h < VIZ_CARD_STRIP_H + 10) {
      return;
    }
    const top = h - VIZ_CARD_STRIP_H;
    ctx.clearRect(0, top, w, VIZ_CARD_STRIP_H);
    const barH = 10;
    const by = top;
    const fillX = this.meterPos(viz.getRmsDb(true)) * w;
    const g1 = w * (40 / 60);
    const g2 = w * (54 / 60);
    ctx.save();
    this.capsulePath(0, by, w, barH);
    ctx.clip();
    ctx.fillStyle = 'rgba(12,12,16,0.82)';
    ctx.fillRect(0, by, w, barH);
    if (fillX > 0) {
      ctx.fillStyle = '#34C759';
      ctx.fillRect(0, by, Math.min(fillX, g1), barH);
      if (fillX > g1) {
        ctx.fillStyle = '#FFB800';
        ctx.fillRect(g1, by, Math.min(fillX, g2) - g1, barH);
      }
      if (fillX > g2) {
        ctx.fillStyle = '#FF6A6A';
        ctx.fillRect(g2, by, fillX - g2, barH);
      }
    }
    ctx.restore();
    this.meterHoldLine(0, by, w, barH, viz.getPeakDb(true), false);
    this.meterScale(0, by + barH + 3 + 7.5, w, false, 7.5, 'rgba(255,255,255,0.38)');
  }
}

export const VIZ_CARD_STRIP_H = 25;
