import { Fft } from '../utils/Fft';

const VIZ_FFT_SIZE = 1024;
const VIZ_RING_SAMPLES = 48000;
export const VIZ_COLS = 360;
export const VIZ_BANDS = 96;
const VIZ_BAR_BANDS = 48;
export const VIZ_MIN_FREQ = 50;
const VIZ_MAX_FREQ = 16000;
const VIZ_DB_FLOOR = -90;
const VIZ_DB_RANGE = 90;
const PEAK_HOLD_MS = 1500;
const PEAK_DECAY_DB_PER_S = 6;
const CLIP_THRESHOLD_DB = -0.1;
const DB_FLOOR_INF = -160;

export enum MeterMode {
  PEAK = 0,
  LUFS = 1
}

function ampToDb(v: number): number {
  if (v <= 1e-9) {
    return -160;
  }
  return 20 * Math.log10(v);
}

function readSample24(dv: DataView, offset: number): number {
  let raw = dv.getUint8(offset) | (dv.getUint8(offset + 1) << 8) | (dv.getUint8(offset + 2) << 16);
  if (raw >= 0x800000) {
    raw -= 0x1000000;
  }
  return raw;
}

class VizChannel {
  samples: Float32Array = new Float32Array(VIZ_RING_SAMPLES);
  writePos: number = 0;
  filled: number = 0;
  rmsDb: number = -160;
  peakHoldDb: number = -160;
  peakHoldAtMs: number = 0;
  truePeakDb: number = -160;
  clipLatched: boolean = false;
  specHistory: Uint8Array = new Uint8Array(VIZ_COLS * VIZ_BANDS);
  historyCol: number = 0;
  barDb: Float32Array = new Float32Array(VIZ_BAR_BANDS);

  constructor() {
    this.barDb.fill(-160);
  }

  reset(): void {
    this.writePos = 0;
    this.filled = 0;
    this.rmsDb = -160;
    this.peakHoldDb = -160;
    this.peakHoldAtMs = 0;
    this.truePeakDb = -160;
    this.clipLatched = false;
    this.specHistory.fill(0);
    this.historyCol = 0;
    this.barDb.fill(-160);
  }
}

export class AudioVizManager {
  private pre: VizChannel = new VizChannel();
  private post: VizChannel = new VizChannel();
  private fft: Fft = new Fft(VIZ_FFT_SIZE);
  private sampleRate: number = 48000;
  private maxFreq: number = VIZ_MAX_FREQ;
  private specBandEdges: Int32Array = new Int32Array(VIZ_BANDS + 1);
  private barBandEdges: Int32Array = new Int32Array(VIZ_BAR_BANDS + 1);
  private magDb: Float32Array = new Float32Array(VIZ_FFT_SIZE / 2);
  private fftIn: Float32Array = new Float32Array(VIZ_FFT_SIZE);
  private waveMin: Float32Array = new Float32Array(400);
  private waveMax: Float32Array = new Float32Array(400);
  private wavePixels: number = 0;

  constructor() {
    this.rebuildBands();
  }

  feedPre(buffer: ArrayBuffer, sampleRate: number, sampleBits: number, channels: number): void {
    this.feedChannel(this.pre, buffer, sampleRate, sampleBits, channels);
  }

  feedPost(buffer: ArrayBuffer, sampleRate: number, sampleBits: number, channels: number): void {
    this.feedChannel(this.post, buffer, sampleRate, sampleBits, channels);
  }

  reset(): void {
    this.pre.reset();
    this.post.reset();
  }

  getMaxFreq(): number {
    return this.maxFreq;
  }

  getRmsDb(post: boolean): number {
    return post ? this.post.rmsDb : this.pre.rmsDb;
  }

  getPeakDb(post: boolean): number {
    return this.peakHoldValue(post ? this.post : this.pre, Date.now());
  }

  getTruePeakDb(post: boolean): number {
    return post ? this.post.truePeakDb : this.pre.truePeakDb;
  }

  isClipping(post: boolean): boolean {
    return post ? this.post.clipLatched : this.pre.clipLatched;
  }

