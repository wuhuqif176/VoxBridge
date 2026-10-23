// MicYou 桌面端兼容协议纯编码层（无 IO）。
// 协议真源：MicYou-master tauri-app/crates/micyou-protocol/src/lib.rs + proto/network.proto
// + micyou-core/src/transport/{tcp,session}.rs。
// 帧格式：8 字节大端头 [magic i32 BE = 0x4D696359 "MicY"][payload_len i32 BE] + protobuf MessageWrapper。
// 注意：帧头为大端（本项目自有协议 9000 端口为小端，勿混淆）。

export const MICYOU_DEFAULT_PORT: number = 9123;
export const MICYOU_PACKET_MAGIC: number = 0x4D696359; // "MicY"
export const MICYOU_CODEC_PCM: number = 0;
export const MICYOU_AUDIO_FORMAT_PCM16: number = 2; // PCM 16-bit（2 字节/样本）
export const MICYOU_AUDIO_FORMAT_PCM24: number = 6; // PCM 24-bit（3 字节/样本，与 S24LE 打包一致）
export const MICYOU_HANDSHAKE_REQ: string = 'MicYouCheck1';
export const MICYOU_HANDSHAKE_RESP: string = 'MicYouCheck2';
export const MICYOU_HANDSHAKE_LEN: number = 12;

// protobuf 字段号（network.proto 核实，勿凭记忆改）：
// MessageWrapper.audioPacket = 1；AudioPacketMessageOrdered{ sequenceNumber=1, audioPacket=2, timestamp=3 }
// AudioPacketMessage{ buffer=1, sampleRate=2, channelCount=3, audioFormat=4, codec=5 }
// codec=0(PCM)/fec 系列/sessionId 按 proto3 默认值省略不发。

class MicYouProtoWriter {
  private data: Uint8Array;
  private pos: number = 0;

  constructor(capacity: number) {
    this.data = new Uint8Array(capacity);
  }

  writeByte(byte: number): void {
    this.data[this.pos] = byte & 0xFF;
    this.pos += 1;
  }

  writeVarint(value: number): void {
    let v = Math.floor(value);
    while (v >= 0x80) {
      this.writeByte((v % 128) + 128);
      v = Math.floor(v / 128);
    }
    this.writeByte(v);
  }

  writeVarintField(fieldNo: number, value: number): void {
    this.writeByte((fieldNo << 3) | 0);
    this.writeVarint(value);
  }

  writeLenDelimitedHeader(fieldNo: number, len: number): void {
    this.writeByte((fieldNo << 3) | 2);
    this.writeVarint(len);
  }

  writeRaw(bytes: Uint8Array): void {
    this.data.set(bytes, this.pos);
    this.pos += bytes.length;
  }

  toUint8Array(): Uint8Array {
    return this.data.slice(0, this.pos);
  }
}

function micYouVarintLen(value: number): number {
  let n = 1;
  let v = Math.floor(value);
  while (v >= 0x80) {
    v = Math.floor(v / 128);
    n += 1;
  }
  return n;
}

function micYouAsciiBytes(text: string): Uint8Array {
  const out = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    out[i] = text.charCodeAt(i) & 0x7F;
  }
  return out;
}

// 握手请求字节（客户端 → 桌面端，裸 TCP 字节非 protobuf）。
export function micYouHandshakeRequestBytes(): Uint8Array {
  return micYouAsciiBytes(MICYOU_HANDSHAKE_REQ);
}

// 判断累积到的入站字节是否为握手响应（12 字节精确比对）。
export function micYouIsHandshakeResponse(data: Uint8Array, length: number): boolean {
  if (length !== MICYOU_HANDSHAKE_LEN) {
    return false;
  }
  for (let i = 0; i < MICYOU_HANDSHAKE_LEN; i++) {
    if (data[i] !== (MICYOU_HANDSHAKE_RESP.charCodeAt(i) & 0x7F)) {
      return false;
    }
  }
  return true;
}

// 采样位深 → MicYou audioFormat：16→2(PCM16)、24→6(PCM24)；
// 32bit 为 S32LE 整型，MicYou 无对应格式（4=PCM float），降级按 16bit 发（调用方须保证实际 PCM 已降为 16bit）。
export function micYouAudioFormatFromBits(sampleBits: number): number {
  if (sampleBits === 24) {
    return MICYOU_AUDIO_FORMAT_PCM24;
  }
  return MICYOU_AUDIO_FORMAT_PCM16;
}

// 编码完整音频帧 protobuf：MessageWrapper.audioPacket = AudioPacketMessageOrdered{ seq, AudioPacketMessage, timestamp }。
// 三层嵌套均按精确长度一次性分配（容量先算后写，无增长重分配）。
export function micYouEncodeAudioPacketMessage(payload: ArrayBuffer, sampleRate: number, channels: number,
  audioFormat: number, sequence: number, timestamp: number): Uint8Array {
  const pcm = new Uint8Array(payload);
  const payloadLen = pcm.length;
  const innerLen = (1 + micYouVarintLen(payloadLen) + payloadLen)
    + (1 + micYouVarintLen(sampleRate))
    + (1 + micYouVarintLen(channels))
    + (1 + micYouVarintLen(audioFormat));
  const orderedLen = (1 + micYouVarintLen(sequence))
    + (1 + micYouVarintLen(innerLen) + innerLen)
    + (1 + micYouVarintLen(timestamp));
  const writer = new MicYouProtoWriter(1 + micYouVarintLen(orderedLen) + orderedLen);
  writer.writeLenDelimitedHeader(1, orderedLen); // MessageWrapper.audioPacket (field 1)
  writer.writeVarintField(1, sequence); // Ordered.sequenceNumber
  writer.writeLenDelimitedHeader(2, innerLen); // Ordered.audioPacket
  writer.writeLenDelimitedHeader(1, payloadLen); // AudioPacketMessage.buffer
  writer.writeRaw(pcm);
  writer.writeVarintField(2, sampleRate);
  writer.writeVarintField(3, channels);
  writer.writeVarintField(4, audioFormat);
  writer.writeVarintField(3, timestamp); // Ordered.timestamp
  return writer.toUint8Array();
}

// 8 字节大端帧头 + protobuf → 完整发送帧。
export function micYouBuildFrame(protobuf: Uint8Array): ArrayBuffer {
  const frame = new ArrayBuffer(8 + protobuf.length);
  const view = new DataView(frame);
  view.setInt32(0, MICYOU_PACKET_MAGIC, false); // 大端
  view.setInt32(4, protobuf.length, false); // 大端
  new Uint8Array(frame, 8).set(protobuf);
  return frame;
}
