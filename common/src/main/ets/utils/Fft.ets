export class Fft {
  private fftSize: number;
  private revTable: Uint32Array;
  private cosTable: Float32Array;
  private sinTable: Float32Array;
  private hannWin: Float32Array;
  private reBuf: Float32Array;
  private imBuf: Float32Array;
  private windowGain: number;

  constructor(fftSize: number) {
    let size = fftSize;
    let bits = 0;
    let v = size;
    while (v > 1) {
      v = v >> 1;
      bits++;
    }
    if (size < 2 || (1 << bits) !== size) {
      size = 1024;
      bits = 10;
    }
    this.fftSize = size;
    this.revTable = new Uint32Array(size);
    for (let i = 0; i < size; i++) {
      let r = 0;
      let x = i;
      for (let b = 0; b < bits; b++) {
        r = (r << 1) | (x & 1);
        x = x >> 1;
      }
      this.revTable[i] = r;
    }
    const half = size >> 1;
    this.cosTable = new Float32Array(half);
    this.sinTable = new Float32Array(half);
    for (let i = 0; i < half; i++) {
      this.cosTable[i] = Math.cos(-2 * Math.PI * i / size);
      this.sinTable[i] = Math.sin(-2 * Math.PI * i / size);
    }
    this.hannWin = new Float32Array(size);
    let winSum = 0;
    for (let i = 0; i < size; i++) {
      const wv = 0.5 * (1 - Math.cos(2 * Math.PI * i / (size - 1)));
      this.hannWin[i] = wv;
      winSum += wv;
    }
    this.windowGain = winSum / size;
    this.reBuf = new Float32Array(size);
    this.imBuf = new Float32Array(size);
  }

  analyze(samples: Float32Array, magDb: Float32Array): void {
    const n = this.fftSize;
    const re = this.reBuf;
    const im = this.imBuf;
    for (let i = 0; i < n; i++) {
      re[i] = samples[i] * this.hannWin[i];
      im[i] = 0;
    }
    for (let i = 0; i < n; i++) {
      const j = this.revTable[i];
      if (j > i) {
        const tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        const ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (let len = 2; len <= n; len = len << 1) {
      const halfLen = len >> 1;
      const step = n / len;
      for (let i = 0; i < n; i += len) {
        for (let j = 0; j < halfLen; j++) {
          const c = this.cosTable[j * step];
          const s = this.sinTable[j * step];
          const ie = i + j;
          const io = ie + halfLen;
          const tr = c * re[io] - s * im[io];
          const ti = s * re[io] + c * im[io];
          re[io] = re[ie] - tr;
          im[io] = im[ie] - ti;
          re[ie] = re[ie] + tr;
          im[ie] = im[ie] + ti;
        }
      }
    }
    const halfOut = n >> 1;
    const norm = 2 / (n * this.windowGain);
    for (let k = 0; k < halfOut; k++) {
      const mag = Math.sqrt(re[k] * re[k] + im[k] * im[k]) * norm;
      let db = -160;
      if (mag > 1e-9) {
        db = 20 * Math.log10(mag);
        if (db < -160) {
          db = -160;
        }
      }
      magDb[k] = db;
    }
  }
}
