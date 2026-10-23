import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MicLogger } from '../utils/Logger';
import { AudioTcpSender } from './AudioTcpSender';

export enum TcpState {
  DISCONNECTED = 0,
  CONNECTING = 1,
  CONNECTED = 2,
  RECONNECT_WAIT = 3
}

export interface AudioStreamDesc {
  sampleRate: number;
  channels: number;
  sampleBits: number;
}

// 说明: TCP 侧质量指标快照（F4 口径）：queueLevel=当前水位 0..1；enqueuedChunks/droppedChunks/reconnectCount
// 为自 connect() 起的累计值，消费方（StreamService）用采样差值算窗口化丢弃率。
export interface TcpQualityMetrics {
  state: TcpState;
  queueLevel: number;
  enqueuedChunks: number;
  droppedChunks: number;
  reconnectCount: number;
}

interface SendFrame {
  frameType: number;
  payload: ArrayBuffer;
}

const FRAME_TYPE_CONFIG = 1;
const FRAME_TYPE_PCM = 2;
const FRAME_PREFIX_LEN = 5;
const PROTOCOL_VERSION = 1;

export class TcpClientManager implements AudioTcpSender {
  private tcpSocket: socket.TCPSocket | null = null;
  private currentState: TcpState = TcpState.DISCONNECTED;
  private serverIp: string = '';
  private serverPort: number = 0;
  private streamDesc: AudioStreamDesc | null = null;
  private autoReconnect: boolean = false;
  private reconnectAttempts: number = 0;
  private sendQueue: SendFrame[] = [];
  private bufferedBytes: number = 0;
  private maxBufferedBytes: number = 8192;
  private isSending: boolean = false;
  private totalBytesSent: number = 0;
  private droppedChunks: number = 0;
  private enqueuedChunks: number = 0;
  private reconnectTotal: number = 0;
  private lastError: string = '';
  private reconnectTimerId: number = -1;
  public onStateChanged: ((state: TcpState, detail: string) => void) | null = null;

  private static readonly MAX_RECONNECT_ATTEMPTS: number = 8;
  private static readonly MAX_BATCH_BYTES: number = 32768;
  private static readonly CONNECT_TIMEOUT_MS: number = 5000;
  private static readonly MAX_LATENCY_MS: number = 250;
  private static readonly SEND_BUFFER_SIZE: number = 262144;

  getState(): TcpState {
    return this.currentState;
  }

  getTotalBytesSent(): number {
    return this.totalBytesSent;
  }

  getQueueLength(): number {
    return this.sendQueue.length;
  }

  getDroppedChunks(): number {
    return this.droppedChunks;
  }

  getLastError(): string {
    return this.lastError;
  }

  getQualityMetrics(): TcpQualityMetrics {
    const level = this.maxBufferedBytes > 0 ? this.bufferedBytes / this.maxBufferedBytes : 0;
    return {
      state: this.currentState,
      queueLevel: level,
      enqueuedChunks: this.enqueuedChunks,
      droppedChunks: this.droppedChunks,
      reconnectCount: this.reconnectTotal
    };
  }

  // 说明: 网络恢复等场景立即触发一次重连：仅清掉等待定时器立即执行，
  // 重连次数仍按原节奏累计（不清 8 次上限与延迟序列，退避策略本体保持）。
  kickReconnect(): void {
    if (this.currentState !== TcpState.RECONNECT_WAIT) {
      return;
    }
    if (this.reconnectTimerId !== -1) {
      clearTimeout(this.reconnectTimerId);
      this.reconnectTimerId = -1;
    }
    this.reconnectInternal();
  }

  async connect(ip: string, port: number, desc: AudioStreamDesc): Promise<void> {
    this.serverIp = ip;
    this.serverPort = port;
    this.streamDesc = desc;
    this.applyDesc(desc);
    this.reconnectAttempts = 0;
    this.droppedChunks = 0;
    this.enqueuedChunks = 0;
    this.reconnectTotal = 0;
    this.totalBytesSent = 0;
    this.bufferedBytes = 0;
    this.lastError = '';
    this.autoReconnect = true;
    try {
      await this.createAndConnect();
    } catch (error) {
      const err = error as BusinessError;
      this.autoReconnect = false;
      this.setState(TcpState.DISCONNECTED, `连接 ${ip}:${port} 失败`);
      throw new Error(`connect failed: code=${err.code} ${err.message}`);
    }
  }

