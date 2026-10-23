<div align="center">

<h1>VoxBridge</h1>

<img src="./picture/icon-dark-1024.webp" width="128" height="128" />

<br>

<b>English</b> | <a href="./README_zh-cn.md">简体中文</a> | <a href="./README_zh-tw.md">繁體中文</a>

<br>

<a href="./LICENSE"><img alt="License" src="https://img.shields.io/badge/License-MIT-blue.svg"></a>
<img alt="Platform" src="https://img.shields.io/badge/Platform-HarmonyOS-1F6FEB">
<img alt="HarmonyOS API" src="https://img.shields.io/badge/HarmonyOS_API-26-orange">
<img alt="App" src="https://img.shields.io/badge/App-ArkTS-3178C6">

<br>
<br>

VoxBridge turns your HarmonyOS phone into a high-quality microphone for your PC.

Native HarmonyOS app · LAN streaming · MicYou desktop compatible

<br>

*This project was built by AI under human supervision.*

</div>

## Features

- Capture voice at up to 48 kHz / 24 bit (auto downgrades to 16 kHz / 16 bit on weak networks)
- Process audio on-device: 5-band RBJ equalizer, AGC, limiter and DeepFilterNet3 noise suppression
- Watch four real-time visualizations — spectrum, waveform, level meter and ripple — switchable via a draggable floating dock, adaptive to both orientations
- Stream to the MicYou desktop app (port 9123) or any VoxBridge-protocol receiver (port 9000)
- Light/dark themes, immersive materials and a lock-screen media session card

## Screenshots

**Portrait**

| Connect | Live | Waveform |
|:---:|:---:|:---:|
| ![Connect](img/home.png) | ![Live](img/live.png) | ![Waveform](img/viz_waveform.png) |

| Ripple | Settings |
|:---:|:---:|
| ![Ripple](img/viz_ripple.png) | ![Settings](img/settings.png) |

**Landscape**

| Live | Visualizer |
|:---:|:---:|
| ![Live landscape](img/live_landscape.png) | ![Visualizer landscape](img/viz_landscape.png) |

## Getting Started

### 1. Build the phone app

1. Install [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/) (HarmonyOS API 26).
2. Open the project and enable **Automatically generate signature** in `File > Project Structure > Signing Configs`.
3. Run the `entry` module on your device.

The DeepFilterNet static library ships with the repo (`entry/libs/arm64-v8a/libdf.a`), so no extra build step is needed; see `tools/` if you want to rebuild it.

### 2. Set up the PC receiver

Install the MicYou desktop app on your PC and make sure the phone and the PC are on the same LAN, then enter the PC's IP address and port 9123 in VoxBridge.

VoxBridge also speaks its own minimal TCP protocol (port 9000, see [Streaming Protocols](#streaming-protocols) below), handy if you want to write your own receiver.

### 3. Route through a virtual microphone

Install [VB-CABLE](https://vb-audio.com/Cable/) or any virtual audio device, select it as the receiver's output device, then pick it as the microphone in your call, game, streaming or recording app.

## Streaming Protocols

| Mode | Port | Frame format | Payload |
| --- | --- | --- | --- |
| VoxBridge receiver | TCP 9000 | `[type u8][len u32 LE]` | `type=1` config (sample rate / channels / bits), `type=2` PCM16 |
| MicYou desktop | TCP 9123 | `[0x4D696359][len i32 BE]` + protobuf | Audio packet (PCM16 / PCM24 / float32), 12-byte ASCII handshake |

A config frame is always sent right after connecting and re-sent whenever weak-network downgrade kicks in.

Implementation: `common/src/main/ets/model/TcpClientManager.ets` (VoxBridge) · `MicYouProto.ets` / `MicYouTcpClient.ets` (MicYou).

## Technology

- Phone app: ArkTS, ArkUI, HarmonyOS API 26
- Audio: DeepFilterNet3 noise suppression (`libdf.a`), RBJ biquad EQ, FFT visualization

## Project Structure

```
entry/        # Main module: pages, services, UI components
common/       # Audio pipeline (capture / EQ / noise suppression), TCP senders, viz data source
tools/        # libdf build script and DeepFilterNet patch
docs/         # Design-review mockups and implementation audit report
picture/      # App icon assets
```

## Acknowledgments

Special thanks to [Rikorose/DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) for open-sourcing DeepFilterNet, which powers VoxBridge's noise suppression.

VoxBridge is protocol-compatible with the MicYou desktop app, which also inspired its streaming design.

## License

This project is licensed under the [MIT License](./LICENSE). The bundled `entry/libs/arm64-v8a/libdf.a` is a static build of DeepFilterNet v0.5.6 (MIT); see the third-party notice in LICENSE.
