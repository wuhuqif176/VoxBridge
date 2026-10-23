import { audio } from '@kit.AudioKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { MicLogger } from '../utils/Logger';

const NOISE_REDUCTION_API_LEVEL = 26;

export interface CaptureConfig {
  source: audio.SourceType;
  sampleRate: number;
  sampleBits: number;
  channels: number;
  noiseReductionChoice: number;
}

export class AudioCaptureManager {
  private capturer: audio.AudioCapturer | null = null;
  private config: CaptureConfig | null = null;
  private running: boolean = false;
  private nrModesCache: Map<number, audio.NoiseReductionMode[]> = new Map();
  public onAudioData: ((buffer: ArrayBuffer) => void) | null = null;
  public onCaptureStateChanged: ((running: boolean, detail: string) => void) | null = null;
  public onMicInterrupted: ((event: audio.InterruptEvent) => void) | null = null;

  isRunning(): boolean {
    return this.running;
  }

  getSamplingRate(): number {
    return this.config !== null ? this.config.sampleRate : 16000;
  }

  getChannelCount(): number {
    return this.config !== null ? this.config.channels : 1;
  }

  getSampleBits(): number {
    return this.config !== null ? this.config.sampleBits : 16;
  }

  getSourceName(source: audio.SourceType): string {
    if (source === audio.SourceType.SOURCE_TYPE_MIC) {
      return '原始MIC';
    }
    if (source === audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION) {
      return '语音识别';
    }
    if (source === audio.SourceType.SOURCE_TYPE_VOICE_MESSAGE) {
      return '语音消息(降噪)';
    }
    return '通话增强';
  }

  getSupportedNrModes(source: audio.SourceType): audio.NoiseReductionMode[] {
    const cached = this.nrModesCache.get(source as number);
    return cached !== undefined ? cached : [];
  }