  resetMeterLatch(): void {
    this.pre.peakHoldDb = DB_FLOOR_INF;
    this.pre.peakHoldAtMs = 0;
    this.pre.clipLatched = false;
    this.post.peakHoldDb = DB_FLOOR_INF;
    this.post.peakHoldAtMs = 0;
    this.post.clipLatched = false;
  }

  clearClipLatch(): void {
    this.post.clipLatched = false;
  }

  getBarDb(post: boolean): Float32Array {
    return post ? this.post.barDb : this.pre.barDb;
  }

  getSpecHistory(post: boolean): Uint8Array {
    return post ? this.post.specHistory : this.pre.specHistory;
  }

  getHistoryHead(post: boolean): number {
    return post ? this.post.historyCol : this.pre.historyCol;
  }

  getWaveform(post: boolean, pixels: number): void {
    const ch = post ? this.post : this.pre;
    const cap = ch.samples.length;
    let n = pixels;
    if (n > this.waveMin.length) {
      n = this.waveMin.length;
    }
    if (n < 1) {
      n = 0;
    }
    this.wavePixels = n;
    if (n === 0 || ch.filled === 0) {
      for (let i = 0; i < n; i++) {
        this.waveMin[i] = 0;
        this.waveMax[i] = 0;
      }
      return;
    }
    let windowLen = Math.round(this.sampleRate * 0.25);
    if (windowLen > ch.filled) {
      windowLen = ch.filled;
    }
    if (windowLen < 1) {
      windowLen = 1;
    }
    const step = windowLen / n;
    let start = ch.writePos - windowLen;
    if (start < 0) {
      start += cap;
    }
    for (let px = 0; px < n; px++) {
      const from = Math.floor(px * step);
      let to = Math.floor((px + 1) * step);
      if (to <= from) {
        to = from + 1;
      }
      let mn = 1;
      let mx = -1;
      let idx = (start + from) % cap;
      for (let s = from; s < to; s++) {
        const v = ch.samples[idx];
        if (v < mn) {
          mn = v;
        }
        if (v > mx) {
          mx = v;
        }
        idx++;
        if (idx >= cap) {
          idx = 0;
        }
      }
      if (mn > mx) {
        mn = 0;
        mx = 0;
      }
      this.waveMin[px] = mn;
      this.waveMax[px] = mx;
    }
  }

  getWavePixels(): number {
    return this.wavePixels;
  }

  getWaveMin(): Float32Array {
    return this.waveMin;
  }

  getWaveMax(): Float32Array {
    return this.waveMax;
  }

  tick(): void {
    this.tickChannel(this.pre);
    this.tickChannel(this.post);
  }

