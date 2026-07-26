# DiuBangFileS (NASServer)

面向 **Windows 桌面** 的 NAS 服务端（Flutter）：围绕用户选定的单个共享目录提供 WebDAV、控制面 API、Relay，以及共享目录内图片/视频的预览与缩略图能力。

**许可证：** [MIT](LICENSE) · **版本：** 1.0.2

**配套客户端：** [DiuBangNASClient](https://github.com/DianDanHuaJuan/DiuBangNASClient)

## 功能特性

- 用户选定单个共享目录，不提供媒体库或全盘扫描
- WebDAV 文件访问（`/dav/fs`）
- 控制面 REST API 与 WebSocket 实时通道
- 共享目录内图片/视频预览与缩略图
- Relay：以 NAS 服务端为中转的设备间文件互传
- Windows 托盘运行、开机自启（可选）

## 环境要求

- Flutter SDK，兼容 **Dart ^3.10.7**（见 `pubspec.yaml`）
- **Windows 10 / 11，x64**（本仓库主要支持 Windows 桌面）
- **Android 服务端：** [diubangNASServer_Android](https://github.com/DianDanHuaJuan/diubangNASServer_Android)
- 配套 [DiuBangNASClient](https://github.com/DianDanHuaJuan/DiuBangNASClient)

## 快速开始

1. 从 GitHub 克隆仓库：

   ```powershell
   git clone https://github.com/DianDanHuaJuan/DiuBangNASServer.git
   cd DiuBangNASServer
   ```

2. 安装依赖：

   ```powershell
   flutter pub get
   ```

3. **预下载 Windows 构建依赖（必做）：**

   克隆后需一次性准备未纳入 Git 的外部依赖（media_kit 原生库、FFmpeg LGPL 构建）：

   ```powershell
   .\tool\bootstrap_windows.ps1
   ```

   - **media_kit**：libmpv + ANGLE，带 MD5 校验；网络不稳定时避免 `Integrity check failed`
   - **FFmpeg**：[BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) **`latest` / win64-lgpl** 静态构建（8.1 分支），仅提取 `assets\ffmpeg.exe`；

   单独修复某一依赖：

   ```powershell
   .\tool\bootstrap_windows.ps1 -Only media_kit
   .\tool\bootstrap_windows.ps1 -Only ffmpeg -Force
   ```

4. 运行（Windows 桌面）：

   ```powershell
   flutter run -d windows
   ```

   若未运行 bootstrap 且系统 PATH 无 `ffmpeg.exe`，视频缩略图与 HLS 转码不可用。

5. 开发检查：

   ```powershell
   flutter analyze
   flutter test
   ```

## Windows 安装包（Inno Setup）

打安装包前须已完成 `.\tool\bootstrap_windows.ps1`（见上文第 3 步）。

```powershell
.\packaging\windows\build_installer.ps1
```

脚本会自动调用 `.\tool\bootstrap_windows.ps1`，无需手动放置依赖。

安装包输出：`packaging\windows\output\DiuBangFileS-Setup-<version>.exe`

详见 [packaging/windows/README.md](packaging/windows/README.md)。

## Windows 构建故障排除

| 现象 | 处理 |
|------|------|
| Bootstrap 失败 | 查看脚本末尾「Bootstrap FAILED」清单，按依赖名修复；重试 `.\tool\bootstrap_windows.ps1 [-Force]`；或在 `tool\bootstrap\bootstrap.properties` 设 `localProxyEnabled=true` / 调整 `githubMirrorPrefix` |
| `Integrity check failed`（media_kit） | `.\tool\bootstrap_windows.ps1 -Only media_kit -Force`；必要时 `flutter clean` 后删除 `build\windows\x64\` 下 `*.7z`、`libmpv\`、`ANGLE\` |
| FFmpeg / media_kit 下载失败 | 同上开启本机代理或镜像后 `-Force`；或从 [BtbN latest](https://github.com/BtbN/FFmpeg-Builds/releases/tag/latest) 手动下载 `ffmpeg-n8.1-latest-win64-lgpl-8.1.zip`（**lgpl**，非 gpl） |
| 缺少 `assets\ffmpeg.exe` | `.\tool\bootstrap_windows.ps1 -Only ffmpeg` |

更多细节见 [packaging/windows/README.md](packaging/windows/README.md)。


## 贡献

详见 [CONTRIBUTING.md](CONTRIBUTING.md)。提交 Pull Request 前请确保 `flutter analyze` 和 `flutter test` 通过。

## 更新日志

详见 [CHANGELOG.md](CHANGELOG.md)。

## 第三方组件

本仓库源码为 [MIT](LICENSE)。安装包另含以下组件（详见 [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)）：

- [Noto Sans CJK SC](assets/fonts/OFL.txt) — UI 字体（SIL Open Font License 1.1）
- [FFmpeg](https://ffmpeg.org/)（[BtbN win64-lgpl](https://github.com/BtbN/FFmpeg-Builds)）— HLS/缩略图**子进程**（`assets\ffmpeg.exe`，LGPL v2.1+；H.264 编码使用 `h264_mf` / `libopenh264`，非 GPL）
- [libmpv](https://github.com/media-kit/libmpv-win32-video-build) — 本地视频预览（`libmpv-2.dll`，LGPL v2.1+，`-Dgpl=false` 构建）

## 安全

详见 [SECURITY.md](SECURITY.md)。切勿提交生产凭据或私有调试日志。
