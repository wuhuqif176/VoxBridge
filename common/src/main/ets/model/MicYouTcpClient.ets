// MicYou 桌面端兼容 TCP 客户端：协议见 MicYouProto.ets 头注。
// 独立类复制 TcpClientManager 已验证的队列/重连退避/指标骨架（不继承——
// protected 钩子会改动已部署验证的 pc-receiver 路径，代码重复为有意取舍）。
// 差异点：①connect 内完成 MicYouCheck1/2 裸字节握手（12 字节精确比对，5s 超时）
// ②发送帧=8B 大端头+protobuf MessageWrapper（序列号从 0 起，legacy 首包绑定 0..4）
// ③无配置帧：音频参数随每包元数据自适应，sendReconfig 为 no-op
// ④订阅 socket 'message' 全程抽干入站（防对端 Mute/Ping 写阻塞；仅计数不解析）。
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MicLogger } from '../utils/Logger';
import { AudioTcpSender } from './AudioTcpSender';
import { TcpState, AudioStreamDesc, TcpQualityMetrics } from './TcpClientManager';
import {
  MICYOU_AUDIO_FORMAT_PCM16,
  MICYOU_HANDSHAKE_LEN,
  micYouHandshakeRequestBytes,
  micYouIsHandshakeResponse,
  micYouAudioFormatFromBits,
  micYouEncodeAudioPacketMessage,
  micYouBuildFrame
} from './MicYouProto';

interface SendChunk {
  payload: ArrayBuffer;
}

export class MicYouTcpClient implements AudioTcpSender {
  private tcpSocket: socket.TCPSocket | null = null;
  private currentState: TcpState = TcpState.DISCONNECTED;
  private serverIp: string = '';
  private serverPort: number = 0;
  private autoReconnect: boolean = false;
  private reconnectAttempts: number = 0;
  private sendQueue: SendChunk[] = [];
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
  // MicYou 特有状态
  private rxPhase: number = 0; // 0=握手期, 1=抽干期
  private rxBuffer: Uint8Array = new Uint8Array(64);
  private rxLen: number = 0;
  private handshakeResolve: (() => void) | null = null;
  private handshakeReject: ((err: Error) => void) | null = null;
  private handshakeTimerId: number = -1;
  private sequenceNumber: number = 0;
  private inboundDrained: number = 0;
  private descSampleRate: number = 48000;
  private descChannels: number = 1;
  private descAudioFormat: number = MICYOU_AUDIO_FORMAT_PCM16;

  private static readonly MAX_RECONNECT_ATTEMPTS: number = 8;
  private static readonly MAX_BATCH_BYTES: number = 32768;
  private static readonly CONNECT_TIMEOUT_MS: number = 5000;
  private static readonly HANDSHAKE_TIMEOUT_MS: number = 5000;
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
    this.applyDesc(desc);
    this.reconnectAttempts = 0;
    this.droppedChunks = 0;
    this.enqueuedChunks = 0;
    this.reconnectTotal = 0;
    this.totalBytesSent = 0;
    this.bufferedBytes = 0;
    this.inboundDrained = 0;
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

  // MicYou 协议无配置帧：音频参数（采样率/声道/格式）随每包 protobuf 元数据自适应，
  // 桌面端按包校验并即时切换，无需重发配置。
  sendReconfig(desc: AudioStreamDesc): void {
    this.applyDesc(desc);
    MicLogger.info(`[MicYou] 参数切换 ${desc.sampleRate}Hz/${desc.sampleBits}bit/${desc.channels}ch（随包元数据生效）`);
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
    this.sendQueue.push({ payload: buffer });
    this.bufferedBytes += buffer.byteLength;
    this.drainQueue();
  }

  private applyDesc(desc: AudioStreamDesc): void {
    this.maxBufferedBytes = Math.max(8192,
      Math.floor(desc.sampleRate * desc.channels * (desc.sampleBits / 8) * MicYouTcpClient.MAX_LATENCY_MS / 1000));
    this.descSampleRate = desc.sampleRate;
    this.descChannels = desc.channels;
    this.descAudioFormat = micYouAudioFormatFromBits(desc.sampleBits);
    if (desc.sampleBits === 32) {
      MicLogger.warn('[MicYou] 32bit S32LE 无对应 MicYou 格式（4=float32），已按 PCM16 标记发送，实际 PCM 须已降为 16bit');
    }
  }

