import { common } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MicLogger } from 'common';

const AV_SESSION_TAG = 'HarmonyMicLive';
const AV_ASSET_ID = 'harmonymic-live';

export class AvSessionService {
  private session: avSession.AVSession | null = null;
  private endpoint: string = '';
  private activatedAtMs: number = 0;
  private lastElapsedSec: number = -1;
  private lastMuted: boolean | null = null;
  onToggleMute: ((muted: boolean) => void) | null = null;
  onStopStream: (() => void) | null = null;

  async start(context: common.UIAbilityContext, endpoint: string, muted: boolean): Promise<boolean> {
    if (this.session !== null) {
      return true;
    }
    try {
      const session = await avSession.createAVSession(context, AV_SESSION_TAG, 'audio');
      this.session = session;
      this.endpoint = endpoint;
      this.activatedAtMs = Date.now();
      this.lastElapsedSec = 0;
      this.lastMuted = null;
      session.on('play', (): void => {
        this.emitToggleMute(false);
      });
      session.on('pause', (): void => {
        this.emitToggleMute(true);
      });
      session.on('stop', (): void => {
        this.emitStop();
      });
      await this.applyMetadata();
      await this.applyPlaybackState(muted);
      this.lastMuted = muted;
      await session.activate();
      MicLogger.info(`锁屏媒体会话已激活: ${endpoint}`);
      return true;
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`锁屏媒体会话创建失败 (code=${err.code}): ${err.message}`);
      const pending = this.session;
      this.session = null;
      if (pending !== null) {
        try {
          await pending.destroy();
        } catch (destroyError) {
          const derr = destroyError as BusinessError;
          MicLogger.warn(`回滚销毁媒体会话失败 (code=${derr.code}): ${derr.message}`);
        }
      }
      return false;
    }
  }

  async stop(): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    this.session = null;
    this.lastMuted = null;
    this.lastElapsedSec = -1;
    try {
      await session.destroy();
      MicLogger.info('锁屏媒体会话已销毁');
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`锁屏媒体会话销毁失败 (code=${err.code}): ${err.message}`);
    }
  }

  syncMuted(muted: boolean): void {
    if (this.session === null || this.lastMuted === muted) {
      return;
    }
    this.lastMuted = muted;
    this.applyPlaybackState(muted);
  }

  syncElapsed(): void {
    if (this.session === null) {
      return;
    }
    const elapsedSec = Math.floor((Date.now() - this.activatedAtMs) / 1000);
    if (elapsedSec === this.lastElapsedSec) {
      return;
    }
    this.lastElapsedSec = elapsedSec;
    this.applyMetadata();
  }

  // 说明: 直播页时长展示数据源（mm:ss 格式化由消费方完成）；会话未激活时返回 0。
  getElapsedSec(): number {
    if (this.session === null || this.activatedAtMs === 0) {
      return 0;
    }
    return Math.max(0, Math.floor((Date.now() - this.activatedAtMs) / 1000));
  }

  private async applyMetadata(): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    const metadata: avSession.AVMetadata = {
      assetId: AV_ASSET_ID,
      title: 'VoxBridge',
      artist: `直播中 → ${this.endpoint}`,
      subtitle: this.endpoint,
      duration: Math.max(0, this.lastElapsedSec) * 1000
    };
    try {
      await session.setAVMetadata(metadata);
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`锁屏元数据同步失败: ${err.message}`);
    }
  }

  private async applyPlaybackState(muted: boolean): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    const state: avSession.AVPlaybackState = {
      state: muted ? avSession.PlaybackState.PLAYBACK_STATE_PAUSE : avSession.PlaybackState.PLAYBACK_STATE_PLAY
    };
    try {
      await session.setAVPlaybackState(state);
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`锁屏播放状态同步失败: ${err.message}`);
    }
  }

  private emitToggleMute(muted: boolean): void {
    if (this.onToggleMute !== null) {
      this.onToggleMute(muted);
    }
  }

  private emitStop(): void {
    if (this.onStopStream !== null) {
      this.onStopStream();
    }
  }
}
