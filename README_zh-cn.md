<div align="center">

<h1>VoxBridge</h1>

<img src="./picture/icon-dark-1024.webp" width="128" height="128" />

<br>

<a href="./README.md">English</a> | <b>简体中文</b> | <a href="./README_zh-tw.md">繁體中文</a>

<br>

<a href="./LICENSE"><img alt="License" src="https://img.shields.io/badge/License-MIT-blue.svg"></a>
<img alt="Platform" src="https://img.shields.io/badge/Platform-HarmonyOS-1F6FEB">
<img alt="HarmonyOS API" src="https://img.shields.io/badge/HarmonyOS_API-26-orange">
<img alt="App" src="https://img.shields.io/badge/App-ArkTS-3178C6">

<br>
<br>

VoxBridge 可将 HarmonyOS 手机变为高品质的 PC 麦克风。

原生鸿蒙应用 · 局域网串流 · MicYou 桌面端兼容

<br>

*该项目由 AI 在人类监管下完成。*

</div>

## 主要功能

- 以最高 48 kHz / 24 bit 采集人声（弱网自动降级至 16 kHz / 16 bit）
- 端上音频处理：5 段 RBJ 均衡器、AGC、限幅器与 DeepFilterNet3 降噪
- 四种实时可视化——频谱、波形、电平表与涟漪——通过可拖拽悬浮 Dock 切换，横竖屏自适应
- 双协议串流：MicYou 桌面端（端口 9123）或任意 VoxBridge 协议接收端（端口 9000）
- 深浅色主题、沉浸式材质与锁屏媒体会话卡片

## 软件截图

**竖屏**

| 连接 | 直播 | 波形 |
|:---:|:---:|:---:|
| ![连接](img/home.png) | ![直播](img/live.png) | ![波形](img/viz_waveform.png) |

| 涟漪 | 设置 |
|:---:|:---:|
| ![涟漪](img/viz_ripple.png) | ![设置](img/settings.png) |

**横屏**

| 直播 | 可视化 |
|:---:|:---:|
| ![直播横屏](img/live_landscape.png) | ![可视化横屏](img/viz_landscape.png) |

## 使用指南

### 1. 构建手机端

1. 安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（HarmonyOS API 26）
2. 打开项目，在 `File > Project Structure > Signing Configs` 勾选 **Automatically generate signature** 完成自动签名
3. 连接设备，运行 `entry` 模块

DeepFilterNet 静态库已随仓库提供（`entry/libs/arm64-v8a/libdf.a`），无需额外编译；如需重构建参见 `tools/`。

### 2. 运行 PC 接收端

在 PC 上安装 MicYou 桌面端，确保手机与 PC 处于同一局域网，然后在 VoxBridge 中填入 PC 的 IP 与端口 9123。

VoxBridge 同时支持自有的极简 TCP 协议（端口 9000，见下方「串流协议」），方便你编写自己的接收端。

### 3. 接入虚拟麦克风

安装 [VB-CABLE](https://vb-audio.com/Cable/) 或任意虚拟声卡，在接收端选择其为输出设备，然后在通话、游戏、直播或录音软件中选择该虚拟麦克风。

## 串流协议

| 模式 | 端口 | 帧格式 | 负载 |
| --- | --- | --- | --- |
| VoxBridge 接收器 | TCP 9000 | `[type u8][len u32 LE]` | `type=1` 配置帧（采样率/声道/位深），`type=2` PCM16 |
| MicYou 桌面端 | TCP 9123 | `[0x4D696359][len i32 BE]` + protobuf | 音频包（PCM16 / PCM24 / float32），12 字节 ASCII 握手 |

连接后首帧必为配置帧；弱网降级时自动重发配置帧。

实现：`common/src/main/ets/model/TcpClientManager.ets`（VoxBridge）· `MicYouProto.ets` / `MicYouTcpClient.ets`（MicYou）。

## 技术堆叠

- 手机端：ArkTS、ArkUI、HarmonyOS API 26
- 音频：DeepFilterNet3 降噪（`libdf.a`）、RBJ 双二阶 EQ、FFT 可视化

## 项目结构

```
entry/        # 应用主模块（页面/服务/组件）
common/       # 音频管线（采集/EQ/降噪）、TCP 发送、可视化数据源
tools/        # libdf 构建脚本与 DeepFilterNet patch
docs/         # 设计评审草图与实现审计报告
picture/      # 应用图标素材
```

## 致谢

特别感谢 [Rikorose/DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) 开源 DeepFilterNet，为 VoxBridge 提供降噪能力。

VoxBridge 与 MicYou 桌面端协议兼容，其串流设计亦受其启发。

## 许可证

本项目基于 [MIT License](./LICENSE) 开源。随库附带的 `entry/libs/arm64-v8a/libdf.a` 为 DeepFilterNet v0.5.6（MIT）的静态构建，详见 LICENSE 中的第三方声明。
