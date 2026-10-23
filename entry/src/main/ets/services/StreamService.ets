import { common, wantAgent } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { audio } from '@kit.AudioKit';
import { preferences } from '@kit.ArkData';
import { AudioCaptureManager, CaptureConfig, TcpClientManager, TcpState, TcpQualityMetrics, AudioStreamDesc, AudioTcpSender, MicYouTcpClient, NetInfoService, NetSnapshot, PermissionUtil, MicLogger, AudioVizManager, AudioPipeline, GainStage, LimiterStage, EqStage, EqBandParams, EqBandType, EqPresets, EQ_BAND_COUNT } from 'common';
import { AvSessionService } from './AvSessionService';
import { UiEnvService } from './UiEnvService';
import { Mat } from '../component/Materials';
import audioNr from 'libaudio_nr.so';

const BUNDLE_NAME = 'com.example.harmonymic';
const ABILITY_NAME = 'EntryAbility';
const UI_REFRESH_INTERVAL_MS = 500;
const CONFIG_DEBOUNCE_MS = 600;
const PREF_NAME = 'harmonymic_settings';
const KEY_PC_IP = 'pc_ip';
const KEY_PC_PORT = 'pc_port';
const KEY_RX_KIND = 'rx_kind';
const KEY_WELCOMED = 'welcomed';
const KEY_GAIN_DB = 'gain_db';
const KEY_LIMITER_ON = 'limiter_on';
const KEY_EQ_BYPASS = 'eq_bypass';
const KEY_EQ_PRESET = 'eq_preset';
const KEY_EQ_BANDS = 'eq_bands';
const KEY_MATERIAL_LEVEL = 'material_level';
const KEY_CFG_SOURCE = 'cfg_source';
const KEY_CFG_RATE = 'cfg_rate';
const KEY_CFG_BITS = 'cfg_bits';
const KEY_CFG_CHANNELS = 'cfg_channels';
const KEY_CFG_NR = 'cfg_nr';
const KEY_CFG_PRO_NR = 'cfg_pro_nr';
const KEY_CFG_DF_STRENGTH = 'cfg_df_strength';
const KEY_CFG_NOISY = 'cfg_noisy';
const GAIN_PERSIST_DEBOUNCE_MS = 500;
const EQ_PERSIST_DEBOUNCE_MS = 500;

interface EqBandRaw {
  type: number;
  freqHz: number;
  gainDb: number;
  q: number;
}
const AUDIO_SESSION_CONFLICT_CODE = 6800301;
const WEAK_SUSTAIN_MS = 10000;
const GOOD_SUSTAIN_MS = 10000;
const RATE_ACTION_MIN_INTERVAL_MS = 30000;
const TCP_DROP_RATE_WEAK = 0.05;
const TCP_DROP_RATE_FAIR = 0.01;
const TCP_QUEUE_LEVEL_WEAK = 0.8;
const TCP_QUEUE_LEVEL_FAIR = 0.5;
const RECOVER_TOAST_THROTTLE_MS = 30000;

export enum StartResult {
  OK = 0,
  NO_PERMISSION = 1,
  OCCUPIED = 2,
  CONNECT_FAILED = 3,
  UNSUPPORTED = 4,
  INVALID_ENDPOINT = 5,
  INTERNAL = 6
}

class PresetSnapshot {
  sourceChoice: number = 0;
  nrChoice: number = 0;
  proNrMode: boolean = false;
  dfStrength: number = 0;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  return `${(bytes / 1024 / 1024).toFixed(2)} MB`;
}

export function isValidIp(ip: string): boolean {
  const pattern = /^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/;
  return pattern.test(ip);
}

export function isValidPort(port: number): boolean {
  return Number.isFinite(port) && port >= 1 && port <= 65535;
}

export class StreamService {
  private static instance: StreamService | null = null;
  private context: common.UIAbilityContext | null = null;
  private audioMgr: AudioCaptureManager = new AudioCaptureManager();
  private tcpMgr: AudioTcpSender = new TcpClientManager();
  private vizMgr: AudioVizManager = new AudioVizManager();
  private avSessionSvc: AvSessionService = new AvSessionService();
  private sessionManager: audio.AudioSessionManager | null = null;
  private sessionActive: boolean = false;
  private uiTimerId: number = -1;
  private configDebounceId: number = -1;
  private bgTaskRunning: boolean = false;
  private isRunning: boolean = false;
  private isRestarting: boolean = false;
  private pendingConfigChange: boolean = false;
  private probing: boolean = false;
  private matrixLoaded: boolean = false;
  private supportMatrix: boolean[] = [true, true, true, true, true, true, true, true, true, true, true, true];
  private nrSupported: boolean[] = [true, true, true, true];
  private lastGoodConfig: CaptureConfig | null = null;
  private lastProbedSource: number = -1;
  private proNrActive: boolean = false;
  private silenceCache: ArrayBuffer = new ArrayBuffer(0);
  private savedPreset: PresetSnapshot | null = null;
  private netSnapshot: NetSnapshot | null = null;
  private netWatchStarted: boolean = false;
  private lastTcpMetrics: TcpQualityMetrics | null = null;
  private windowDropRate: number = 0;
  private windowQueueLevel: number = 0;
  private rateDowngraded: boolean = false;
  private weakSince: number = -1;
  private goodSince: number = -1;
  private lastRateActionAt: number = 0;
  private pipeline: AudioPipeline = new AudioPipeline();
  private eqStage: EqStage = new EqStage();
  private gainStage: GainStage = new GainStage();
  private limiterStage: LimiterStage = new LimiterStage();
  private gainPersistId: number = -1;
  private eqPersistId: number = -1;
  private callInterrupted: boolean = false;
  private lastRecoverToastAt: number = 0;

  static getInstance(): StreamService {
    if (StreamService.instance === null) {
      StreamService.instance = new StreamService();
    }
    return StreamService.instance;
  }

  static resultText(result: StartResult): string {
    if (result === StartResult.OK) {
      return '';
    }
    if (result === StartResult.NO_PERMISSION) {
      return '需要麦克风权限，请前往设置开启';
    }
    if (result === StartResult.OCCUPIED) {
      return '麦克风被其他应用占用，请关闭后重试';
    }
    if (result === StartResult.CONNECT_FAILED) {
      return '连接 PC 失败，请检查接收端与网络';
    }
    if (result === StartResult.UNSUPPORTED) {
      return '当前音频配置不受设备支持';
    }
    if (result === StartResult.INVALID_ENDPOINT) {
      return 'IP 或端口不合法';
    }
    return '启动失败，请查看日志';
  }

  running(): boolean {
    return this.isRunning;
  }

  getVizManager(): AudioVizManager {
    return this.vizMgr;
  }

