const LIMITER_THRESHOLD_DB = -0.1;
const FS_16 = 32767;
const FS_24 = 8388607;
const FS_32 = 2147483647;

export interface IAudioStage {
  process(buffer: ArrayBuffer, sampleRate: number, sampleBits: number, channels: number): ArrayBuffer;
}

export type SampleTransform = (v: number) => number;

export function transformSamples(buffer: ArrayBuffer, sampleBits: number, transform: SampleTransform): void {
  if (buffer.byteLength === 0) {
    return;
  }
  if (sampleBits === 16) {
    const view = new Int16Array(buffer);
    for (let i = 0; i < view.length; i++) {
      const out = transform(view[i] / FS_16);
      let o = Math.round(out * FS_16);
      if (o > FS_16) {
        o = FS_16;
      } else if (o < -32768) {
        o = -32768;
      }
      view[i] = o;
    }
    return;
  }
  if (sampleBits === 32) {
    const view = new Int32Array(buffer);
    for (let i = 0; i < view.length; i++) {
      const out = transform(view[i] / FS_32);
      let o = Math.round(out * FS_32);
      if (o > FS_32) {
        o = FS_32;
      } else if (o < -2147483648) {
        o = -2147483648;
      }
      view[i] = o;
    }
    return;
  }
  const dv = new DataView(buffer);
  const count = Math.floor(buffer.byteLength / 3);
  for (let i = 0; i < count; i++) {
    const off = i * 3;
    let raw = dv.getUint8(off) | (dv.getUint8(off + 1) << 8) | (dv.getUint8(off + 2) << 16);
    if (raw >= 8388608) {
      raw -= 16777216;
    }
    const out = transform(raw / FS_24);
    let o = Math.round(out * FS_24);
    if (o > FS_24) {
      o = FS_24;
    } else if (o < -8388608) {
      o = -8388608;
    }
    if (o < 0) {
      o += 16777216;
    }
    dv.setUint8(off, o & 0xFF);
    dv.setUint8(off + 1, (o >> 8) & 0xFF);
    dv.setUint8(off + 2, (o >> 16) & 0xFF);
  }
}

export class GainStage implements IAudioStage {
  private gainDb: number = 0;
  private factor: number = 1;

  setGainDb(gainDb: number): void {
    this.gainDb = gainDb;
    this.factor = Math.pow(10, gainDb / 20);
  }

  getGainDb(): number {
    return this.gainDb;
  }

  process(buffer: ArrayBuffer, sampleRate: number, sampleBits: number, channels: number): ArrayBuffer {
    if (this.gainDb === 0 || this.factor === 1) {
      return buffer;
    }
    const factor = this.factor;
    transformSamples(buffer, sampleBits, (v: number): number => v * factor);
    return buffer;
  }
}

export class LimiterStage implements IAudioStage {
  private enabled: boolean = true;
  private threshold: number = Math.pow(10, LIMITER_THRESHOLD_DB / 20);

  setEnabled(enabled: boolean): void {
    this.enabled = enabled;
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  process(buffer: ArrayBuffer, sampleRate: number, sampleBits: number, channels: number): ArrayBuffer {
    if (!this.enabled) {
      return buffer;
    }
    const th = this.threshold;
    transformSamples(buffer, sampleBits, (v: number): number => {
      if (v > th) {
        return th;
      }
      if (v < -th) {
        return -th;
      }
      return v;
    });
    return buffer;
  }
}

export class BiquadFilter implements IAudioStage {
  private b0: number = 1;
  private b1: number = 0;
  private b2: number = 0;
  private a1: number = 0;
  private a2: number = 0;
  private z1: number[] = [0, 0];
  private z2: number[] = [0, 0];

  setCoefficients(b0: number, b1: number, b2: number, a1: number, a2: number): void {
    this.b0 = b0;
    this.b1 = b1;
    this.b2 = b2;
    this.a1 = a1;
    this.a2 = a2;
    this.reset();
  }

  reset(): void {
    this.z1 = [0, 0];
    this.z2 = [0, 0];
  }

  process(buffer: ArrayBuffer, sampleRate: number, sampleBits: number, channels: number): ArrayBuffer {
    if (this.b0 === 1 && this.b1 === 0 && this.b2 === 0 && this.a1 === 0 && this.a2 === 0) {
      return buffer;
    }
    const ch = channels >= 2 ? 2 : 1;
    if (sampleBits === 16) {
      const view = new Int16Array(buffer);
      for (let i = 0; i < view.length; i++) {
        const c = i % ch;
        const x = view[i] / FS_16;
        const y = this.b0 * x + this.z1[c];
        this.z1[c] = this.b1 * x - this.a1 * y + this.z2[c];
        this.z2[c] = this.b2 * x - this.a2 * y;
        let o = Math.round(y * FS_16);
        if (o > FS_16) {
          o = FS_16;
        } else if (o < -32768) {
          o = -32768;
        }
        view[i] = o;
      }
      return buffer;
    }
    if (sampleBits === 32) {
      const view = new Int32Array(buffer);
      for (let i = 0; i < view.length; i++) {
        const c = i % ch;
        const x = view[i] / FS_32;
        const y = this.b0 * x + this.z1[c];
        this.z1[c] = this.b1 * x - this.a1 * y + this.z2[c];
        this.z2[c] = this.b2 * x - this.a2 * y;
        let o = Math.round(y * FS_32);
        if (o > FS_32) {
          o = FS_32;
        } else if (o < -2147483648) {
          o = -2147483648;
        }
        view[i] = o;
      }
      return buffer;
    }
    const dv = new DataView(buffer);
    const count = Math.floor(buffer.byteLength / 3);
    for (let i = 0; i < count; i++) {
      const c = i % ch;
      const off = i * 3;
      let raw = dv.getUint8(off) | (dv.getUint8(off + 1) << 8) | (dv.getUint8(off + 2) << 16);
      if (raw >= 8388608) {
        raw -= 16777216;
      }
      const x = raw / FS_24;
      const y = this.b0 * x + this.z1[c];
      this.z1[c] = this.b1 * x - this.a1 * y + this.z2[c];
      this.z2[c] = this.b2 * x - this.a2 * y;
      let o = Math.round(y * FS_24);
      if (o > FS_24) {
        o = FS_24;
      } else if (o < -8388608) {
        o = -8388608;
      }
      if (o < 0) {
        o += 16777216;
      }
      dv.setUint8(off, o & 0xFF);
      dv.setUint8(off + 1, (o >> 8) & 0xFF);
      dv.setUint8(off + 2, (o >> 16) & 0xFF);
    }
    return buffer;
  }
}

export class AudioPipeline {
  private stages: IAudioStage[] = [];

  addStage(stage: IAudioStage): void {
    this.stages.push(stage);
  }

  process(buffer: ArrayBuffer, sampleRate: number, sampleBits: number, channels: number): ArrayBuffer {
    let cur = buffer;
    for (let i = 0; i < this.stages.length; i++) {
      if (cur.byteLength === 0) {
        return cur;
      }
      cur = this.stages[i].process(cur, sampleRate, sampleBits, channels);
    }
    return cur;
  }
}
