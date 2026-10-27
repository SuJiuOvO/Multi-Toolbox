# 🧰 Multi-Toolbox (多功能动态百宝箱)

<p align="center">
  <img src="assets/app_icon.png" width="128" height="128" alt="Multi-Toolbox Logo" style="border-radius: 28px;" />
</p>

<p align="center">
  <b>跨平台 · 双端自适应 · 热插拔 · 全沙箱 · 纯本地私密运行的下一代模块化生产力百宝箱</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.24+-02569B?logo=flutter&logoColor=white" alt="Flutter" />
  <img src="https://img.shields.io/badge/Dart-3.5+-0175C2?logo=dart&logoColor=white" alt="Dart" />
  <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20Android-4CAF50" alt="Platform" />
  <img src="https://img.shields.io/badge/Runtime-Dual--Adaptive%20%7C%20Wasm%20VFS%20%7C%20QuickJS%20%7C%20Native-6366F1" alt="Runtime" />
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License" />
</p>

---

## 📖 项目简介

**Multi-Toolbox** 是专为 **Windows 桌面端** 与 **Android 移动端** 深度打造的现代化热插拔百宝箱应用。

摒弃了传统工具箱“全部功能写死在客户端内、越用越臃肿、更新必须重新发版”的痛点，Multi-Toolbox 采用**插件化微内核架构**，支持功能模块在全隔离沙箱中即装即用。无论是高算力 WebAssembly 二进制微核、JavaScript 动态脚本，还是 Windows 原生可执行程序，均可通过轻量声明式清单（Manifest）驱动运行。

更进一步，客户端支持 **🚀 双端自适应合一架构 (Dual-Adaptive)**：同一个功能模块可同时携带 Windows 裸机原生 EXE 二进制与 Android WASM 字节码，客户端在运行时自动识别当前操作系统并调度最优引擎，兼顾 Windows 的极致原生性能与 Android 的跨平台安全性！

所有运算**100% 在用户本地设备执行**，零遥测、零数据上报，全面保障隐私安全。

---

## 🌟 核心特性与技术架构