  private feedChannel(ch: VizChannel, buffer: ArrayBuffer, sampleRate: number, sampleBits: number,
    channels: number): void {
    if (sampleRate !== this.sampleRate) {
      this.sampleRate = sampleRate;
      this.rebuildBands();
    }
    if (channels < 1 || (sampleBits !== 16 && sampleBits !== 24 && sampleBits !== 32)) {
      return;
    }
    const bytesPerFrame = (sampleBits / 8) * channels;
    const frameCount = Math.floor(buffer.byteLength / bytesPerFrame);
    if (frameCount === 0) {
      return;
    }
    const cap = ch.samples.length;
    let wp = ch.writePos;
    let sumSq = 0;
    let peakAbs = 0;
    if (sampleBits === 16) {
      const s16 = new Int16Array(buffer);
      for (let f = 0; f < frameCount; f++) {
        let v: number;
        if (channels === 2) {
          v = (s16[f * 2] + s16[f * 2 + 1]) * 0.5 / 32768;
        } else {
          v = s16[f] / 32768;
        }
        ch.samples[wp] = v;
        wp++;
        if (wp >= cap) {
          wp = 0;
        }
        sumSq += v * v;
        const a = v < 0 ? -v : v;
        if (a > peakAbs) {
          peakAbs = a;
        }
      }
    } else if (sampleBits === 24) {
      const dv = new DataView(buffer);
      const stride = 3 * channels;
      for (let f = 0; f < frameCount; f++) {
        const o = f * stride;
        let v: number;
        if (channels === 2) {
          const l = readSample24(dv, o);
          const r = readSample24(dv, o + 3);
          v = (l + r) * 0.5 / 8388608;
        } else {
          v = readSample24(dv, o) / 8388608;
        }
        ch.samples[wp] = v;
        wp++;
        if (wp >= cap) {
          wp = 0;
        }
        sumSq += v * v;
        const a = v < 0 ? -v : v;
        if (a > peakAbs) {
          peakAbs = a;
        }
      }
    } else {
      const s32 = new Int32Array(buffer);
      for (let f = 0; f < frameCount; f++) {
        let v: number;
        if (channels === 2) {
          v = (s32[f * 2] + s32[f * 2 + 1]) * 0.5 / 2147483648;
        } else {
          v = s32[f] / 2147483648;
        }
        ch.samples[wp] = v;
        wp++;
        if (wp >= cap) {
          wp = 0;
        }
        sumSq += v * v;
        const a = v < 0 ? -v : v;
        if (a > peakAbs) {
          peakAbs = a;
        }
      }
    }
    ch.writePos = wp;
    if (ch.filled < cap) {
      const nf = ch.filled + frameCount;
      ch.filled = nf < cap ? nf : cap;
    }
    const chunkRms = Math.sqrt(sumSq / frameCount);
    const chunkRmsDb = ampToDb(chunkRms);
    if (chunkRmsDb > ch.rmsDb) {
      ch.rmsDb = chunkRmsDb;
    } else {
      ch.rmsDb += (chunkRmsDb - ch.rmsDb) * 0.3;
    }
    const now = Date.now();
    const chunkPeakDb = ampToDb(peakAbs);
    if (chunkPeakDb > this.peakHoldValue(ch, now)) {
      ch.peakHoldDb = chunkPeakDb;
      ch.peakHoldAtMs = now;
    }
    this.computeTruePeak(ch, frameCount);
  }

  private peakHoldValue(ch: VizChannel, now: number): number {
    if (ch.peakHoldDb <= DB_FLOOR_INF) {
      return DB_FLOOR_INF;
    }
    const heldMs = now - ch.peakHoldAtMs;
    if (heldMs <= PEAK_HOLD_MS) {
      return ch.peakHoldDb;
    }
    const v = ch.peakHoldDb - (heldMs - PEAK_HOLD_MS) / 1000 * PEAK_DECAY_DB_PER_S;
    return v < DB_FLOOR_INF ? DB_FLOOR_INF : v;
  }

  private computeTruePeak(ch: VizChannel, frameCount: number): void {
    const cap = ch.samples.length;
    const n = ch.filled < frameCount + 2 ? ch.filled : frameCount + 2;
    if (n < 4) {
      ch.truePeakDb = DB_FLOOR_INF;
      return;
    }
    const start = ch.writePos - n;
    let tp = 0;
    for (let k = 1; k <= n - 2; k++) {
      const i0 = this.ringIndex(start + k - 1, cap);
      const i1 = this.ringIndex(start + k, cap);
      const i2 = this.ringIndex(start + k + 1, cap);
      const i3 = this.ringIndex(start + k + 2, cap);
      const p0 = ch.samples[i0];
      const p1 = ch.samples[i1];
      const p2 = ch.samples[i2];
      const p3 = k + 2 <= n - 1 ? ch.samples[i3] : p2;
      const c1 = 0.5 * (p2 - p0);
      const c2 = 0.5 * (2 * p0 - 5 * p1 + 4 * p2 - p3);
      const c3 = 0.5 * (3 * p1 - p0 - 3 * p2 + p3);
      const y1 = ((c3 * 0.25 + c2) * 0.25 + c1) * 0.25 + p1;
      const y2 = ((c3 * 0.5 + c2) * 0.5 + c1) * 0.5 + p1;
      const y3 = ((c3 * 0.75 + c2) * 0.75 + c1) * 0.75 + p1;
      let a = y1 < 0 ? -y1 : y1;
      if (a > tp) {
        tp = a;
      }
      a = y2 < 0 ? -y2 : y2;
      if (a > tp) {
        tp = a;
      }
      a = y3 < 0 ? -y3 : y3;
      if (a > tp) {
        tp = a;
      }
    }
    ch.truePeakDb = ampToDb(tp);
    if (ch.truePeakDb >= CLIP_THRESHOLD_DB) {
      ch.clipLatched = true;
    }
  }