  sendReconfig(desc: AudioStreamDesc): void {
    this.streamDesc = desc;
    this.applyDesc(desc);
    if (this.currentState !== TcpState.CONNECTED) {
      MicLogger.warn('[TCP] 未连接，新参数将在下次连接时生效');
      return;
    }
    this.sendQueue.push({ frameType: FRAME_TYPE_CONFIG, payload: this.buildConfigPayload(desc) });
    MicLogger.info(`[TCP] 已发送参数切换帧: ${desc.sampleRate}Hz/${desc.sampleBits}bit/${desc.channels}ch`);
    this.drainQueue();
  }

  disconnect(): void {
    this.autoReconnect = false;
    if (this.reconnectTimerId !== -1) {
      clearTimeout(this.reconnectTimerId);
      this.reconnectTimerId = -1;
    }
    this.sendQueue = [];
    this.bufferedBytes = 0;
    this.cleanupSocket();
    this.setState(TcpState.DISCONNECTED, '已主动断开');
  }

  enqueueData(buffer: ArrayBuffer): void {
    this.enqueuedChunks += 1;
    if (this.currentState !== TcpState.CONNECTED) {
      this.droppedChunks += 1;
      return;
    }
    while (this.bufferedBytes + buffer.byteLength > this.maxBufferedBytes && this.sendQueue.length > 0) {
      const oldest = this.sendQueue.shift();
      if (oldest !== undefined) {
        this.bufferedBytes -= oldest.payload.byteLength;
        this.droppedChunks += 1;
      }
    }
    if (this.bufferedBytes + buffer.byteLength > this.maxBufferedBytes) {
      this.droppedChunks += 1;
      return;
    }
    this.sendQueue.push({ frameType: FRAME_TYPE_PCM, payload: buffer });
    this.bufferedBytes += buffer.byteLength;
    this.drainQueue();
  }

  private applyDesc(desc: AudioStreamDesc): void {
    this.maxBufferedBytes = Math.max(8192,
      Math.floor(desc.sampleRate * desc.channels * (desc.sampleBits / 8) * TcpClientManager.MAX_LATENCY_MS / 1000));
  }

  private buildConfigPayload(desc: AudioStreamDesc): ArrayBuffer {
    const payload = new ArrayBuffer(7);
    const view = new DataView(payload);
    view.setUint8(0, PROTOCOL_VERSION);
    view.setUint32(1, desc.sampleRate, true);
    view.setUint8(5, desc.channels);
    view.setUint8(6, desc.sampleBits);
    return payload;
  }

  private buildFrame(frame: SendFrame): ArrayBuffer {
    const wire = new ArrayBuffer(FRAME_PREFIX_LEN + frame.payload.byteLength);
    const view = new DataView(wire);
    view.setUint8(0, frame.frameType);
    view.setUint32(1, frame.payload.byteLength, true);
    const bytes = new Uint8Array(wire);
    bytes.set(new Uint8Array(frame.payload), FRAME_PREFIX_LEN);
    return wire;
  }

  private async createAndConnect(): Promise<void> {
    this.cleanupSocket();
    this.setState(TcpState.CONNECTING, `正在连接 ${this.serverIp}:${this.serverPort}`);
    this.tcpSocket = socket.constructTCPSocketInstance();
    this.registerSocketEvents();
    await this.tcpSocket.connect({
      address: { address: this.serverIp, port: this.serverPort },
      timeout: TcpClientManager.CONNECT_TIMEOUT_MS
    });
    await this.applySocketOptions();
    this.reconnectAttempts = 0;
    this.setState(TcpState.CONNECTED, `已连接 ${this.serverIp}:${this.serverPort}`);
    const desc = this.streamDesc;
    if (desc !== null) {
      this.sendQueue.push({ frameType: FRAME_TYPE_CONFIG, payload: this.buildConfigPayload(desc) });
      this.drainQueue();
    }
  }