```text
┌──────────────────────────────────────────────────────────────────────────────────┐
│                             Multi-Toolbox 客户端底座                              │
├─────────────────────┬──────────────────┬──────────────────┬──────────────────────┤
│ 🚀 双端自适应路由器 │ 🦀 WASI VFS 沙箱 │ ⚡ QuickJS 引擎   │ 🪟 Windows 开放工坊  │
│ (Win原生/安卓Wasm)  │(POSIX目录虚拟映射)│ (JS动态热加载)   │ (EXE/脚本+实时终端)  │
├─────────────────────┴──────────────────┴──────────────────┴──────────────────────┤
│ 📁 宿主层文件夹扁平化展开 & 路径去重防死循环 (flattenInputEntries)               │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 🎛️ 统一插件管理中心 (InstalledPluginsManager: 实时搜索/来源分类/一键干净卸载)    │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 🎨 声明式 UI 引擎 & 图标渲染体系 (SVG矢量代码 / 图片安全降级 / 深浅主题自适应)  │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 🌐 多源竞速 Registry 节点池 (Gitee 国内极速 / jsDelivr CDN / GitHub 直连)       │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### 1. 深度执行沙箱与智能路由
- **🚀 双端自适应合一路由引擎 (Dual-Adaptive)**：
  单个功能模块可同时声明 `nativeRunner`（供 Windows 运行原生编译二进制）与 `wasmRunner`（供 Android 运行 WASM 算力微内核）。客户端内置 `resolveExecutionEngine` 路由器：
  - Windows 端自动调度 `WindowsExtensionRunnerService`，享受裸机机器码的极致算力（160MB 巨型文件 **0.3 秒** 秒级直出）；
  - Android 端自动调度 `WasmUniversalService`，在沙箱中无缝流式处理（**<1 秒** 完成）；
  - 界面实时展示当前生效内核（`🚀 Win 原生极速模式` / `🦀 Android Wasm 沙箱模式`），用户无需任何配置。
- **🦀 WASI Preview 1 虚拟文件系统 (VFS) 磁盘映射沙箱**：
  采用高性能 Rust `wasm_run` 底座（预打入 Android `arm64-v8a`、`armeabi-v7a`、`x86`、`x86_64` 的 `libwasm_run_dart.so` 以及 Windows 的 `wasm_run_dart.dll`）。将宿主主机工作路径无缝挂载为沙箱内的 `/input`、`/output`、`/tmp` 标准 POSIX 虚拟文件系统，C/C++/Rust 标准流式 I/O 无缝流转，彻底解决大内存暴涨与 UTF-8 乱码。
- **⚡ QuickJS 跨平台轻量脚本沙箱**：
  纯本地 QuickJS 运行时与宿主桥接通道，支持在 Android 与 Windows 上免发版热加载执行动态 JS 脚本插件。
- **🪟 Windows 开放扩展工坊**：
  支持声明式调度外部独立 `.exe`、`PowerShell` 与 `Python` 脚本，并提供实时捕获的流式终端控制台（Terminal Log Viewer），支持一键强杀与日志输出。
- **🎬 本地音视频多媒体流水线 (FFmpeg)**：
  全面扩展支持 **FLAC 原生多线程无损转码**（`-c:a flac`）与 **OGG (Vorbis) 高效转码**（双重保障：首选 `libvorbis -q:a 5`，若运行环境缺失自动平滑回退至 FFmpeg 原生内置 `vorbis` 编码器）。

### 2. 统一插件与模块管理中心 (`InstalledPluginsManagerPage`)
- **一键卸载（解决原痛点）**：
  彻底解决了以往“本地导入插件无法卸载、云端插件必须回市场翻找”的缺陷，无论插件是本地导入（`.json` / `.zip`）还是市场下载，均可一键弹出二次确认安全弹窗并彻底擦除本地沙箱目录与缓存。
- **实时全文搜索**：
  配备自适应搜索栏，支持插件名称、ID、分类、作者、功能描述与标签的毫秒级模糊检索。
- **来源与状态分类筛选**：
  提供带实时计数的过滤标签：`全部`、`第三方与扩展`、`本地导入`、`市场安装`、`内置核心`。
- **内置核心防呆保护**：
  系统内置基础功能模块（如图片压缩、文档转换等基石）自动赋予“内置核心”保护徽标并禁用卸载按钮，防止误删系统核心基石。
- **全平台与深浅主题自适应**：
  Windows 端采用多列响应式网格流（支持鼠标 Hover 态与高信息密度），移动端采用单列大触控圆角卡片；完美兼容浅色、深色与毛玻璃主题。

### 3. Android 专有格式容错与文件夹递归扁平化
- **Android 私有专有后缀安全降级**：
  针对 `.ncm`、`.qmc`、`.dat` 等系统 MimeTypeMap 无法识别的私有格式，客户端实现自动异常捕获与 `FileType.any` 安全平滑降级，彻底解决 SAF 文件选择器置灰无响应问题。
- **宿主层文件夹扁平化展开 (`flattenInputEntries`)**：
  若用户选择或拖拽了整个文件夹，客户端在宿主层自动执行递归深度扫描，过滤隐藏与系统垃圾文件（`.DS_Store`、`Thumbs.db`、`desktop.ini`），并通过规范化路径去重与符号链接防死循环保护（`followLinks: false`），将目标文件整齐输入给下游处理引擎。

### 4. 声明式 UI 与多源镜像竞速池
- **声明式表单构建**：插件通过简洁的 JSON 清单声明输入组件（文件选择器、滑动条、单选/多选下拉、数字输入、动态联动条件 `visibleIf`）。
- **全格式图标渲染体系**：支持内联纯文本 SVG 矢量 XML 代码、图片格式（严格限制大小 $\le$ 512KB 与像素分辨率 $\le$ 512×512）与自动平滑降级。
- **三源竞速注册中心**：默认接入 **Gitee（国内极速）** + **jsDelivr CDN（全球免梯加速）** + **GitHub Raw（国际直连）** 节点池，支持自动测速选优、单点故障秒级切换与纯离线模式。

---

## 📦 内置官方功能矩阵

| 分类 | 功能模块 | 核心能力与技术亮点 | 运行底座 | 支持平台 |
| :--- | :--- | :--- | :--- | :--- |
| **音频解密** | **网易云 NCM 解密** 🌟 | 100% 还原原始无损 FLAC 或高保真 MP3 音轨，自动嵌入元数据与高清封面，**Windows 跑原生极速 EXE (0.3s 直出)，Android 跑 WASM 沙箱 (<1s 完成)** | **🚀 双端自适应** | 全平台通用 |
| **音视频** | **音视频工具箱 (v1.3.0)** 🎬 | 基于 GPU 硬件加速 (NVENC/QSV/AMF/MediaCodec) 与智能线程调度；支持 **FLAC 多线程无损转码** 与 **OGG Vorbis 高保真转码**（带原生双重回退） | 本地 FFmpeg 流水线 | 全平台通用 |
| **图片处理** | **Gemini-Banana 无损去水印** | 基于**逆向 Alpha 混合数学解算算法（Reverse Alpha Blending）**，逐像素还原被遮挡的原图底色，拒绝涂抹模糊与 AI 虚构 | 本地算法引擎 | 全平台通用 |
| **图片处理** | **图片格式与质量无损压缩** | 深度支持 JPG / PNG / WebP 质量因子调节与有损/无损压缩 | 本地算法引擎 | 全平台通用 |
| **图片处理** | **图片等比缩放与尺寸调节** | 采用双线性插值抗锯齿，支持按比例缩放及自定义宽高重采样 | 本地算法引擎 | 全平台通用 |
| **图片处理** | **智能证件照换底色与剪裁** | 纯色底自由替换，内置标准一寸、二寸、计算机考试等常用规格比例 | 本地算法引擎 | 全平台通用 |
| **文档/CAD** | **PDF 综合拆分/合并/提取** | 纯本地 PDF 矢量合并、选页重构与文本提取，秒级离线批处理 | 本地算法引擎 | 全平台通用 |
| **文档/CAD** | **Office / PDF / Markdown 互转** | Windows 原生调起 Office/WPS COM 组件输出 100% 印刷级真矢量；Android 端支持轻量离线回退与 WPS 官方跳转 | 系统 Office / 离线回退 | Windows / Android |
| **文档/CAD** | **CAD (DXF) 工业图纸转换** | 智能解析 DXF 矢量图元，支持黑底工程模式与白底蓝图打印输出高清 PDF | 本地矢量引擎 | 全平台通用 |
| **数据/归档** | **万能解压与密码提取工坊** | 支持 7z、RAR、ZIP、TAR 等分卷包自动串联、GBK 乱码探测修复与防双重嵌套 | 本地解压引擎 | 全平台通用 |
| **数据/归档** | **万能信息摘要与多重编解码** | 支持 MD5、SHA1/SHA256/SHA512、Base64、Hex、URL、Unicode 批量编解码 | QuickJS 动态沙箱 | 全平台通用 |
| **算力沙箱** | **WebAssembly 全能算力工坊** | 支持直接拖拽加载 C/Rust 编译的 `.wasm`/`.wat` 模块，自省导出表并沙箱执行 | Wasm 微核解释器 | 全平台通用 |
| **Windows工坊**| **Windows 独立扩展工坊** | 声明式外挂运行外部 CLI 命令行、Python、PowerShell，带流式终端回显 | Windows 宿主桥 | Windows 专享 |

---

## 🛠️ 本地编译与构建指南

### 前置环境
- [Flutter SDK](https://flutter.dev) (>= 3.24.0)
- [Dart SDK](https://dart.dev) (>= 3.5.0)
- Android SDK & NDK（针对 Android 端构建）
- Visual Studio 2022 C++ 桌面工作负荷（针对 Windows 桌面端构建）

### 常用构建命令

```bash
# 1. 克隆代码仓库
git clone https://github.com/SuJiuOvO/Multi-Toolbox.git
cd Multi-Toolbox