  private ringIndex(idx: number, cap: number): number {
    let v = idx % cap;
    if (v < 0) {
      v += cap;
    }
    return v;
  }

  private tickChannel(ch: VizChannel): void {
    if (ch.filled === 0) {
      ch.barDb.fill(-160);
      return;
    }
    const cap = ch.samples.length;
    const avail = Math.min(ch.filled, VIZ_FFT_SIZE);
    const zeros = VIZ_FFT_SIZE - avail;
    for (let i = 0; i < zeros; i++) {
      this.fftIn[i] = 0;
    }
    let start = ch.writePos - avail;
    if (start < 0) {
      start += cap;
    }
    for (let i = 0; i < avail; i++) {
      this.fftIn[zeros + i] = ch.samples[start];
      start++;
      if (start >= cap) {
        start = 0;
      }
    }
    this.fft.analyze(this.fftIn, this.magDb);
    const binCount = this.magDb.length;
    for (let i = 0; i < VIZ_BAR_BANDS; i++) {
      let m = -160;
      const s = this.barBandEdges[i];
      const e = this.barBandEdges[i + 1];
      const hi = e < binCount ? e : binCount;
      for (let k = s; k < hi; k++) {
        if (this.magDb[k] > m) {
          m = this.magDb[k];
        }
      }
      ch.barDb[i] = m;
    }
    const col = ch.historyCol;
    const base = col * VIZ_BANDS;
    for (let b = 0; b < VIZ_BANDS; b++) {
      let m = -160;
      const s = this.specBandEdges[b];
      const e = this.specBandEdges[b + 1];
      const hi = e < binCount ? e : binCount;
      for (let k = s; k < hi; k++) {
        if (this.magDb[k] > m) {
          m = this.magDb[k];
        }
      }
      let v = (m - VIZ_DB_FLOOR) / VIZ_DB_RANGE * 255;
      if (v < 0) {
        v = 0;
      }
      if (v > 255) {
        v = 255;
      }
      ch.specHistory[base + b] = Math.round(v);
    }
    ch.historyCol = (col + 1) % VIZ_COLS;
  }

  private rebuildBands(): void {
    const halfBins = VIZ_FFT_SIZE / 2;
    const nyq = this.sampleRate / 2;
    let maxF = VIZ_MAX_FREQ;
    if (maxF > nyq - 100) {
      maxF = nyq - 100;
    }
    if (maxF < VIZ_MIN_FREQ * 2) {
      maxF = VIZ_MIN_FREQ * 2;
    }
    this.maxFreq = maxF;
    this.buildEdges(this.specBandEdges, maxF, halfBins);
    this.buildEdges(this.barBandEdges, maxF, halfBins);
    this.pre.specHistory.fill(0);
    this.post.specHistory.fill(0);
    this.pre.historyCol = 0;
    this.post.historyCol = 0;
  }

  private buildEdges(edges: Int32Array, maxFreq: number, halfBins: number): void {
    const binHz = this.sampleRate / VIZ_FFT_SIZE;
    const count = edges.length;
    let prev = 0;
    for (let i = 0; i < count; i++) {
      const t = i / (count - 1);
      const f = VIZ_MIN_FREQ * Math.pow(maxFreq / VIZ_MIN_FREQ, t);
      let e = Math.round(f / binHz);
      if (e <= prev) {
        e = prev + 1;
      }
      if (e > halfBins) {
        e = halfBins;
      }
      edges[i] = e;
      prev = e;
    }
  }
}
