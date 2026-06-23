# DroidMirroring for macOS

Mirror your Android device screen to Mac natively. Low latency, full control.

将 Android 设备屏幕镜像到 Mac 上的原生应用。低延迟，全控制。

![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Universal](https://img.shields.io/badge/arch-Universal%20%28ARM64%20%2B%20x86__64%29-lightgrey)

---

<p align="center">
  <img src="https://via.placeholder.com/800x450/1a1a2e/ffffff?text=🎬+Video+Demo+Coming+Soon" alt="Demo Video" width="800">
</p>

<p align="center">
  <img src="https://via.placeholder.com/400x300/16213e/ffffff?text=📱+Screenshot+1" width="48%" alt="Screenshot 1">
  <img src="https://via.placeholder.com/400x300/0f3460/ffffff?text=🖥️+Screenshot+2" width="48%" alt="Screenshot 2">
</p>

---

## Features / 功能特性

- 📱 **Real-time Mirroring** — Low-latency screen mirroring via scrcpy
- 🖥️ **Desktop Mode** — Run Android desktop on Mac (Android 14+)
- 📁 **File Manager** — Browse and transfer files via ADB
- ⌨️ **Keyboard & Mouse** — Full Mac input support
- 📡 **USB & Wi-Fi** — Wired or wireless connection
- 🎬 **Screen Recording** — Record device screen directly
- 🔀 **Universal Binary** — Native support for Apple Silicon & Intel Mac

- 📱 **实时镜像** — 通过 scrcpy 实现低延迟屏幕镜像
- 🖥️ **桌面模式** — 在 Mac 上运行 Android 桌面（需 Android 14+）
- 📁 **文件管理** — 通过 ADB 浏览和传输文件
- ⌨️ **键盘鼠标** — 完整的 Mac 输入支持
- 📡 **USB 和 Wi-Fi** — 有线或无线连接
- 🎬 **屏幕录制** — 直接录制设备屏幕
- 🔀 **通用二进制** — 原生支持 Apple Silicon 和 Intel Mac

## Download / 下载

| Version | Architecture | Download |
|---------|-------------|----------|
| Latest | **Universal** (ARM64 + x86_64) | [📦 DroidMirroring-universal.dmg](https://github.com/matyle/droidMirroring-mac/releases/latest) |

> Requires macOS 15.0 (Sequoia) or later.

## Quick Start / 快速开始

### USB Connection

1. **Enable USB Debugging** on your Android device:
   - Settings → About phone → Tap "Build number" 7 times
   - Settings → Developer options → Enable "USB debugging"
2. Connect via USB cable
3. Tap "Allow" on the device when prompted

### Wi-Fi Pairing

1. Click **"Pair over Wi-Fi"** on the main screen
2. Follow the pairing code prompt
3. Ensure both devices are on the same network

### USB 连接（中文说明）

1. 在 Android 设备上开启 **USB 调试**：
   - 设置 → 关于手机 → 连续点击"版本号"7次
   - 设置 → 开发者选项 → 开启"USB调试"
2. 使用 USB 线连接 Mac
3. 在 Android 上点击"允许"授权

### Wi-Fi 无线配对

1. 点击主界面 **"Pair over Wi-Fi"** 按钮
2. 按照提示输入配对码
3. 确保 Mac 和 Android 在同一网络

## FAQ / 常见问题

<details>
<summary><b>Device not detected? / 检测不到设备？</b></summary>

- Make sure USB debugging is enabled / 确认 USB 调试已开启
- Try a different USB cable / 尝试更换 USB 数据线
- Run `adb devices` in Terminal to verify connection
</details>

<details>
<summary><b>Mirroring is laggy? / 镜像画面卡顿？</b></summary>

- Use USB connection instead of Wi-Fi / 无线连接时尝试改用 USB 连接
- Lower the device screen resolution / 降低设备屏幕分辨率
</details>

## License / 许可证

MIT License

## Support / 支持

- Bug reports: [Issues](https://github.com/matyle/droidMirroring-mac/issues)
- Code repository: [DroidMirroring](https://github.com/matyle/DroidMirroring)