# 2. 安装并同步依赖
flutter pub get

# 3. 运行静态代码语法分析与自动化测试套件
dart analyze lib test
flutter test

# 4. 构建 Windows Release 独立发布版
flutter build windows --release
# 产物输出路径: build/windows/x64/runner/Release/app.exe

# 5. 构建分架构 Android Release APK (推荐，体积小、性能佳)
flutter build apk --split-per-abi --release
# 产物分别位于 build/app/outputs/flutter-apk/:
# - app-arm64-v8a-release.apk (主流旗舰如骁龙 8 Gen 3，体积仅约 91MB)
# - app-x86_64-release.apk (电脑安卓模拟器，体积约 95MB)
# - app-armeabi-v7a-release.apk (旧型 32 位设备，体积约 119MB)

# 6. 构建全架构通用版 APK (兼容所有 ABI)
flutter build apk --release
# 产物输出路径: build/app/outputs/flutter-apk/app-release.apk (约 292MB)
```

---

## 🤝 社区插件市场与贡献

Multi-Toolbox 的插件市场生态完全开放，欢迎向社区官方注册表贡献您的实用工具：

- **官方社区仓库**：[SuJiuOvO/Toolbox-Community-Registry](https://github.com/SuJiuOvO/Toolbox-Community-Registry)
- **功能模块开发技术文档**：详见 [docs/PLUGIN_DEVELOPMENT_GUIDE.md](docs/PLUGIN_DEVELOPMENT_GUIDE.md)，完整涵盖 WASI VFS 沙箱、双端自适应合一架构、QuickJS、Windows CLI 扩展、Manifest v2.2 规范与完整实战开发教程。
- **提交流程**：Fork 社区仓库，在 `plugins/<id>/` 目录下添加您的模块，使用 `python tools/build_registry.py` 完成自动化校验与打包，提交 Pull Request 即可自动触发多镜像节点（Gitee / CDN / GitHub）同步分发。

---

## 📄 开源许可证

本项目基于 [MIT 许可证](LICENSE) 开源发布。保留所有权利，欢迎自由学习、使用与二次开发。
