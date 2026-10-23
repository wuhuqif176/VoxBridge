// TCP 发送端抽象：HarmonyMic 自有协议（TcpClientManager，TCP 9000 小端帧）
// 与 MicYou 桌面端兼容协议（MicYouTcpClient，TCP 9123 大端帧+protobuf）共用同一公开面，
// StreamService 按 rxKind 选择实现，消费方代码零感知。
import { TcpState, AudioStreamDesc, TcpQualityMetrics } from './TcpClientManager';

export interface AudioTcpSender {
  onStateChanged: ((state: TcpState, detail: string) => void) | null;
  connect(ip: string, port: number, desc: AudioStreamDesc): Promise<void>;
  disconnect(): void;
  kickReconnect(): void;
  enqueueData(buffer: ArrayBuffer): void;
  sendReconfig(desc: AudioStreamDesc): void;
  getState(): TcpState;
  getTotalBytesSent(): number;
  getQueueLength(): number;
  getDroppedChunks(): number;
  getLastError(): string;
  getQualityMetrics(): TcpQualityMetrics;
}