  init(context: common.UIAbilityContext, autoProbe: boolean): void {
    if (this.context !== null) {
      return;
    }
    this.context = context;
    AppStorage.setOrCreate('cfgSource', 0);
    AppStorage.setOrCreate('cfgRate', 0);
    AppStorage.setOrCreate('cfgBits', 0);
    AppStorage.setOrCreate('cfgChannels', 0);
    AppStorage.setOrCreate('cfgNr', 0);
    AppStorage.setOrCreate('cfgProNr', false);
    AppStorage.setOrCreate('cfgDfStrength', 0);
    AppStorage.setOrCreate('cfgNoisy', false);
    AppStorage.setOrCreate('vizMuted', false);
    AppStorage.setOrCreate('vizStreaming', false);
    AppStorage.setOrCreate('vizNrActive', false);
    AppStorage.setOrCreate('vizMgr', this.vizMgr);
    AppStorage.setOrCreate('micOccupied', false);
    AppStorage.setOrCreate('streamBusy', 'idle');
    AppStorage.setOrCreate('statConn', '未连接');
    AppStorage.setOrCreate('statRecord', '空闲');
    AppStorage.setOrCreate('statBytes', '0 B');
    AppStorage.setOrCreate('statQueue', '队列 0 块 · 丢弃 0 块');
    AppStorage.setOrCreate('statLog', '');
    AppStorage.setOrCreate('pcIp', '');
    AppStorage.setOrCreate('pcPort', '9000');
    AppStorage.setOrCreate('rxKind', 'harmonymic');
    AppStorage.setOrCreate('proNrAvailable', audioNr.nrIsSupported());
    AppStorage.setOrCreate('probeText', '能力未探测');
    AppStorage.setOrCreate('probing', false);
    AppStorage.setOrCreate('matrixLoaded', false);
    AppStorage.setOrCreate('supportMatrix', this.supportMatrix.slice());
    AppStorage.setOrCreate('nrSupported', this.nrSupported.slice());
    AppStorage.setOrCreate('netOnline', true);
    AppStorage.setOrCreate('netBearer', 'unknown');
    AppStorage.setOrCreate('netQuality', 'good');
    AppStorage.setOrCreate('rateDowngraded', false);
    AppStorage.setOrCreate('cfgAutoDowngrade', true);
    AppStorage.setOrCreate('cfgKeepScreenOn', false);
    AppStorage.setOrCreate('cfgAutoRecover', true);
    AppStorage.setOrCreate('inputDeviceName', '');
    AppStorage.setOrCreate('cfgGainDb', 0);
    AppStorage.setOrCreate('cfgLimiterOn', true);
    AppStorage.setOrCreate('cfgEqBypass', true);
    AppStorage.setOrCreate('cfgEqPreset', EqPresets.FLAT);
    AppStorage.setOrCreate('cfgEqBands', EqPresets.defaultBands());
    AppStorage.setOrCreate('cfgMaterialLevel', 1);
    this.pipeline = new AudioPipeline();
    this.pipeline.addStage(this.eqStage);
    this.pipeline.addStage(this.gainStage);
    this.pipeline.addStage(this.limiterStage);
    MicLogger.info(`DeepFilterNet3 降噪可用: ${AppStorage.get<boolean>('proNrAvailable') === true}`);
    this.audioMgr.onMicInterrupted = (event: audio.InterruptEvent): void => {
      if (event.eventType === audio.InterruptType.INTERRUPT_TYPE_END) {
        this.handleInterruptEnd();
        return;
      }
      if (event.forceType === audio.InterruptForceType.INTERRUPT_FORCE
        && (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE
          || event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP
          || event.hintType === audio.InterruptHint.INTERRUPT_HINT_MUTE)) {
        if (this.isRunning && !this.isRestarting) {
          this.callInterrupted = true;
          MicLogger.warn(`采集被通话类打断 (hint=${event.hintType})，系统自动闭麦/强停，等待打断结束事件`);
        }
      }
    };
    this.avSessionSvc.onToggleMute = (muted: boolean): void => {
      AppStorage.setOrCreate('vizMuted', muted);
    };
    this.avSessionSvc.onStopStream = (): void => {
      this.stop();
    };
    try {
      this.sessionManager = audio.getAudioManager().getSessionManager();
      this.sessionManager.on('audioSessionDeactivated', (event: audio.AudioSessionDeactivatedEvent) => {
        MicLogger.warn(`音频会话被取消激活: reason=${event.reason}`);
        this.sessionActive = false;
        if (this.isRunning && !this.isRestarting && !this.callInterrupted
          && event.reason === audio.AudioSessionDeactivatedReason.DEACTIVATED_LOWER_PRIORITY) {
          this.handleMicLost('音频会话被更高优先级应用抢占');
        }
      });
      this.sessionManager.on('availableDeviceChange', audio.DeviceUsage.MEDIA_INPUT_DEVICES,
        (action: audio.DeviceChangeAction) => {
          MicLogger.info(`输入设备插拔: ${this.deviceChangeActionText(action)}`);
        });
      this.sessionManager.on('currentInputDeviceChanged', (event: audio.CurrentInputDeviceChangedEvent) => {
        this.handleInputDeviceChanged(event);
      });
      MicLogger.info('音频会话管理器已就绪，麦克风占用检测已启用');
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`音频会话管理器初始化失败 (占用检测降级): ${err.message}`);
      this.sessionManager = null;
    }
    if (!this.netWatchStarted) {
      this.netWatchStarted = true;
      NetInfoService.getInstance().startWatch((snapshot: NetSnapshot): void => {
        this.handleNetSnapshot(snapshot);
      });
    }
    this.uiTimerId = setInterval(() => {
      this.publishStats();
    }, UI_REFRESH_INTERVAL_MS);
    this.loadSavedEndpoint();
    this.loadGainSettings();
    this.loadEqSettings();
    this.loadMaterialSettings();
    // 说明: 探测必须等连接配置载入完成——持久化的音源恢复后再探测，避免按默认音源探测错对象；
    // loadConfigChoices 内部 catch 保证永不 reject，探测不会丢。
    this.loadConfigChoices().then((): void => {
      if (autoProbe) {
        this.probeCurrentSource();
      }
    });
  }

  setGainDb(gainDb: number): void {
    const clamped = Math.max(-24, Math.min(24, gainDb));
    AppStorage.setOrCreate('cfgGainDb', clamped);
    if (this.gainPersistId !== -1) {
      clearTimeout(this.gainPersistId);
    }
    this.gainPersistId = setTimeout(() => {
      this.gainPersistId = -1;
      this.persistGainSettings();
    }, GAIN_PERSIST_DEBOUNCE_MS);
  }

  setLimiterOn(on: boolean): void {
    AppStorage.setOrCreate('cfgLimiterOn', on);
    MicLogger.info(on ? '限幅器已开启 (阈值 -0.1dBFS)' : '限幅器已关闭');
    this.persistGainSettings();
  }

  private async persistGainSettings(): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      store.putSync(KEY_GAIN_DB, AppStorage.get<number>('cfgGainDb') ?? 0);
      store.putSync(KEY_LIMITER_ON, AppStorage.get<boolean>('cfgLimiterOn') !== false);
      await store.flush();
      MicLogger.info(`输入增益已保存: ${(AppStorage.get<number>('cfgGainDb') ?? 0).toFixed(1)} dB`);
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`保存增益设置失败: ${err.message}`);
    }
  }

  private async loadGainSettings(): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      const gain = store.getSync(KEY_GAIN_DB, 0);
      if (typeof gain === 'number') {
        AppStorage.setOrCreate('cfgGainDb', Math.max(-24, Math.min(24, gain)));
      }
      const limiter = store.getSync(KEY_LIMITER_ON, true);
      if (typeof limiter === 'boolean') {
        AppStorage.setOrCreate('cfgLimiterOn', limiter);
      }
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`读取增益设置失败: ${err.message}`);
    }
  }

  // 说明: 连接配置弹出卡全部选择（音源/采样率/位深/声道/降噪模式/DF3 开关/强度/嘈杂模式）持久化——
  // 由 onConfigChanged 防抖回调与 setDfStrength 触发，重启后保留上一次结果。
  private async persistConfigChoices(): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      store.putSync(KEY_CFG_SOURCE, AppStorage.get<number>('cfgSource') ?? 0);
      store.putSync(KEY_CFG_RATE, AppStorage.get<number>('cfgRate') ?? 0);
      store.putSync(KEY_CFG_BITS, AppStorage.get<number>('cfgBits') ?? 0);
      store.putSync(KEY_CFG_CHANNELS, AppStorage.get<number>('cfgChannels') ?? 0);
      store.putSync(KEY_CFG_NR, AppStorage.get<number>('cfgNr') ?? 0);
      store.putSync(KEY_CFG_PRO_NR, AppStorage.get<boolean>('cfgProNr') === true);
      store.putSync(KEY_CFG_DF_STRENGTH, AppStorage.get<number>('cfgDfStrength') ?? 0);
      store.putSync(KEY_CFG_NOISY, AppStorage.get<boolean>('cfgNoisy') === true);
      await store.flush();
      MicLogger.info('连接配置已保存');
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`保存连接配置失败: ${err.message}`);
    }
  }

  private async loadConfigChoices(): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      const source = store.getSync(KEY_CFG_SOURCE, 0);
      if (typeof source === 'number') {
        AppStorage.setOrCreate('cfgSource', source);
      }
      const rate = store.getSync(KEY_CFG_RATE, 0);
      if (typeof rate === 'number') {
        AppStorage.setOrCreate('cfgRate', rate);
      }
      const bits = store.getSync(KEY_CFG_BITS, 0);
      if (typeof bits === 'number') {
        AppStorage.setOrCreate('cfgBits', bits);
      }
      const channels = store.getSync(KEY_CFG_CHANNELS, 0);
      if (typeof channels === 'number') {
        AppStorage.setOrCreate('cfgChannels', channels);
      }
      const nr = store.getSync(KEY_CFG_NR, 0);
      if (typeof nr === 'number') {
        AppStorage.setOrCreate('cfgNr', nr);
      }
      const proNr = store.getSync(KEY_CFG_PRO_NR, false);
      if (typeof proNr === 'boolean') {
        AppStorage.setOrCreate('cfgProNr', proNr);
      }
      const dfStrength = store.getSync(KEY_CFG_DF_STRENGTH, 0);
      if (typeof dfStrength === 'number') {
        AppStorage.setOrCreate('cfgDfStrength', dfStrength);
      }
      const noisy = store.getSync(KEY_CFG_NOISY, false);
      if (typeof noisy === 'boolean') {
        AppStorage.setOrCreate('cfgNoisy', noisy);
      }
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`读取连接配置失败: ${err.message}`);
    }
  }

  // 说明: 沉浸光感强度（0 柔和/1 标准/2 浓郁）——按档重建 Mat 材质实例并写 AppStorage
  // 驱动卡面字面兜底色联动；档位即强度（API 26 无数值强度参数）。
  setMaterialLevel(level: number): void {
    const clamped = Math.max(0, Math.min(2, Math.round(level)));
    Mat.applyLevel(clamped);
    AppStorage.setOrCreate('cfgMaterialLevel', clamped);
    const label = clamped === 0 ? '柔和' : (clamped === 2 ? '浓郁' : '标准');
    MicLogger.info(`沉浸光感强度已调整: ${label}`);
    this.persistMaterialLevel();
  }

  private async persistMaterialLevel(): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      store.putSync(KEY_MATERIAL_LEVEL, AppStorage.get<number>('cfgMaterialLevel') ?? 1);
      await store.flush();
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`保存光感强度失败: ${err.message}`);
    }
  }

  private async loadMaterialSettings(): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      const level = store.getSync(KEY_MATERIAL_LEVEL, 1);
      if (typeof level === 'number' && level >= 0 && level <= 2) {
        Mat.applyLevel(level);
        AppStorage.setOrCreate('cfgMaterialLevel', level);
      }
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`读取光感强度失败: ${err.message}`);
    }
  }

  setEqBypass(bypass: boolean): void {
    AppStorage.setOrCreate('cfgEqBypass', bypass);
    MicLogger.info(bypass ? '均衡器已旁通 (bit 级直通)' : '均衡器已启用');
    this.persistEqSettings();
  }

  setEqPreset(name: string): void {
    const names = EqPresets.presetNames();
    let valid = false;
    for (let i = 0; i < names.length; i++) {
      if (names[i] === name) {
        valid = true;
        break;
      }
    }
    if (!valid) {
      return;
    }
    AppStorage.setOrCreate('cfgEqBands', EqPresets.presetBands(name));
    AppStorage.setOrCreate('cfgEqPreset', name);
    MicLogger.info(`均衡器预设: ${name}`);
    this.persistEqSettings();
  }

  setEqBandGain(index: number, gainDb: number): void {
    if (index < 0 || index >= EQ_BAND_COUNT) {
      return;
    }
    const clamped = Math.max(-12, Math.min(12, gainDb));
    const bands = this.currentEqBands();
    const next: EqBandParams[] = [];
    for (let i = 0; i < bands.length; i++) {
      const b = bands[i];
      if (i === index) {
        next.push({ type: b.type, freqHz: b.freqHz, gainDb: clamped, q: b.q });
      } else {
        next.push({ type: b.type, freqHz: b.freqHz, gainDb: b.gainDb, q: b.q });
      }
    }
    AppStorage.setOrCreate('cfgEqBands', next);
    AppStorage.setOrCreate('cfgEqPreset', EqPresets.CUSTOM);
    if (this.eqPersistId !== -1) {
      clearTimeout(this.eqPersistId);
    }
    this.eqPersistId = setTimeout(() => {
      this.eqPersistId = -1;
      this.persistEqSettings();
    }, EQ_PERSIST_DEBOUNCE_MS);
  }

  private currentEqBands(): EqBandParams[] {
    const stored = AppStorage.get<EqBandParams[]>('cfgEqBands');
    if (stored !== undefined && stored.length === EQ_BAND_COUNT) {
      return stored;
    }
    return EqPresets.defaultBands();
  }

  private async persistEqSettings(): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      store.putSync(KEY_EQ_BYPASS, AppStorage.get<boolean>('cfgEqBypass') !== false);
      store.putSync(KEY_EQ_PRESET, AppStorage.get<string>('cfgEqPreset') ?? EqPresets.FLAT);
      store.putSync(KEY_EQ_BANDS, JSON.stringify(this.currentEqBands()));
      await store.flush();
      MicLogger.info(`均衡器设置已保存: 预设 ${AppStorage.get<string>('cfgEqPreset') ?? EqPresets.FLAT}`);
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`保存均衡器设置失败: ${err.message}`);
    }
  }

  private async loadEqSettings(): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      const bypass = store.getSync(KEY_EQ_BYPASS, true);
      if (typeof bypass === 'boolean') {
        AppStorage.setOrCreate('cfgEqBypass', bypass);
      }
      const preset = store.getSync(KEY_EQ_PRESET, EqPresets.FLAT);
      if (typeof preset === 'string' && preset.length > 0) {
        AppStorage.setOrCreate('cfgEqPreset', preset);
      }
      const bandsRaw = store.getSync(KEY_EQ_BANDS, '');
      if (typeof bandsRaw === 'string' && bandsRaw.length > 0) {
        const bands = this.parseEqBands(bandsRaw);
        if (bands !== null) {
          if (bands.length === 5) {
            // 说明: 旧 5 段持久化迁移到 8 段——具名预设直接升级为 8 段新定义，
            // 自定义设置按控制点频率 1:1 映射（100/300/1k/3k/8k 锚点保留，新段增益从 0 起步）。
            const presetName = AppStorage.get<string>('cfgEqPreset') ?? EqPresets.FLAT;
            if (presetName === EqPresets.VOICE || presetName === EqPresets.LOW_CUT || presetName === EqPresets.BRIGHT) {
              AppStorage.setOrCreate('cfgEqBands', EqPresets.presetBands(presetName));
            } else {
              AppStorage.setOrCreate('cfgEqBands', this.migrateLegacyBands(bands));
            }
          } else {
            AppStorage.setOrCreate('cfgEqBands', bands);
          }
        }
      }
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`读取均衡器设置失败: ${err.message}`);
    }
  }

  // 说明: 旧 5 段 → 8 段迁移：频率一致的控制点保留增益与 Q，新增段（180/550/1800 Hz）增益 0 起步。
  private migrateLegacyBands(legacy: EqBandParams[]): EqBandParams[] {
    const defaults = EqPresets.defaultBands();
    const out: EqBandParams[] = [];
    for (let i = 0; i < defaults.length; i++) {
      const d = defaults[i];
      let gainDb = 0;
      let q = d.q;
      for (let j = 0; j < legacy.length; j++) {
        if (legacy[j].freqHz === d.freqHz) {
          gainDb = legacy[j].gainDb;
          q = legacy[j].q;
          break;
        }
      }
      out.push({ type: d.type, freqHz: d.freqHz, gainDb: gainDb, q: q });
    }
    return out;
  }

  private parseEqBands(text: string): EqBandParams[] | null {
    const raw = JSON.parse(text) as EqBandRaw[];
    if (!Array.isArray(raw) || (raw.length !== 5 && raw.length !== EQ_BAND_COUNT)) {
      return null;
    }
    const defaults = EqPresets.defaultBands();
    const bands: EqBandParams[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item = raw[i];
      if (item === null) {
        return null;
      }
      if (typeof item.type !== 'number' || typeof item.freqHz !== 'number'
        || typeof item.gainDb !== 'number' || typeof item.q !== 'number') {
        return null;
      }
      const fallback = defaults[i];
      bands.push({
        type: item.type === 0 ? EqBandType.LOW_SHELF : (item.type === 2 ? EqBandType.HIGH_SHELF : fallback.type),
        freqHz: item.freqHz > 0 ? item.freqHz : fallback.freqHz,
        gainDb: Math.max(-12, Math.min(12, item.gainDb)),
        q: Math.max(0.5, Math.min(4, item.q))
      });
    }
    return bands;
  }

  onConfigChanged(): void {
    if (this.configDebounceId !== -1) {
      clearTimeout(this.configDebounceId);
    }
    this.configDebounceId = setTimeout(() => {
      this.configDebounceId = -1;
      this.persistConfigChoices();
      if (this.isRunning) {
        this.applyLiveConfig();
      } else {
        const source = this.cfgNumber('cfgSource', 0);
        if (source !== this.lastProbedSource) {
          this.probeCurrentSource();
        }
      }
    }, CONFIG_DEBOUNCE_MS);
  }

  setDfStrength(tier: number): void {
    AppStorage.setOrCreate('cfgDfStrength', tier);
    audioNr.nrSetStrength(tier);
    this.persistConfigChoices();
  }

  applyNoisyEnvPreset(on: boolean): void {
    if (on) {
      if (this.savedPreset === null) {
        const snap = new PresetSnapshot();
        snap.sourceChoice = this.cfgNumber('cfgSource', 0);
        snap.nrChoice = this.cfgNumber('cfgNr', 0);
        snap.proNrMode = AppStorage.get<boolean>('cfgProNr') === true;
        snap.dfStrength = this.cfgNumber('cfgDfStrength', 0);
        this.savedPreset = snap;
      }
      this.setDfStrength(2);
      AppStorage.setOrCreate('cfgProNr', true);
      AppStorage.setOrCreate('cfgNr', 2);
      AppStorage.setOrCreate('cfgSource', 3);
      AppStorage.setOrCreate('cfgNoisy', true);
      MicLogger.info('嘈杂环境模式已开启: 语音消息源 + 人声降噪(PURE_VOCALS) + DF3极致档 (两级串联降噪)');
    } else {
      const snap = this.savedPreset;
      if (snap !== null) {
        AppStorage.setOrCreate('cfgSource', snap.sourceChoice);
        AppStorage.setOrCreate('cfgNr', snap.nrChoice);
        AppStorage.setOrCreate('cfgProNr', snap.proNrMode);
        this.setDfStrength(snap.dfStrength);
        this.savedPreset = null;
      }
      AppStorage.setOrCreate('cfgNoisy', false);
      MicLogger.info('嘈杂环境模式已关闭，还原先前配置');
    }
    this.onConfigChanged();
  }

  probeNow(): void {
    this.probeCurrentSource();
  }

  async updateEndpoint(ip: string, port: string): Promise<boolean> {
    const trimmedIp = ip.trim();
    const portNumber = Number(port.trim());
    if (!isValidIp(trimmedIp) || !isValidPort(portNumber)) {
      return false;
    }
    AppStorage.setOrCreate('pcIp', trimmedIp);
    AppStorage.setOrCreate('pcPort', String(portNumber));
    await this.saveEndpoint(trimmedIp, String(portNumber));
    return true;
  }

  // 说明: 接收端类型——'harmonymic'=自有 pc-receiver（TCP 9000 小端帧），
  // 'micyou'=MicYou 桌面端兼容协议（TCP 9123 大端帧+protobuf+握手）。
  getRxKind(): string {
    return AppStorage.get<string>('rxKind') === 'micyou' ? 'micyou' : 'harmonymic';
  }

  async setRxKind(kind: string): Promise<boolean> {
    if (kind !== 'harmonymic' && kind !== 'micyou') {
      return false;
    }
    AppStorage.setOrCreate('rxKind', kind);
    await this.saveRxKind(kind);
    MicLogger.info(`接收端类型已切换: ${kind === 'micyou' ? 'MicYou 桌面端' : 'VoxBridge 接收器'}`);
    return true;
  }

  private async saveRxKind(kind: string): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      store.putSync(KEY_RX_KIND, kind);
      await store.flush();
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`保存接收端类型失败: ${err.message}`);
    }
  }

  // 说明: 会话启动前按 rxKind 换装发送端实现（运行中切换类型下次启动生效；
  // 旧实例 disconnect 为空操作兜底，正常路径 stop() 已先行断开）。
  private ensureSenderForRxKind(): void {
    const wantMicYou = this.getRxKind() === 'micyou';
    const currentIsMicYou = this.tcpMgr instanceof MicYouTcpClient;
    if (wantMicYou !== currentIsMicYou) {
      this.tcpMgr.disconnect();
      this.tcpMgr = wantMicYou ? new MicYouTcpClient() : new TcpClientManager();
      MicLogger.info(`[TCP] 发送端协议切换为 ${wantMicYou ? 'MicYou 桌面端' : 'VoxBridge 接收器'}`);
    }
  }

  async hasWelcomed(): Promise<boolean> {
    const context = this.context;
    if (context === null) {
      return false;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      const raw = store.getSync(KEY_WELCOMED, 0);
      return raw === 1;
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`读取引导标记失败: ${err.message}`);
      return false;
    }
  }

  async markWelcomed(): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      store.putSync(KEY_WELCOMED, 1);
      await store.flush();
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`保存引导标记失败: ${err.message}`);
    }
  }

  async start(ip: string, port: string): Promise<StartResult> {
    if (this.isRunning || this.isRestarting) {
      return StartResult.OK;
    }
    const trimmedIp = ip.trim();
    const portNumber = Number(port.trim());
    if (!isValidIp(trimmedIp)) {
      MicLogger.warn('请输入合法的 PC IP 地址');
      return StartResult.INVALID_ENDPOINT;
    }
    if (!isValidPort(portNumber)) {
      MicLogger.warn('请输入合法端口 (1-65535)');
      return StartResult.INVALID_ENDPOINT;
    }
    const context = this.context;
    if (context === null) {
      MicLogger.error('应用上下文未初始化');
      return StartResult.INTERNAL;
    }
    AppStorage.setOrCreate('streamBusy', 'starting');
    AppStorage.setOrCreate('micOccupied', false);
    const granted = await PermissionUtil.requestMicrophone(context);
    if (!granted) {
      AppStorage.setOrCreate('streamBusy', 'idle');
      return StartResult.NO_PERMISSION;
    }
    const occupied = await this.activateAudioSessionGuarded();
    if (occupied) {
      MicLogger.error('麦克风被其他应用占用 (音频会话激活冲突)，已取消开始');
      AppStorage.setOrCreate('micOccupied', true);
      AppStorage.setOrCreate('streamBusy', 'idle');
      return StartResult.OCCUPIED;
    }
    const proNrMode = AppStorage.get<boolean>('cfgProNr') === true;
    if (proNrMode) {
      const nrOk = audioNr.nrStart();
      if (!nrOk) {
        MicLogger.error(`DeepFilterNet3 降噪启动失败 [${audioNr.nrGetLastError()}]，已取消开始`);
        await this.deactivateAudioSessionGuarded();
        AppStorage.setOrCreate('streamBusy', 'idle');
        return StartResult.UNSUPPORTED;
      }
      this.proNrActive = true;
      MicLogger.info('DeepFilterNet3 降噪已启动: 输出强制 48kHz/单声道/16bit');
    }
    const requested = this.buildRequestedConfig();
    let actual: CaptureConfig | null = null;
    try {
      actual = await this.audioMgr.probeConfig(requested);
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.error(`启动前探测异常: ${err.message}`);
    }
    if (actual === null) {
      MicLogger.error('设备无法以当前配置录音 (音源/采样率/位深/声道组合不受支持)，请更换配置后重试');
      this.teardownNr();
      await this.deactivateAudioSessionGuarded();
      AppStorage.setOrCreate('streamBusy', 'idle');
      return StartResult.UNSUPPORTED;
    }
    this.supportMatrix[this.comboIndex(this.cfgNumber('cfgRate', 0), this.cfgNumber('cfgBits', 0), this.cfgNumber('cfgChannels', 0))] =
      actual.sampleRate === requested.sampleRate && actual.sampleBits === requested.sampleBits
      && actual.channels === requested.channels;
    this.matrixLoaded = true;
    this.lastProbedSource = this.cfgNumber('cfgSource', 0);
    AppStorage.setOrCreate('matrixLoaded', true);
    AppStorage.setOrCreate('supportMatrix', this.supportMatrix.slice());
    this.refreshNrSupport(actual.source);
    this.ensureSenderForRxKind();
    try {
      await this.tcpMgr.connect(trimmedIp, portNumber, this.descFromConfig(actual));
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.error(`连接 ${trimmedIp}:${portNumber} 失败 (code=${err.code})，请确认 PC 端接收程序已启动且 IP/端口正确`);
      this.teardownNr();
      await this.deactivateAudioSessionGuarded();
      AppStorage.setOrCreate('streamBusy', 'idle');
      return StartResult.CONNECT_FAILED;
    }
    await this.saveEndpoint(trimmedIp, String(portNumber));
    await this.startBgTask();
    this.audioMgr.onAudioData = (buffer: ArrayBuffer): void => {
      this.handleAudioData(buffer);
    };
    this.audioMgr.onCaptureStateChanged = (running: boolean, detail: string): void => {
      MicLogger.info(`采集回调: ${detail}`);
    };
    try {
      const started = await this.audioMgr.start(actual);
      this.lastGoodConfig = started;
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.error(`启动录音失败: ${err.message}`);
      this.tcpMgr.disconnect();
      await this.stopBgTask();
      this.teardownNr();
      await this.deactivateAudioSessionGuarded();
      AppStorage.setOrCreate('streamBusy', 'idle');
      return StartResult.INTERNAL;
    }
    this.vizMgr.reset();
    this.isRunning = true;
    AppStorage.setOrCreate('streamBusy', 'running');
    AppStorage.setOrCreate('vizStreaming', true);
    AppStorage.setOrCreate('vizNrActive', this.proNrActive);
    MicLogger.info('串流已启动');
    const avOk = await this.avSessionSvc.start(context, `${trimmedIp}:${portNumber}`,
      AppStorage.get<boolean>('vizMuted') === true);
    if (!avOk) {
      MicLogger.warn('锁屏媒体卡片不可用，串流功能不受影响');
    }
    if (AppStorage.get<boolean>('cfgKeepScreenOn') === true) {
      await UiEnvService.getInstance().setKeepScreenOn(true);
    }
    return StartResult.OK;
  }

  async stop(): Promise<void> {
    if (!this.isRunning) {
      return;
    }
    this.isRunning = false;
    this.callInterrupted = false;
    AppStorage.setOrCreate('vizMuted', false);
    AppStorage.setOrCreate('streamBusy', 'idle');
    try {
      await this.audioMgr.stop();
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`停止录音异常: ${err.message}`);
    }
    this.vizMgr.reset();
    this.tcpMgr.disconnect();
    this.rateDowngraded = false;
    AppStorage.setOrCreate('rateDowngraded', false);
    this.weakSince = -1;
    this.goodSince = -1;
    this.lastRateActionAt = 0;
    this.lastTcpMetrics = null;
    this.windowDropRate = 0;
    this.windowQueueLevel = 0;
    await this.stopBgTask();
    await this.avSessionSvc.stop();
    await UiEnvService.getInstance().setKeepScreenOn(false);
    this.teardownNr();
    AppStorage.setOrCreate('vizStreaming', false);
    AppStorage.setOrCreate('vizNrActive', false);
    AppStorage.setOrCreate('statRecord', '已停止');
    await this.deactivateAudioSessionGuarded();
    MicLogger.info('串流已停止');
    this.probeCurrentSource();
  }

  setCfgKeepScreenOn(on: boolean): void {
    AppStorage.setOrCreate('cfgKeepScreenOn', on);
    if (this.isRunning) {
      UiEnvService.getInstance().setKeepScreenOn(on);
    }
    MicLogger.info(`串流时屏幕常亮: ${on ? '开' : '关'}`);
  }

  setCfgAutoRecover(on: boolean): void {
    AppStorage.setOrCreate('cfgAutoRecover', on);
    MicLogger.info(`来电自动恢复: ${on ? '开' : '关'}`);
  }

  setCfgAutoDowngrade(on: boolean): void {
    AppStorage.setOrCreate('cfgAutoDowngrade', on);
    MicLogger.info(`弱网自动降级: ${on ? '开' : '关'}`);
  }

  private handleMicLost(reason: string): void {
    MicLogger.error(`麦克风被抢占: ${reason}`);
    AppStorage.setOrCreate('micOccupied', true);
    this.stop();
  }

  private handleInterruptEnd(): void {
    MicLogger.info('音频打断结束事件 (interrupt END)');
    if (!this.callInterrupted) {
      return;
    }
    this.callInterrupted = false;
    if (!this.isRunning || this.isRestarting) {
      return;
    }
    if (AppStorage.get<boolean>('cfgAutoRecover') !== true) {
      MicLogger.info('来电自动恢复已关闭 (cfgAutoRecover=false)，等待用户手动处理');
      return;
    }
    this.autoRecover();
  }

  private async autoRecover(): Promise<void> {
    if (this.audioMgr.isRunning()) {
      MicLogger.info('通话结束，采集器仍在运行 (系统自动闭麦已解除)');
      return;
    }
    const config = this.lastGoodConfig;
    if (config === null) {
      this.recoverFailed('无可用采集配置');
      return;
    }
    const occupied = await this.activateAudioSessionGuarded();
    if (occupied) {
      this.recoverFailed('麦克风仍被占用');
      return;
    }
    try {
      await this.audioMgr.stop();
      const started = await this.audioMgr.start(config);
      this.lastGoodConfig = started;
      this.vizMgr.reset();
      MicLogger.info('通话结束，采集已自动恢复');
    } catch (error) {
      const err = error as BusinessError;
      this.recoverFailed(err.message);
    }
  }

  private recoverFailed(detail: string): void {
    MicLogger.error(`通话结束自动恢复失败: ${detail}`);
    this.showToastThrottled('自动恢复失败 · 请回 App 手动重启采集');
    this.stop();
  }

  private showToastThrottled(message: string): void {
    const now = Date.now();
    if (now - this.lastRecoverToastAt < RECOVER_TOAST_THROTTLE_MS) {
      return;
    }
    this.lastRecoverToastAt = now;
    const context = this.context;
    if (context === null) {
      return;
    }
    window.getLastWindow(context)
      .then((mainWin: window.Window): void => {
        mainWin.getUIContext().getPromptAction().showToast({ message: message, duration: 3000, systemMaterial: Mat.toast });
      })
      .catch((error: BusinessError): void => {
        MicLogger.warn(`自动恢复 toast 显示失败: ${error.message}`);
      });
  }

  private handleAudioData(buffer: ArrayBuffer): void {
    const capRate = this.audioMgr.getSamplingRate();
    const capBits = this.audioMgr.getSampleBits();
    const capCh = this.audioMgr.getChannelCount();
    const micMuted = AppStorage.get<boolean>('vizMuted') === true;
    if (micMuted) {
      const sil = this.silenceOf(buffer.byteLength);
      if (this.proNrActive) {
        this.vizMgr.feedPre(buffer, capRate, capBits, capCh);
        this.vizMgr.feedPost(sil, 48000, 16, 1);
      } else {
        this.vizMgr.feedPre(buffer, capRate, capBits, capCh);
        this.vizMgr.feedPost(sil, capRate, capBits, capCh);
      }
      this.tcpMgr.enqueueData(sil);
      return;
    }
    if (this.proNrActive) {
      this.syncPipelineParams(48000);
      this.vizMgr.feedPre(buffer, capRate, capBits, capCh);
      const processed = audioNr.nrProcess(buffer);
      const piped = this.pipeline.process(processed, 48000, 16, 1);
      this.vizMgr.feedPost(piped, 48000, 16, 1);
      if (piped.byteLength > 0) {
        this.tcpMgr.enqueueData(piped);
      }
    } else {
      this.syncPipelineParams(capRate);
      this.vizMgr.feedPre(buffer, capRate, capBits, capCh);
      const piped = this.pipeline.process(buffer, capRate, capBits, capCh);
      this.vizMgr.feedPost(piped, capRate, capBits, capCh);
      this.tcpMgr.enqueueData(piped);
    }
  }

  private syncPipelineParams(sampleRate: number): void {
    this.gainStage.setGainDb(AppStorage.get<number>('cfgGainDb') ?? 0);
    this.limiterStage.setEnabled(AppStorage.get<boolean>('cfgLimiterOn') !== false);
    this.eqStage.setBypass(AppStorage.get<boolean>('cfgEqBypass') !== false);
    this.eqStage.setBands(this.currentEqBands(), sampleRate);
  }

  private async applyLiveConfig(): Promise<void> {
    if (this.isRestarting) {
      this.pendingConfigChange = true;
      return;
    }
    this.isRestarting = true;
    AppStorage.setOrCreate('streamBusy', 'restarting');
    MicLogger.info('运行中调整参数: 重启采集器 (TCP 不断开)');
    try {
      await this.audioMgr.stop();
      const requested = this.buildRequestedConfig();
      let actual = await this.audioMgr.probeConfig(requested);
      if (actual === null) {
        MicLogger.warn('新配置探测失败，回退到最近可用参数');
        actual = this.lastGoodConfig;
      }
      if (actual === null) {
        MicLogger.error('无可用回退配置，停止串流');
        this.isRestarting = false;
        await this.stop();
        return;
      }
      this.refreshNrSupport(actual.source);
      this.tcpMgr.sendReconfig(this.descFromConfig(actual));
      const proNrMode = AppStorage.get<boolean>('cfgProNr') === true;
      if (proNrMode && !this.proNrActive) {
        if (audioNr.nrStart()) {
          this.proNrActive = true;
        } else {
          MicLogger.warn(`DeepFilterNet3 降噪启动失败 [${audioNr.nrGetLastError()}]，本次以原始音频串流`);
        }
      }
      if (!proNrMode && this.proNrActive) {
        audioNr.nrStop();
        this.proNrActive = false;
      }
      const started = await this.audioMgr.start(actual);
      this.lastGoodConfig = started;
      MicLogger.info('参数切换完成');
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.error(`参数切换失败: ${err.message}，尝试回退最近可用参数`);
      const fallback = this.lastGoodConfig;
      if (fallback !== null) {
        try {
          this.tcpMgr.sendReconfig(this.descFromConfig(fallback));
          const restarted = await this.audioMgr.start(fallback);
          this.lastGoodConfig = restarted;
          MicLogger.info('已回退到最近可用参数');
        } catch (fallbackError) {
          const fbErr = fallbackError as BusinessError;
          MicLogger.error(`回退也失败: ${fbErr.message}，停止串流`);
          this.isRestarting = false;
          await this.stop();
          return;
        }
      } else {
        this.isRestarting = false;
        await this.stop();
        return;
      }
    }
    if (!this.sessionActive) {
      const occupied = await this.activateAudioSessionGuarded();
      if (occupied) {
        MicLogger.warn('参数切换后重激活音频会话冲突，保持当前串流 (真实打断将由打断事件兜底)');
      }
    }
    this.isRestarting = false;
    AppStorage.setOrCreate('streamBusy', this.isRunning ? 'running' : 'idle');
    AppStorage.setOrCreate('vizNrActive', this.proNrActive);
    if (this.pendingConfigChange) {
      this.pendingConfigChange = false;
      this.applyLiveConfig();
    }
  }

  private async probeCurrentSource(): Promise<void> {
    if (this.isRunning || this.probing) {
      return;
    }
    if (!PermissionUtil.hasMicrophone()) {
      AppStorage.setOrCreate('probeText', '无麦克风权限，未做全量探测 (启动时自动探测兜底)');
      return;
    }
    this.probing = true;
    AppStorage.setOrCreate('probing', true);
    AppStorage.setOrCreate('probeText', '正在探测设备能力组合...');
    const source = this.currentSourceType();
    const rates: number[] = [16000, 48000];
    const bitsOptions: number[] = [16, 24, 32];
    const channelOptions: number[] = [1, 2];
    let unsupportedCount = 0;
    for (let r = 0; r < 2; r++) {
      for (let b = 0; b < 3; b++) {
        for (let c = 0; c < 2; c++) {
          const requested: CaptureConfig = {
            source: source,
            sampleRate: rates[r],
            sampleBits: bitsOptions[b],
            channels: channelOptions[c],
            noiseReductionChoice: 0
          };
          const actual = await this.audioMgr.probeConfig(requested);
          const matched = actual !== null && actual.sampleRate === rates[r]
            && actual.sampleBits === bitsOptions[b] && actual.channels === channelOptions[c];
          this.supportMatrix[this.comboIndex(r, b, c)] = matched;
          if (!matched) {
            unsupportedCount += 1;
          }
        }
      }
    }
    this.matrixLoaded = true;
    this.lastProbedSource = this.cfgNumber('cfgSource', 0);
    AppStorage.setOrCreate('matrixLoaded', true);
    AppStorage.setOrCreate('supportMatrix', this.supportMatrix.slice());
    this.refreshNrSupport(source);
    if (unsupportedCount === 0) {
      AppStorage.setOrCreate('probeText', '能力检测完成: 全部 12 种组合均支持');
    } else {
      AppStorage.setOrCreate('probeText', `能力检测完成: ${unsupportedCount} 种组合设备不支持 (已禁用)`);
    }
    this.probing = false;
    AppStorage.setOrCreate('probing', false);
  }

  private refreshNrSupport(source: audio.SourceType): void {
    const modes = this.audioMgr.getSupportedNrModes(source);
    if (modes.length === 0) {
      return;
    }
    this.nrSupported[1] = modes.includes(audio.NoiseReductionMode.STANDARD);
    this.nrSupported[2] = modes.includes(audio.NoiseReductionMode.PURE_VOCALS);
    this.nrSupported[3] = modes.includes(audio.NoiseReductionMode.FIDELITY);
    AppStorage.setOrCreate('nrSupported', this.nrSupported.slice());
    MicLogger.info(`降噪选项可用性: STANDARD=${this.nrSupported[1]} PURE_VOCALS=${this.nrSupported[2]} FIDELITY=${this.nrSupported[3]}`);
  }

  private publishStats(): void {
    AppStorage.setOrCreate('statConn', this.stateToText(this.tcpMgr.getState()));
    AppStorage.setOrCreate('statBytes', formatBytes(this.tcpMgr.getTotalBytesSent()));
    AppStorage.setOrCreate('statQueue', `队列 ${this.tcpMgr.getQueueLength()} 块 · 丢弃 ${this.tcpMgr.getDroppedChunks()} 块`);
    AppStorage.setOrCreate('statLog', MicLogger.getRecentText());
    const busy = AppStorage.get<string>('streamBusy');
    let record = '空闲';
    if (busy === 'restarting') {
      record = '切换参数中...';
    } else if (this.isRunning && this.audioMgr.isRunning()) {
      const muted = AppStorage.get<boolean>('vizMuted') === true;
      record =
        `录音中 · ${this.audioMgr.getSamplingRate()}Hz · ${this.audioMgr.getSampleBits()}bit · ${this.audioMgr.getChannelCount()} 声道${this.proNrActive ? ' · DF3降噪' : ''}${muted ? ' · 已静音' : ''}`;
    } else if (this.isRunning) {
      record = '录音中断';
    }
    AppStorage.setOrCreate('statRecord', record);
    this.avSessionSvc.syncMuted(AppStorage.get<boolean>('vizMuted') === true);
    this.avSessionSvc.syncElapsed();
    AppStorage.setOrCreate('statElapsedSec', this.avSessionSvc.getElapsedSec());
    if (this.isRunning) {
      AppStorage.setOrCreate('vizStreaming', this.isRunning && this.audioMgr.isRunning());
      AppStorage.setOrCreate('vizNrActive', this.proNrActive);
    }
    this.sampleTcpQuality();
    this.evaluateQuality();
  }

  private handleNetSnapshot(snapshot: NetSnapshot): void {
    const recovered = this.netSnapshot !== null && !this.netSnapshot.online && snapshot.online;
    this.netSnapshot = snapshot;
    AppStorage.setOrCreate('netOnline', snapshot.online);
    AppStorage.setOrCreate('netBearer', snapshot.bearer);
    if (recovered && this.isRunning && this.tcpMgr.getState() === TcpState.RECONNECT_WAIT) {
      MicLogger.info('网络已恢复，立即触发重连 (退避计数保持)');
      this.tcpMgr.kickReconnect();
    }
  }

  private sampleTcpQuality(): void {
    const metrics = this.tcpMgr.getQualityMetrics();
    const last = this.lastTcpMetrics;
    if (last !== null) {
      const newEnqueued = metrics.enqueuedChunks - last.enqueuedChunks;
      const newDropped = metrics.droppedChunks - last.droppedChunks;
      this.windowDropRate = newEnqueued > 0 ? newDropped / newEnqueued : 0;
    }
    this.windowQueueLevel = metrics.queueLevel;
    this.lastTcpMetrics = metrics;
  }

  private mergedQuality(): string {
    const snapshot = this.netSnapshot;
    let quality: string = snapshot === null ? 'good' : snapshot.quality;
    if (this.isRunning) {
      if (this.windowDropRate >= TCP_DROP_RATE_WEAK || this.windowQueueLevel >= TCP_QUEUE_LEVEL_WEAK) {
        return 'weak';
      }
      if (quality === 'good'
        && (this.windowDropRate >= TCP_DROP_RATE_FAIR || this.windowQueueLevel >= TCP_QUEUE_LEVEL_FAIR)) {
        quality = 'fair';
      }
    }
    return quality;
  }

  private evaluateQuality(): void {
    const merged = this.mergedQuality();
    AppStorage.setOrCreate('netQuality', merged);
    if (!this.isRunning || this.isRestarting) {
      this.weakSince = -1;
      this.goodSince = -1;
      return;
    }
    const now = Date.now();
    if (merged === 'weak') {
      this.goodSince = -1;
      if (this.weakSince < 0) {
        this.weakSince = now;
      }
      if (now - this.weakSince >= WEAK_SUSTAIN_MS && now - this.lastRateActionAt >= RATE_ACTION_MIN_INTERVAL_MS) {
        this.applyWeakAction();
      }
      return;
    }
    this.weakSince = -1;
    if (merged === 'good') {
      if (this.goodSince < 0) {
        this.goodSince = now;
      }
      if (this.rateDowngraded && now - this.goodSince >= GOOD_SUSTAIN_MS
        && now - this.lastRateActionAt >= RATE_ACTION_MIN_INTERVAL_MS) {
        this.recoverRate();
      }
      return;
    }
    this.goodSince = -1;
  }

  private applyWeakAction(): void {
    this.lastRateActionAt = Date.now();
    if (AppStorage.get<boolean>('cfgAutoDowngrade') !== true) {
      MicLogger.info('网络质量: 弱 · 自动降级已关闭，保持当前采样率');
      return;
    }
    if (this.proNrActive) {
      MicLogger.info('网络质量: 弱 · DF3 降噪链固定 48kHz，不做采样率降级');
      return;
    }
    if (this.rateDowngraded || this.currentSampleRate() === 16000) {
      MicLogger.info('网络质量: 弱 · 已是最低档 16kHz');
      return;
    }
    this.rateDowngraded = true;
    AppStorage.setOrCreate('rateDowngraded', true);
    MicLogger.info('网络质量: 弱 · 自动降级 48kHz → 16kHz');
    this.onConfigChanged();
  }

  private recoverRate(): void {
    this.lastRateActionAt = Date.now();
    this.rateDowngraded = false;
    AppStorage.setOrCreate('rateDowngraded', false);
    this.weakSince = -1;
    this.goodSince = -1;
    MicLogger.info('网络质量: 优 · 已升回 48kHz');
    this.onConfigChanged();
  }

  private effectiveSampleRate(): number {
    return this.rateDowngraded ? 16000 : this.currentSampleRate();
  }

  private stateToText(state: TcpState): string {
    if (state === TcpState.CONNECTED) {
      return '已连接';
    }
    if (state === TcpState.CONNECTING) {
      return '连接中...';
    }
    if (state === TcpState.RECONNECT_WAIT) {
      return '等待重连...';
    }
    return '未连接';
  }

  private cfgNumber(key: string, fallback: number): number {
    const value = AppStorage.get<number>(key);
    return value === undefined ? fallback : value;
  }

  private currentSourceType(): audio.SourceType {
    const choice = this.cfgNumber('cfgSource', 0);
    if (choice === 1) {
      return audio.SourceType.SOURCE_TYPE_MIC;
    }
    if (choice === 2) {
      return audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION;
    }
    if (choice === 3) {
      return audio.SourceType.SOURCE_TYPE_VOICE_MESSAGE;
    }
    return audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION;
  }

  private currentSampleRate(): number {
    return this.cfgNumber('cfgRate', 0) === 1 ? 48000 : 16000;
  }

  private currentSampleBits(): number {
    const choice = this.cfgNumber('cfgBits', 0);
    if (choice === 1) {
      return 24;
    }
    if (choice === 2) {
      return 32;
    }
    return 16;
  }

  private currentChannels(): number {
    return this.cfgNumber('cfgChannels', 0) === 1 ? 2 : 1;
  }

  private comboIndex(rateIdx: number, bitsIdx: number, chIdx: number): number {
    return rateIdx * 6 + bitsIdx * 2 + chIdx;
  }

  private buildRequestedConfig(): CaptureConfig {
    const proNrMode = AppStorage.get<boolean>('cfgProNr') === true;
    let sampleBits = this.currentSampleBits();
    // MicYou 模式 32bit 降级：S32LE 整型无对应 MicYou audioFormat（4=PCM float），采集降为 16bit
    if (!proNrMode && sampleBits === 32 && this.getRxKind() === 'micyou') {
      sampleBits = 16;
      MicLogger.info('MicYou 桌面端模式: 32bit 采集已降级为 16bit');
    }
    const config: CaptureConfig = {
      source: this.currentSourceType(),
      sampleRate: proNrMode ? 48000 : this.effectiveSampleRate(),
      sampleBits: proNrMode ? 16 : sampleBits,
      channels: proNrMode ? 1 : this.currentChannels(),
      noiseReductionChoice: this.cfgNumber('cfgNr', 0)
    };
    return config;
  }

  private descFromConfig(config: CaptureConfig): AudioStreamDesc {
    const desc: AudioStreamDesc = {
      sampleRate: config.sampleRate,
      channels: config.channels,
      sampleBits: config.sampleBits
    };
    return desc;
  }

  private silenceOf(byteLength: number): ArrayBuffer {
    if (this.silenceCache.byteLength !== byteLength) {
      this.silenceCache = new ArrayBuffer(byteLength);
    }
    return this.silenceCache;
  }

  private teardownNr(): void {
    if (this.proNrActive) {
      audioNr.nrStop();
      this.proNrActive = false;
      MicLogger.info('DeepFilterNet3 降噪已停止');
    }
  }

  private async activateAudioSessionGuarded(): Promise<boolean> {
    const sessionManager = this.sessionManager;
    if (sessionManager === null) {
      return false;
    }
    const strategy: audio.AudioSessionStrategy = {
      concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_DEFAULT
    };
    try {
      await sessionManager.activateAudioSession(strategy);
      this.sessionActive = true;
      MicLogger.info('音频会话已激活 (并发模式: CONCURRENCY_DEFAULT)');
      return false;
    } catch (error) {
      const err = error as BusinessError;
      if (err.code === AUDIO_SESSION_CONFLICT_CODE) {
        return true;
      }
      MicLogger.warn(`音频会话激活失败 (code=${err.code})，跳过会话管理继续: ${err.message}`);
      return false;
    }
  }

  private async deactivateAudioSessionGuarded(): Promise<void> {
    if (!this.sessionActive || this.sessionManager === null) {
      return;
    }
    try {
      await this.sessionManager.deactivateAudioSession();
      MicLogger.info('音频会话已取消激活');
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`音频会话取消激活失败: ${err.message}`);
    }
    this.sessionActive = false;
  }

  getInputDevices(): audio.AudioDeviceDescriptors {
    const sessionManager = this.sessionManager;
    if (sessionManager === null) {
      return [];
    }
    try {
      return sessionManager.getAvailableDevices(audio.DeviceUsage.MEDIA_INPUT_DEVICES);
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`获取可用输入设备列表失败: ${err.message}`);
      return [];
    }
  }

  getSelectedInputDevice(): audio.AudioDeviceDescriptor | null {
    const sessionManager = this.sessionManager;
    if (sessionManager === null) {
      return null;
    }
    try {
      const device = sessionManager.getSelectedMediaInputDevice();
      if (device.deviceType === audio.DeviceType.INVALID) {
        return null;
      }
      return device;
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`读取已选输入设备失败: ${err.message}`);
      return null;
    }
  }

  async selectInputDevice(device: audio.AudioDeviceDescriptor): Promise<boolean> {
    const sessionManager = this.sessionManager;
    if (sessionManager === null) {
      return false;
    }
    try {
      await sessionManager.selectMediaInputDevice(device);
      MicLogger.info(`已选择输入设备: ${StreamService.inputDeviceLabel(device)}`);
      return true;
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`选择输入设备失败: ${err.message}`);
      return false;
    }
  }

  static inputDeviceLabel(device: audio.AudioDeviceDescriptor): string {
    if (device.displayName.length > 0) {
      return device.displayName;
    }
    if (device.name.length > 0) {
      return device.name;
    }
    return StreamService.deviceTypeText(device.deviceType);
  }

  static deviceTypeText(type: audio.DeviceType): string {
    if (type === audio.DeviceType.MIC) {
      return '内置';
    }
    if (type === audio.DeviceType.BLUETOOTH_A2DP || type === audio.DeviceType.BLUETOOTH_SCO) {
      return '蓝牙';
    }
    if (type === audio.DeviceType.USB_HEADSET) {
      return 'USB';
    }
    if (type === audio.DeviceType.WIRED_HEADSET || type === audio.DeviceType.WIRED_HEADPHONES) {
      return '有线';
    }
    if (type === audio.DeviceType.HEARING_AID) {
      return '助听设备';
    }
    if (type === audio.DeviceType.NEARLINK) {
      return '星闪';
    }
    return '外接';
  }

  static deviceChangeReasonText(reason: audio.AudioStreamDeviceChangeReason): string {
    if (reason === audio.AudioStreamDeviceChangeReason.REASON_NEW_DEVICE_AVAILABLE) {
      return '新设备可用';
    }
    if (reason === audio.AudioStreamDeviceChangeReason.REASON_OLD_DEVICE_UNAVAILABLE) {
      return '旧设备不可用';
    }
    if (reason === audio.AudioStreamDeviceChangeReason.REASON_OVERRODE) {
      return '设备被覆盖';
    }
    if (reason === audio.AudioStreamDeviceChangeReason.REASON_SESSION_ACTIVATED) {
      return '会话激活';
    }
    if (reason === audio.AudioStreamDeviceChangeReason.REASON_STREAM_PRIORITY_CHANGED) {
      return '流优先级变化';
    }
    return '未知原因';
  }

  private handleInputDeviceChanged(event: audio.CurrentInputDeviceChangedEvent): void {
    let label = '';
    const devices = event.devices;
    if (devices.length > 0) {
      label = StreamService.inputDeviceLabel(devices[0]);
    }
    AppStorage.setOrCreate('inputDeviceName', label);
    MicLogger.info(`当前输入设备变更: ${label} (${StreamService.deviceChangeReasonText(event.changeReason)})`);
  }

  private deviceChangeActionText(action: audio.DeviceChangeAction): string {
    const descriptors = action.deviceDescriptors;
    const parts: string[] = [];
    for (let i = 0; i < descriptors.length; i++) {
      parts.push(StreamService.inputDeviceLabel(descriptors[i]));
    }
    const verb = action.type === audio.DeviceChangeType.CONNECT ? '接入' : '断开';
    return `${verb} ${parts.length > 0 ? parts.join('、') : '未知设备'}`;
  }

  private async loadSavedEndpoint(): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      const ipRaw = store.getSync(KEY_PC_IP, '');
      const portRaw = store.getSync(KEY_PC_PORT, '');
      const kindRaw = store.getSync(KEY_RX_KIND, '');
      if (typeof ipRaw === 'string' && ipRaw.length > 0 && isValidIp(ipRaw)) {
        AppStorage.setOrCreate('pcIp', ipRaw);
      }
      if (typeof portRaw === 'string' && portRaw.length > 0 && isValidPort(Number(portRaw))) {
        AppStorage.setOrCreate('pcPort', portRaw);
      }
      if (typeof kindRaw === 'string' && (kindRaw === 'harmonymic' || kindRaw === 'micyou')) {
        AppStorage.setOrCreate('rxKind', kindRaw);
      }
      const ip = AppStorage.get<string>('pcIp');
      if (ip !== undefined && ip.length > 0) {
        MicLogger.info(`已载入上次连接的 PC 端点 ${ip}:${AppStorage.get<string>('pcPort')}`);
      }
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`读取已保存端点失败: ${err.message}`);
    }
  }

  private async saveEndpoint(ip: string, port: string): Promise<void> {
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      store.putSync(KEY_PC_IP, ip);
      store.putSync(KEY_PC_PORT, port);
      await store.flush();
      MicLogger.info(`已记住 PC 端点 ${ip}:${port}`);
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`保存端点失败: ${err.message}`);
    }
  }

  private async startBgTask(): Promise<void> {
    const context = this.context;
    if (context === undefined || context === null) {
      MicLogger.error('无法获取上下文，长时任务未启动');
      return;
    }
    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: BUNDLE_NAME,
          abilityName: ABILITY_NAME
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(context, ['audioRecording'], agent);
      this.bgTaskRunning = true;
      MicLogger.info('长时任务已启动 (audioRecording)，退后台录音不中断');
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.error(`长时任务启动失败: code=${err.code} ${err.message}`);
    }
  }

  private async stopBgTask(): Promise<void> {
    if (!this.bgTaskRunning) {
      return;
    }
    const context = this.context;
    if (context === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      MicLogger.info('长时任务已取消');
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`取消长时任务失败: ${err.message}`);
    }
    this.bgTaskRunning = false;
  }
}
