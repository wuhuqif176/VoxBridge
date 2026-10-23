import { BiquadFilter, IAudioStage } from './AudioPipeline';

export enum EqBandType {
  LOW_SHELF = 0,
  PEAKING = 1,
  HIGH_SHELF = 2
}

export interface EqBandParams {
  type: EqBandType;
  freqHz: number;
  gainDb: number;
  q: number;
}

// 说明: EQ 固定 8 段（S4-RoundZG 由 5 段扩展）：新增 180/550/1800 Hz 峰值段，
// 原 100/300/1k/3k/8k 锚点全部保留，旧 5 段持久化设置可按频率 1:1 迁移。
export const EQ_BAND_COUNT = 8;

export class EqPresets {
  static readonly FLAT: string = 'flat';
  static readonly VOICE: string = 'voice';
  static readonly LOW_CUT: string = 'lowcut';
  static readonly BRIGHT: string = 'bright';
  static readonly CUSTOM: string = 'custom';

  static presetNames(): string[] {
    return [EqPresets.FLAT, EqPresets.VOICE, EqPresets.LOW_CUT, EqPresets.BRIGHT];
  }

  static defaultBands(): EqBandParams[] {
    return [
      { type: EqBandType.LOW_SHELF, freqHz: 100, gainDb: 0, q: 0.707 },
      { type: EqBandType.PEAKING, freqHz: 180, gainDb: 0, q: 0.90 },
      { type: EqBandType.PEAKING, freqHz: 300, gainDb: 0, q: 0.90 },
      { type: EqBandType.PEAKING, freqHz: 550, gainDb: 0, q: 0.90 },
      { type: EqBandType.PEAKING, freqHz: 1000, gainDb: 0, q: 0.90 },
      { type: EqBandType.PEAKING, freqHz: 1800, gainDb: 0, q: 0.90 },
      { type: EqBandType.PEAKING, freqHz: 3000, gainDb: 0, q: 0.90 },
      { type: EqBandType.HIGH_SHELF, freqHz: 8000, gainDb: 0, q: 0.707 }
    ];
  }

  static presetBands(name: string): EqBandParams[] {
    if (name === EqPresets.VOICE) {
      return [
        { type: EqBandType.LOW_SHELF, freqHz: 100, gainDb: -2.0, q: 0.707 },
        { type: EqBandType.PEAKING, freqHz: 180, gainDb: -2.0, q: 0.90 },
        { type: EqBandType.PEAKING, freqHz: 300, gainDb: -2.0, q: 0.90 },
        { type: EqBandType.PEAKING, freqHz: 550, gainDb: -0.5, q: 0.90 },
        { type: EqBandType.PEAKING, freqHz: 1000, gainDb: 1.5, q: 0.80 },
        { type: EqBandType.PEAKING, freqHz: 1800, gainDb: 3.0, q: 0.90 },
        { type: EqBandType.PEAKING, freqHz: 3000, gainDb: 4.0, q: 0.70 },
        { type: EqBandType.HIGH_SHELF, freqHz: 8000, gainDb: 2.0, q: 0.707 }
      ];
    }
    if (name === EqPresets.LOW_CUT) {
      return [
        { type: EqBandType.LOW_SHELF, freqHz: 100, gainDb: -8.0, q: 0.707 },
        { type: EqBandType.PEAKING, freqHz: 180, gainDb: -4.0, q: 0.90 },
        { type: EqBandType.PEAKING, freqHz: 300, gainDb: -2.0, q: 0.90 },
        { type: EqBandType.PEAKING, freqHz: 550, gainDb: 0, q: 0.90 },
        { type: EqBandType.PEAKING, freqHz: 1000, gainDb: 0, q: 0.90 },
        { type: EqBandType.PEAKING, freqHz: 1800, gainDb: 0, q: 0.90 },
        { type: EqBandType.PEAKING, freqHz: 3000, gainDb: 0, q: 0.90 },
        { type: EqBandType.HIGH_SHELF, freqHz: 8000, gainDb: 0, q: 0.707 }
      ];
    }
    if (name === EqPresets.BRIGHT) {
      return [
        { type: EqBandType.LOW_SHELF, freqHz: 100, gainDb: 0, q: 0.707 },
        { type: EqBandType.PEAKING, freqHz: 180, gainDb: 0, q: 0.90 },
        { type: EqBandType.PEAKING, freqHz: 300, gainDb: 0, q: 0.90 },
        { type: EqBandType.PEAKING, freqHz: 550, gainDb: 0.5, q: 0.90 },
        { type: EqBandType.PEAKING, freqHz: 1000, gainDb: 1.0, q: 0.80 },
        { type: EqBandType.PEAKING, freqHz: 1800, gainDb: 2.0, q: 0.90 },
        { type: EqBandType.PEAKING, freqHz: 3000, gainDb: 3.0, q: 1.20 },
        { type: EqBandType.HIGH_SHELF, freqHz: 8000, gainDb: 5.0, q: 0.707 }
      ];
    }
    return EqPresets.defaultBands();
  }
}