  private async createAndConnect(): Promise<void> {
    this.cleanupSocket();
    this.rxPhase = 0;
    this.rxLen = 0;
    this.sequenceNumber = 0; // legacy 流序列号从 0 重起（首包 0..4 才能绑定会话）
    this.setState(TcpState.CONNECTING, `正在连接 ${this.serverIp}:${this.serverPort}`);
    this.tcpSocket = socket.constructTCPSocketInstance();
    this.registerSocketEvents();
    await this.tcpSocket.connect({
      address: { address: this.serverIp, port: this.serverPort },
      timeout: MicYouTcpClient.CONNECT_TIMEOUT_MS
    });
    await this.applySocketOptions();
    const reqBytes = micYouHandshakeRequestBytes();
    await this.tcpSocket.send({ data: reqBytes.buffer });
    // 等待握手响应（'message' 事件累积 12 字节精确比对；close/error/超时经 reject 打断）
    await new Promise<void>((resolve: () => void, reject: (reason: Error) => void) => {
      this.handshakeResolve = resolve;
      this.handshakeReject = reject;
      this.handshakeTimerId = setTimeout(() => {
        this.failHandshake(new Error(`MicYou 握手超时(${MicYouTcpClient.HANDSHAKE_TIMEOUT_MS}ms)`));
      }, MicYouTcpClient.HANDSHAKE_TIMEOUT_MS);
    });
    this.reconnectAttempts = 0;
    this.setState(TcpState.CONNECTED, `已连接 ${this.serverIp}:${this.serverPort} (MicYou)`);
  }

  private applySocketOptions(): Promise<void> {
    const sock = this.tcpSocket;
    if (sock === null) {
      return Promise.resolve();
    }
    return sock.setExtraOptions({
      TCPNoDelay: true,
      sendBufferSize: MicYouTcpClient.SEND_BUFFER_SIZE,
      receiveBufferSize: MicYouTcpClient.SEND_BUFFER_SIZE
    }).then(() => {
      MicLogger.info('[MicYou] Socket 选项已设置: TCPNoDelay + 256KB 缓冲');
    }).catch((error: BusinessError) => {
      MicLogger.warn(`[MicYou] 设置 Socket 选项失败(降级为默认): ${error.message}`);
    });
  }

  private registerSocketEvents(): void {
    const sock = this.tcpSocket;
    if (sock === null) {
      return;
    }
    sock.on('close', () => {
      MicLogger.warn('[MicYou] TCP 连接被对端关闭');
      this.lastError = '连接被对端关闭';
      this.handleSessionDropped();
    });
    sock.on('error', (err: BusinessError) => {
      MicLogger.error(`[MicYou] TCP 异常: code=${err.code} ${err.message}`);
      this.lastError = `code=${err.code} ${err.message}`;
      this.handleSessionDropped();
    });
    sock.on('message', (info: socket.SocketMessageInfo) => {
      this.handleInbound(info.message);
    });
  }

  private handleInbound(data: ArrayBuffer): void {
    const incoming = new Uint8Array(data);
    if (this.rxPhase === 0) {
      this.appendRx(incoming);
      if (this.rxLen >= MICYOU_HANDSHAKE_LEN) {
        if (micYouIsHandshakeResponse(this.rxBuffer, MICYOU_HANDSHAKE_LEN)) {
          this.completeHandshake();
        } else {
          this.failHandshake(new Error('MicYou 握手响应不匹配'));
        }
      }
      return;
    }
    // 握手完成后抽干入站（Mute/Ping/Pong 等不处理，仅防对端写阻塞）
    this.inboundDrained += incoming.length;
  }

  private appendRx(incoming: Uint8Array): void {
    const need = this.rxLen + incoming.length;
    if (need > this.rxBuffer.length) {
      const grown = new Uint8Array(Math.max(need, this.rxBuffer.length * 2));
      grown.set(this.rxBuffer.subarray(0, this.rxLen), 0);
      this.rxBuffer = grown;
    }
    this.rxBuffer.set(incoming, this.rxLen);
    this.rxLen += incoming.length;
  }