  private async applySocketOptions(): Promise<void> {
    const sock = this.tcpSocket;
    if (sock === null) {
      return;
    }
    try {
      await sock.setExtraOptions({
        TCPNoDelay: true,
        sendBufferSize: TcpClientManager.SEND_BUFFER_SIZE,
        receiveBufferSize: TcpClientManager.SEND_BUFFER_SIZE
      });
      MicLogger.info('Socket 选项已设置: TCPNoDelay + 256KB 缓冲');
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`设置 Socket 选项失败(降级为默认): ${err.message}`);
    }
  }

  private registerSocketEvents(): void {
    const sock = this.tcpSocket;
    if (sock === null) {
      return;
    }
    sock.on('close', () => {
      MicLogger.warn('TCP 连接被对端关闭');
      this.lastError = '连接被对端关闭';
      this.handleSessionDropped();
    });
    sock.on('error', (err: BusinessError) => {
      MicLogger.error(`TCP 异常: code=${err.code} ${err.message}`);
      this.lastError = `code=${err.code} ${err.message}`;
      this.handleSessionDropped();
    });
  }

  private handleSessionDropped(): void {
    if (this.currentState === TcpState.DISCONNECTED || this.currentState === TcpState.RECONNECT_WAIT) {
      return;
    }
    this.cleanupSocket();
    if (!this.autoReconnect) {
      this.setState(TcpState.DISCONNECTED, this.lastError);
      return;
    }
    this.scheduleReconnect();
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimerId !== -1) {
      return;
    }
    if (!this.autoReconnect) {
      return;
    }
    if (this.reconnectAttempts >= TcpClientManager.MAX_RECONNECT_ATTEMPTS) {
      this.autoReconnect = false;
      this.setState(TcpState.DISCONNECTED,
        `重连 ${TcpClientManager.MAX_RECONNECT_ATTEMPTS} 次均失败，已停止 (${this.lastError})`);
      return;
    }
    this.reconnectAttempts += 1;
    this.reconnectTotal += 1;
    const delayMs = Math.min(1000 * this.reconnectAttempts, 5000);
    this.setState(TcpState.RECONNECT_WAIT,
      `连接中断，${delayMs / 1000}s 后进行第 ${this.reconnectAttempts} 次重连`);
    this.reconnectTimerId = setTimeout(() => {
      this.reconnectTimerId = -1;
      this.reconnectInternal();
    }, delayMs);
  }

  private async reconnectInternal(): Promise<void> {
    if (!this.autoReconnect) {
      return;
    }
    this.setState(TcpState.CONNECTING, `正在重连 ${this.serverIp}:${this.serverPort}`);
    try {
      await this.createAndConnect();
      MicLogger.info('重连成功，继续传输');
    } catch (error) {
      const err = error as BusinessError;
      this.lastError = `code=${err.code} ${err.message}`;
      MicLogger.error(`重连失败: ${this.lastError}`);
      this.scheduleReconnect();
    }
  }

  private drainQueue(): void {
    if (this.isSending || this.currentState !== TcpState.CONNECTED || this.tcpSocket === null) {
      return;
    }
    if (this.sendQueue.length === 0) {
      return;
    }
    const sock = this.tcpSocket;
    const frame = this.mergeQueue();
    if (frame.payload.byteLength === 0) {
      return;
    }
    const wire = this.buildFrame(frame);
    this.isSending = true;
    sock.send({ data: wire }).then(() => {
      this.isSending = false;
      this.totalBytesSent += frame.payload.byteLength;
      if (this.sendQueue.length > 0) {
        this.drainQueue();
      }
    }).catch((error: BusinessError) => {
      this.isSending = false;
      this.lastError = `code=${error.code} ${error.message}`;
      MicLogger.error(`发送失败: ${this.lastError}`);
      this.handleSessionDropped();
    });
  }

  private mergeQueue(): SendFrame {
    const head = this.sendQueue[0];
    if (head === undefined) {
      return { frameType: FRAME_TYPE_PCM, payload: new ArrayBuffer(0) };
    }
    if (head.frameType === FRAME_TYPE_CONFIG) {
      const configFrame = this.sendQueue.shift();
      if (configFrame !== undefined) {
        this.bufferedBytes -= configFrame.payload.byteLength;
        return configFrame;
      }
    }
    let bytes = 0;
    const chunks: ArrayBuffer[] = [];
    while (this.sendQueue.length > 0 && this.sendQueue[0].frameType === FRAME_TYPE_PCM
      && bytes < TcpClientManager.MAX_BATCH_BYTES) {
      const frame = this.sendQueue.shift();
      if (frame === undefined) {
        break;
      }
      chunks.push(frame.payload);
      bytes += frame.payload.byteLength;
    }
    this.bufferedBytes -= bytes;
    const merged = new ArrayBuffer(bytes);
    const view = new Uint8Array(merged);
    let offset = 0;
    for (const chunk of chunks) {
      view.set(new Uint8Array(chunk), offset);
      offset += chunk.byteLength;
    }
    return { frameType: FRAME_TYPE_PCM, payload: merged };
  }

  private cleanupSocket(): void {
    const sock = this.tcpSocket;
    this.tcpSocket = null;
    this.isSending = false;
    if (sock !== null) {
      sock.off('close');
      sock.off('error');
      sock.close().catch((error: BusinessError) => {
        MicLogger.warn(`关闭 socket 异常: ${error.message}`);
      });
    }
  }

  private setState(state: TcpState, detail: string): void {
    this.currentState = state;
    MicLogger.info(`[TCP] ${detail}`);
    if (this.onStateChanged !== null) {
      this.onStateChanged(state, detail);
    }
  }
}