export class EqStage implements IAudioStage {
  private static readonly MAX_GAIN_DB = 12;
  private static readonly MIN_Q = 0.5;
  private static readonly MAX_Q = 4;

  private filters: BiquadFilter[] = [
    new BiquadFilter(), new BiquadFilter(), new BiquadFilter(), new BiquadFilter(),
    new BiquadFilter(), new BiquadFilter(), new BiquadFilter(), new BiquadFilter()
  ];
  private coeffs: number[][] = [];
  private bands: EqBandParams[] = EqPresets.defaultBands();
  private bypass: boolean = true;
  private allFlat: boolean = true;
  private sampleRate: number = 48000;

  private static clamp(v: number, lo: number, hi: number): number {
    if (v < lo) {
      return lo;
    }
    if (v > hi) {
      return hi;
    }
    return v;
  }

  private static computeCoefficients(band: EqBandParams, sampleRate: number): number[] {
    const maxFreq = Math.floor(sampleRate * 0.45);
    const f0 = EqStage.clamp(band.freqHz, 10, maxFreq);
    const gain = EqStage.clamp(band.gainDb, -EqStage.MAX_GAIN_DB, EqStage.MAX_GAIN_DB);
    const w0 = 2 * Math.PI * f0 / sampleRate;
    const cw = Math.cos(w0);
    const sw = Math.sin(w0);
    const A = Math.pow(10, gain / 40);
    if (band.type === EqBandType.PEAKING) {
      const q = EqStage.clamp(band.q, EqStage.MIN_Q, EqStage.MAX_Q);
      const alpha = sw / (2 * q);
      const a0 = 1 + alpha / A;
      return [
        (1 + alpha * A) / a0,
        (-2 * cw) / a0,
        (1 - alpha * A) / a0,
        (-2 * cw) / a0,
        (1 - alpha / A) / a0
      ];
    }
    const alpha = sw * Math.SQRT1_2;
    const sqA = 2 * Math.sqrt(A) * alpha;
    if (band.type === EqBandType.HIGH_SHELF) {
      const a0 = (A + 1) - (A - 1) * cw + sqA;
      return [
        (A * ((A + 1) + (A - 1) * cw + sqA)) / a0,
        (-2 * A * ((A - 1) + (A + 1) * cw)) / a0,
        (A * ((A + 1) + (A - 1) * cw - sqA)) / a0,
        (2 * ((A - 1) - (A + 1) * cw)) / a0,
        ((A + 1) - (A - 1) * cw - sqA) / a0
      ];
    }
    const a0 = (A + 1) + (A - 1) * cw + sqA;
    return [
      (A * ((A + 1) - (A - 1) * cw + sqA)) / a0,
      (2 * A * ((A - 1) - (A + 1) * cw)) / a0,
      (A * ((A + 1) - (A - 1) * cw - sqA)) / a0,
      (-2 * ((A - 1) + (A + 1) * cw)) / a0,
      ((A + 1) + (A - 1) * cw - sqA) / a0
    ];
  }