  private completeHandshake(): void {
    this.rxPhase = 1;
    this.rxLen = 0;
    if (this.handshakeTimerId !== -1) {
      clearTimeout(this.handshakeTimerId);
      this.handshakeTimerId = -1;
    }
    const waiter = this.handshakeResolve;
    this.handshakeResolve = null;
    this.handshakeReject = null;
    if (waiter !== null) {
      waiter();
    }
  }

  private failHandshake(err: Error): void {
    if (this.handshakeTimerId !== -1) {
      clearTimeout(this.handshakeTimerId);
      this.handshakeTimerId = -1;
    }
    const failer = this.handshakeReject;
    this.handshakeResolve = null;
    this.handshakeReject = null;
    this.rxPhase = 0;
    this.rxLen = 0;
    // 超时/响应不匹配时 socket 仍开启：先关再 reject（reject 触发 createAndConnect 抛错走既有重连路径）
    this.cleanupSocket();
    if (failer !== null) {
      failer(err);
    }
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
    if (this.reconnectAttempts >= MicYouTcpClient.MAX_RECONNECT_ATTEMPTS) {
      this.autoReconnect = false;
      this.setState(TcpState.DISCONNECTED,
        `重连 ${MicYouTcpClient.MAX_RECONNECT_ATTEMPTS} 次均失败，已停止 (${this.lastError})`);
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
      MicLogger.info('[MicYou] 重连成功，继续传输');
    } catch (error) {
      const err = error as BusinessError;
      this.lastError = `code=${err.code} ${err.message}`;
      MicLogger.error(`[MicYou] 重连失败: ${this.lastError}`);
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
    const payload = this.mergeQueue();
    if (payload.byteLength === 0) {
      return;
    }
    const protobuf = micYouEncodeAudioPacketMessage(payload, this.descSampleRate, this.descChannels,
      this.descAudioFormat, this.sequenceNumber, Date.now());
    this.sequenceNumber += 1;
    const wire = micYouBuildFrame(protobuf);
    this.isSending = true;
    sock.send({ data: wire }).then(() => {
      this.isSending = false;
      this.totalBytesSent += payload.byteLength;
      if (this.sendQueue.length > 0) {
        this.drainQueue();
      }
    }).catch((error: BusinessError) => {
      this.isSending = false;
      this.lastError = `code=${error.code} ${error.message}`;
      MicLogger.error(`[MicYou] 发送失败: ${this.lastError}`);
      this.handleSessionDropped();
    });
  }

  private mergeQueue(): ArrayBuffer {
    let bytes = 0;
    const chunks: ArrayBuffer[] = [];
    while (this.sendQueue.length > 0 && bytes < MicYouTcpClient.MAX_BATCH_BYTES) {
      const chunk = this.sendQueue.shift();
      if (chunk === undefined) {
        break;
      }
      chunks.push(chunk.payload);
      bytes += chunk.payload.byteLength;
    }
    this.bufferedBytes -= bytes;
    const merged = new ArrayBuffer(bytes);
    const view = new Uint8Array(merged);
    let offset = 0;
    for (const chunk of chunks) {
      view.set(new Uint8Array(chunk), offset);
      offset += chunk.byteLength;
    }
    return merged;
  }

  private cleanupSocket(): void {
    const sock = this.tcpSocket;
    this.tcpSocket = null;
    this.isSending = false;
    if (this.handshakeTimerId !== -1) {
      clearTimeout(this.handshakeTimerId);
      this.handshakeTimerId = -1;
    }
    if (this.handshakeReject !== null) {
      // 连接关闭/断开打断等待中的握手（防 connect() 挂起）
      const failer = this.handshakeReject;
      this.handshakeResolve = null;
      this.handshakeReject = null;
      failer(new Error('连接已关闭（握手未完成）'));
    }
    if (sock !== null) {
      sock.off('close');
      sock.off('error');
      sock.off('message');
      sock.close().catch((error: BusinessError) => {
        MicLogger.warn(`[MicYou] 关闭 socket 异常: ${error.message}`);
      });
    }
  }

  private setState(state: TcpState, detail: string): void {
    this.currentState = state;
    MicLogger.info(`[MicYou TCP] ${detail}`);
    if (this.onStateChanged !== null) {
      this.onStateChanged(state, detail);
    }
  }
}
