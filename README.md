# 🎧 AirMic

Transform your phone into a low-latency wireless gaming headset for your PC.

AirMic allows you to use your phone's **microphone**, **speaker**, and eventually **camera** as native PC peripherals over your local network.

![Platform](https://img.shields.io/badge/platform-Windows-blue)
![Frontend](https://img.shields.io/badge/frontend-React%20%2B%20Tauri-orange)
![Mobile](https://img.shields.io/badge/mobile-Flutter-blue)



---

## ✨ Features

### 🎤 Phone as PC Microphone
Use your phone's microphone as an input device for:

- Discord
- OBS Studio
- Zoom
- Microsoft Teams
- Games with voice chat
- Any application that supports microphones

---

### 🔊 Phone as Wireless Headset Speaker
Route PC audio directly to your phone:

- Discord audio
- Game audio
- Music
- Videos
- System sounds

Works just like a wireless gaming headset.

---

### ⚡ Full Duplex Audio
AirMic supports simultaneous:

- Phone → PC microphone streaming
- PC → Phone speaker streaming

allowing real-time conversations with minimal latency.

---

### 🎧 Bluetooth Earbud Support
Connect Bluetooth earbuds to your phone and use them as:

- Wireless PC headphones
- Wireless PC microphone

No PC Bluetooth support required.

---

### 📶 Local Network Pairing
Fast local pairing using:

- Pair codes
- Automatic discovery
- Local WiFi communication

No accounts required.

---

### 🔒 Privacy First
Your audio never leaves your local network.

No cloud servers.

No subscriptions.

No telemetry.

---

## 🏗 Architecture

### Microphone Path

```text
Phone Microphone
        ↓
AirMic Mobile
        ↓
WiFi
        ↓
AirMic Desktop
        ↓
Virtual Microphone
        ↓
Discord / OBS / Games
```

### Speaker Path

```text
Discord / Games / Music
            ↓
Virtual Speaker
            ↓
AirMic Desktop
            ↓
WiFi
            ↓
AirMic Mobile
            ↓
Phone Speaker / Earbuds
```

---

## 🛠 Tech Stack

### Desktop
- Tauri v2
- Rust
- React
- TypeScript
- Vite

### Mobile
- Flutter
- Dart

### Audio
- CPAL
- WASAPI
- VB-Cable Integration

### Networking
- TCP
- UDP
- Local LAN Communication

---

## 🚀 Installation

### Desktop

Download the latest release and install:

```bash
AirMicSetup.exe
```

### Mobile

Install:

```bash
AirMic.apk
```

---

## 🔧 Requirements

### PC
- Windows 10/11
- Local Network Connection

### Mobile
- Android 8+
- Same WiFi Network as PC

---

## 📸 Planned Features

- 📷 Phone Camera as Webcam
- 🖥 Multiple PC Support
- 🎚 Audio Effects
- 🌐 Remote Internet Connection
- 🎮 Gaming Mode
- 🔋 Battery Optimization
- 🪟 System Tray Support
- 🔄 Auto Reconnect
- 🌓 Themes
- 🍎 iOS Support

---

## 🎯 Goal

AirMic aims to make your phone function exactly like a premium wireless gaming headset:

- Independent microphone
- Independent speaker
- Low latency
- Plug-and-play experience

---

## 🤝 Contributing

Contributions are welcome!

Feel free to:

- Open issues
- Submit pull requests
- Suggest features
- Improve documentation

---

## 📜 License

This project is licensed under the MIT License.

---

## ⭐ Support the Project

If you find AirMic useful, consider giving the repository a star ⭐

It helps the project grow and reach more users.

---

Built with ❤️ by Ayush Pandey