  setBypass(bypass: boolean): void {
    this.bypass = bypass;
  }

  isBypassed(): boolean {
    return this.bypass;
  }

  setBands(bands: EqBandParams[], sampleRate: number): void {
    const rate = sampleRate > 0 ? sampleRate : 48000;
    const next: EqBandParams[] = [];
    for (let i = 0; i < this.filters.length && i < bands.length; i++) {
      const src = bands[i];
      next.push({
        type: src.type,
        freqHz: src.freqHz,
        gainDb: EqStage.clamp(src.gainDb, -EqStage.MAX_GAIN_DB, EqStage.MAX_GAIN_DB),
        q: EqStage.clamp(src.q, EqStage.MIN_Q, EqStage.MAX_Q)
      });
    }
    while (next.length < this.filters.length) {
      next.push(EqPresets.defaultBands()[next.length]);
    }
    if (rate === this.sampleRate && next.length === this.bands.length && this.bandsMatch(next)) {
      return;
    }
    this.sampleRate = rate;
    this.bands = next;
    this.allFlat = true;
    this.coeffs = [];
    for (let i = 0; i < next.length; i++) {
      if (next[i].gainDb !== 0) {
        this.allFlat = false;
      }
      const c = EqStage.computeCoefficients(next[i], this.sampleRate);
      this.coeffs.push(c);
      this.filters[i].setCoefficients(c[0], c[1], c[2], c[3], c[4]);
    }
  }

  private bandsMatch(other: EqBandParams[]): boolean {
    for (let i = 0; i < other.length; i++) {
      if (this.bands[i].type !== other[i].type || this.bands[i].freqHz !== other[i].freqHz
        || this.bands[i].gainDb !== other[i].gainDb || this.bands[i].q !== other[i].q) {
        return false;
      }
    }
    return true;
  }

  getBands(): EqBandParams[] {
    const out: EqBandParams[] = [];
    for (let i = 0; i < this.bands.length; i++) {
      const b = this.bands[i];
      out.push({ type: b.type, freqHz: b.freqHz, gainDb: b.gainDb, q: b.q });
    }
    return out;
  }

  getSampleRate(): number {
    return this.sampleRate;
  }

  magnitudeDbAt(freqHz: number): number {
    const maxFreq = Math.floor(this.sampleRate * 0.45);
    const f = EqStage.clamp(freqHz, 1, maxFreq);
    const w = 2 * Math.PI * f / this.sampleRate;
    const c1 = Math.cos(w);
    const s1 = Math.sin(w);
    const c2 = Math.cos(2 * w);
    const s2 = Math.sin(2 * w);
    let total = 1;
    for (let i = 0; i < this.coeffs.length; i++) {
      const c = this.coeffs[i];
      const numRe = c[0] + c[1] * c1 + c[2] * c2;
      const numIm = -(c[1] * s1 + c[2] * s2);
      const denRe = 1 + c[3] * c1 + c[4] * c2;
      const denIm = -(c[3] * s1 + c[4] * s2);
      const numMag = Math.sqrt(numRe * numRe + numIm * numIm);
      const denMag = Math.sqrt(denRe * denRe + denIm * denIm);
      if (denMag > 0) {
        total *= numMag / denMag;
      }
    }
    return 20 * Math.log10(total);
  }

  process(buffer: ArrayBuffer, sampleRate: number, sampleBits: number, channels: number): ArrayBuffer {
    if (this.bypass || this.allFlat) {
      return buffer;
    }
    let cur = buffer;
    for (let i = 0; i < this.filters.length; i++) {
      cur = this.filters[i].process(cur, sampleRate, sampleBits, channels);
    }
    return cur;
  }
}