  async probeConfig(requested: CaptureConfig): Promise<CaptureConfig | null> {
    let capturer: audio.AudioCapturer | null = null;
    try {
      capturer = await audio.createAudioCapturer(this.buildOptions(requested));
      this.cacheNrModes(capturer, requested.source);
      const actual = capturer.getStreamInfoSync();
      const actualRate = this.rateEnumToNumber(actual.samplingRate);
      const actualBits = this.formatToBits(actual.sampleFormat);
      const actualChannels = actual.channels === audio.AudioChannel.CHANNEL_2 ? 2 : 1;
      await this.releaseCapturer(capturer);
      capturer = null;
      const result: CaptureConfig = {
        source: requested.source,
        sampleRate: actualRate,
        sampleBits: actualBits,
        channels: actualChannels,
        noiseReductionChoice: requested.noiseReductionChoice
      };
      const matched = actualRate === requested.sampleRate && actualBits === requested.sampleBits
        && actualChannels === requested.channels;
      if (matched) {
        MicLogger.info(`探测通过: ${actualRate}Hz/${actualBits}bit/${actualChannels}ch 源:${this.getSourceName(requested.source)}`);
      } else {
        MicLogger.warn(`设备参数降级: 请求 ${requested.sampleRate}Hz/${requested.sampleBits}bit/${requested.channels}ch`
          + ` 实际 ${actualRate}Hz/${actualBits}bit/${actualChannels}ch`);
      }
      return result;
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`探测失败 (源:${this.getSourceName(requested.source)} `
        + `${requested.sampleRate}Hz/${requested.sampleBits}bit/${requested.channels}ch): ${err.message}`);
      if (capturer !== null) {
        await this.releaseCapturer(capturer);
      }
      return null;
    }
  }

  async start(config: CaptureConfig): Promise<CaptureConfig> {
    if (this.capturer !== null) {
      await this.release();
    }
    this.config = config;
    this.capturer = await audio.createAudioCapturer(this.buildOptions(config));
    MicLogger.info(
      `采集器已创建: ${config.sampleRate}Hz ${config.sampleBits}bit ${config.channels}声道 源:${this.getSourceName(config.source)}`);

    try {
      this.cacheNrModes(this.capturer, config.source);
      this.applyNoiseReductionMode();
      await this.setupCallbacks();
      await this.capturer.start();
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`采集器启动异常, 已回滚释放: ${err.message}`);
      await this.release();
      throw new Error(`capturer start failed: code=${err.code} ${err.message}`);
    }
    this.running = true;

    const actual = this.readBackActualParams();
    if (actual !== null) {
      this.config = actual;
      this.notifyState(true,
        `录音中 ${actual.sampleRate}Hz ${actual.sampleBits}bit ${actual.channels}声道 (${this.getSourceName(actual.source)})`);
      return actual;
    }
    this.notifyState(true,
      `录音中 ${config.sampleRate}Hz ${config.sampleBits}bit ${config.channels}声道 (${this.getSourceName(config.source)})`);
    return config;
  }

  async stop(): Promise<void> {
    const capturer = this.capturer;
    if (capturer === null) {
      return;
    }
    try {
      if (capturer.state === audio.AudioState.STATE_RUNNING) {
        await capturer.stop();
      }
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`停止采集异常: ${err.message}`);
    }
    await this.release();
  }

  async release(): Promise<void> {
    const capturer = this.capturer;
    this.capturer = null;
    if (capturer !== null) {
      try {
        capturer.off('readData');
        capturer.off('stateChange');
        capturer.off('audioInterrupt');
      } catch (error) {
        const err = error as BusinessError;
        MicLogger.warn(`注销采集器回调异常: ${err.message}`);
      }
      await this.releaseCapturer(capturer);
    }
    if (this.running) {
      this.running = false;
      this.notifyState(false, '采集已停止并释放资源');
    }
  }

  private async releaseCapturer(capturer: audio.AudioCapturer): Promise<void> {
    try {
      capturer.off('readData');
      capturer.off('stateChange');
      capturer.off('audioInterrupt');
      await capturer.release();
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`释放采集器异常: ${err.message}`);
    }
  }

  private buildOptions(config: CaptureConfig): audio.AudioCapturerOptions {
    const streamInfo: audio.AudioStreamInfo = {
      channels: config.channels === 2 ? audio.AudioChannel.CHANNEL_2 : audio.AudioChannel.CHANNEL_1,
      samplingRate: this.rateNumberToEnum(config.sampleRate),
      sampleFormat: this.bitsToFormat(config.sampleBits),
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: config.source,
      capturerFlags: 0
    };
    const options: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo
    };
    return options;
  }

  private readBackActualParams(): CaptureConfig | null {
    const capturer = this.capturer;
    const config = this.config;
    if (capturer === null || config === null) {
      return null;
    }
    try {
      const actual = capturer.getStreamInfoSync();
      const result: CaptureConfig = {
        source: config.source,
        sampleRate: this.rateEnumToNumber(actual.samplingRate),
        sampleBits: this.formatToBits(actual.sampleFormat),
        channels: actual.channels === audio.AudioChannel.CHANNEL_2 ? 2 : 1,
        noiseReductionChoice: config.noiseReductionChoice
      };
      if (result.sampleRate !== config.sampleRate || result.sampleBits !== config.sampleBits
        || result.channels !== config.channels) {
        MicLogger.warn(`运行态参数校验: 请求 ${config.sampleRate}Hz/${config.sampleBits}bit/${config.channels}ch `
          + `实际 ${result.sampleRate}Hz/${result.sampleBits}bit/${result.channels}ch，按实际参数传输`);
      }
      return result;
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`读取实际流参数失败: ${err.message}`);
      return null;
    }
  }

  private bitsToFormat(bits: number): audio.AudioSampleFormat {
    if (bits === 32) {
      return audio.AudioSampleFormat.SAMPLE_FORMAT_S32LE;
    }
    if (bits === 24) {
      return audio.AudioSampleFormat.SAMPLE_FORMAT_S24LE;
    }
    return audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE;
  }

  private formatToBits(format: audio.AudioSampleFormat): number {
    if (format === audio.AudioSampleFormat.SAMPLE_FORMAT_S32LE) {
      return 32;
    }
    if (format === audio.AudioSampleFormat.SAMPLE_FORMAT_S24LE) {
      return 24;
    }
    if (format === audio.AudioSampleFormat.SAMPLE_FORMAT_F32LE) {
      MicLogger.warn('设备返回 F32LE 浮点格式，按 32bit 传输，PC 端需按 float32 解码');
      return 32;
    }
    return 16;
  }

  private rateNumberToEnum(rate: number): audio.AudioSamplingRate {
    if (rate === 48000) {
      return audio.AudioSamplingRate.SAMPLE_RATE_48000;
    }
    return audio.AudioSamplingRate.SAMPLE_RATE_16000;
  }

  private rateEnumToNumber(rate: audio.AudioSamplingRate): number {
    if (rate === audio.AudioSamplingRate.SAMPLE_RATE_48000) {
      return 48000;
    }
    if (rate === audio.AudioSamplingRate.SAMPLE_RATE_44100) {
      return 44100;
    }
    if (rate === audio.AudioSamplingRate.SAMPLE_RATE_32000) {
      return 32000;
    }
    if (rate === audio.AudioSamplingRate.SAMPLE_RATE_24000) {
      return 24000;
    }
    if (rate === audio.AudioSamplingRate.SAMPLE_RATE_22050) {
      return 22050;
    }
    if (rate === audio.AudioSamplingRate.SAMPLE_RATE_12000) {
      return 12000;
    }
    if (rate === audio.AudioSamplingRate.SAMPLE_RATE_11025) {
      return 11025;
    }
    if (rate === audio.AudioSamplingRate.SAMPLE_RATE_8000) {
      return 8000;
    }
    return 16000;
  }

  private cacheNrModes(capturer: audio.AudioCapturer, source: audio.SourceType): void {
    if (deviceInfo.sdkApiVersion < NOISE_REDUCTION_API_LEVEL) {
      return;
    }
    try {
      const modes = capturer.getSupportedNoiseReductionModes();
      this.nrModesCache.set(source as number, modes);
      MicLogger.info(`源:${this.getSourceName(source)} 支持的降噪模式: [${modes.join(',')}]`);
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`查询降噪模式异常: ${err.message}`);
    }
  }

  private applyNoiseReductionMode(): void {
    const capturer = this.capturer;
    const config = this.config;
    if (capturer === null || config === null) {
      return;
    }
    if (config.noiseReductionChoice === 0) {
      MicLogger.info('降噪模式: 保持设备默认');
      return;
    }
    if (deviceInfo.sdkApiVersion < NOISE_REDUCTION_API_LEVEL) {
      MicLogger.info(`系统 API${deviceInfo.sdkApiVersion} 不支持降噪模式设置 (需 API${NOISE_REDUCTION_API_LEVEL})，已跳过`);
      return;
    }
    const desired = this.choiceToMode(config.noiseReductionChoice);
    if (desired === null) {
      return;
    }
    const supported = this.getSupportedNrModes(config.source);
    try {
      if (supported.length === 0 || supported.includes(desired)) {
        capturer.setNoiseReductionMode(desired);
        MicLogger.info(`已设置降噪模式: ${this.nrModeName(desired)} (源:${this.getSourceName(config.source)})`);
      } else {
        MicLogger.warn(`降噪模式 ${this.nrModeName(desired)} 不在设备支持列表，未设置`);
      }
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`设置降噪模式异常: ${err.message}`);
    }
  }

  private choiceToMode(choice: number): audio.NoiseReductionMode | null {
    if (choice === 1) {
      return audio.NoiseReductionMode.STANDARD;
    }
    if (choice === 2) {
      return audio.NoiseReductionMode.PURE_VOCALS;
    }
    if (choice === 3) {
      return audio.NoiseReductionMode.FIDELITY;
    }
    return null;
  }

  private nrModeName(mode: audio.NoiseReductionMode): string {
    if (mode === audio.NoiseReductionMode.STANDARD) {
      return 'STANDARD';
    }
    if (mode === audio.NoiseReductionMode.PURE_VOCALS) {
      return 'PURE_VOCALS';
    }
    return 'FIDELITY';
  }

  private async setupCallbacks(): Promise<void> {
    const capturer = this.capturer;
    if (capturer === null) {
      return;
    }
    capturer.setWillMuteWhenInterrupted(true).catch((error: BusinessError) => {
      MicLogger.warn(`设置静音打断策略失败: ${error.message}`);
    });
    capturer.on('stateChange', (state: audio.AudioState) => {
      MicLogger.info(`采集器状态变化: ${state}`);
      if (state === audio.AudioState.STATE_STOPPED || state === audio.AudioState.STATE_RELEASED) {
        if (this.running) {
          this.running = false;
          this.notifyState(false, `采集被打断或停止 (${state})`);
        }
      }
    });
    capturer.on('readData', (buffer: ArrayBuffer) => {
      const copy = buffer.slice(0);
      if (this.onAudioData !== null) {
        this.onAudioData(copy);
      }
    });
    try {
      capturer.on('audioInterrupt', (event: audio.InterruptEvent) => {
        MicLogger.info(`采集器被打断: type=${event.eventType} force=${event.forceType} hint=${event.hintType}`);
        if (this.onMicInterrupted !== null) {
          this.onMicInterrupted(event);
        }
      });
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`注册打断回调异常: ${err.message}`);
    }
  }

  private notifyState(running: boolean, detail: string): void {
    MicLogger.info(`[音频] ${detail}`);
    if (this.onCaptureStateChanged !== null) {
      this.onCaptureStateChanged(running, detail);
    }
  }
}
