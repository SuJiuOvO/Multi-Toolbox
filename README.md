# 🧰 Multi-Toolbox (多功能动态百宝箱)

<p align="center">
  <img src="assets/app_icon.png" width="128" height="128" alt="Multi-Toolbox Logo" style="border-radius: 28px;" />
</p>

<p align="center">
  <b>跨平台 · 热插拔 · 全沙箱 · 纯本地私密运行的下一代模块化生产力百宝箱</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.24+-02569B?logo=flutter&logoColor=white" alt="Flutter" />
  <img src="https://img.shields.io/badge/Dart-3.5+-0175C2?logo=dart&logoColor=white" alt="Dart" />
  <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20Android-4CAF50" alt="Platform" />
  <img src="https://img.shields.io/badge/Runtime-QuickJS%20%7C%20Wasm%20%7C%20Native-6366F1" alt="Runtime" />
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License" />
</p>

---

## 📖 项目简介

**Multi-Toolbox** 是专为 **Windows 桌面端** 与 **Android 移动端** 深度打造的现代化热插拔百宝箱应用。

摒弃了传统工具箱“全部功能写死在客户端内、越用越臃肿、更新必须重新发版”的痛点，Multi-Toolbox 采用**插件化微内核架构**，支持功能模块在全隔离沙箱中即装即用。无论是高算力 WebAssembly 二进制模块、JavaScript 动态脚本，还是 Windows 原生可执行程序与自动化脚本，均可通过轻量声明式清单（Manifest）驱动运行。

所有运算**100% 在用户本地设备执行**，零遥测、零数据上报，全面保障隐私安全。

---

## 🌟 核心特性与技术架构

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Multi-Toolbox 客户端底座                         │
├──────────────────┬──────────────────┬──────────────────┬───────────────┤
│  QuickJS 脚本沙箱 │  WebAssembly微核  │  Windows开放工坊  │  本地原生引擎 │
│ (JS动态热加载插件) │ (C/Rust字节码执行)│(Exe/Py/PS终端流) │(图片/文档/归档)│
├──────────────────┴──────────────────┴──────────────────┴───────────────┤
│                 声明式 UI 引擎 & 图标渲染体系 (图片/SVG代码)             │
├────────────────────────────────────────────────────────────────────────┤
│           多源竞速 Registry 节点池 (Gitee / jsDelivr / GitHub)          │
└────────────────────────────────────────────────────────────────────────┘
```

### 1. 多运行时沙箱支持
- **🦀 WebAssembly (Wasm) 全能算力内核**：
  客户端底座内嵌 WASM 解释器与 Native Assets 离线构建钩子，支持在完全隔离的内存沙箱中直接加载并执行由 C/C++/Rust 编译的 `.wasm` 与 `.wat` 模块，提供导出表逆向自省、函数调用传参及纳秒级耗时统计。
- **⚡ QuickJS 跨平台轻量脚本沙箱**：
  内嵌纯本地 QuickJS 运行时与宿主桥接通道，支持在 Android 与 Windows 上免更新客户端直接热加载执行动态 JS 脚本插件。
- **🪟 Windows 开放扩展工坊**：
  Windows 平台专享能力，支持声明式调度外部独立 `.exe`、`PowerShell` 与 `Python` 脚本，并提供实时捕获的流式终端黑框控制台（Terminal Log Viewer），支持一键强杀与日志清理。
- **🔒 纯本地私密离线执行**：
  所有数据转换、去水印、解压、算力执行均在本地完成，绝不向任何第三方云端传输用户的文件或数据。

### 2. 智能插件包与高级图标系统
- **声明式表单构建**：插件通过简洁的 JSON 清单声明输入组件（文件选择器、滑动条、单选/多选下拉、数字输入、动态联动条件 `visibleIf`）。
- **全格式图标渲染与安全校验**：
  - **图片图标**：支持内联 Base64、本地打包文件及网络图片，**严格执行大小限制（默认 $\le$ 512KB）与像素分辨率限制（默认 $\le$ 512×512）**，防范超大图片引发的内存泄漏与掉帧。
  - **代码渲染图标**：支持直接嵌入纯文本 SVG 矢量 XML 代码，轻量矢量缩放不失真。
  - **Material 关键词**：兼容常见系统图标快捷别名。
  - **优雅安全降级**：若未配置图标，或提供的图标损坏、超大、格式非法，客户端将自动平滑降级为**官方默认功能模块图标**，杜绝任何红屏或解析异常。

### 3. 多源镜像与无感容灾竞速
- 接入社区镜像生态，默认提供 **Gitee（国内极速）** + **jsDelivr CDN（全球免梯加速）** + **GitHub Raw（国际直连）** 节点池。
- 内置智能测速、自动选优及单点故障自动无缝转移，单节点被墙或限流时自动切换备用线路。
- 支持开启“纯离线模式”，完全切断云端网络检索，仅使用本地已下载资产。

### 4. 客户端全量自更新
- **Android 端**：支持应用内检测最新版本、静默断点下载，下载完成后自动校验 SHA256 并调起系统原生 PackageInstaller 执行无缝覆盖升级。
- **Windows 端**：支持一键拉取便携 ZIP 包，通过独立伴生替换进程实现退出、覆盖与自动重启启动。

---

## 📦 内置官方功能矩阵

| 分类 | 功能模块 | 核心能力与技术亮点 | 运行底座 | 支持平台 |
| :--- | :--- | :--- | :--- | :--- |
| **图片处理** | **Gemini-Banana 无损去水印** | 基于**逆向 Alpha 混合数学解算算法（Reverse Alpha Blending）**，逐像素还原被 Google Gemini、Nano Banana 等遮挡的原图底色，拒绝涂抹模糊与 AI 虚构 | 本地算法引擎 | 全平台通用 |
| **图片处理** | **图片格式与质量无损压缩** | 深度支持 JPG / PNG / WebP 质量因子调节与有损/无损压缩 | 本地算法引擎 | 全平台通用 |
| **图片处理** | **图片等比缩放与尺寸调节** | 采用双线性插值抗锯齿，支持按比例缩放及自定义宽高重采样 | 本地算法引擎 | 全平台通用 |
| **图片处理** | **智能证件照换底色与剪裁** | 纯色底自由替换，内置标准一寸、二寸、计算机考试等常用规格比例 | 本地算法引擎 | 全平台通用 |
| **文档/CAD** | **PDF 综合拆分/合并/提取** | 纯本地 PDF 矢量合并、选页重构与文本提取，秒级离线批处理 | 本地算法引擎 | 全平台通用 |
| **文档/CAD** | **Office / PDF / Markdown 互转** | Windows 原生调起 Office/WPS COM 组件输出 100% 印刷级真矢量；Android 端支持轻量离线回退与 WPS 官方跳转 | 系统 Office / 离线回退 | Windows / Android |
| **文档/CAD** | **CAD (DXF) 工业图纸转换** | 智能解析 DXF 矢量图元，支持黑底工程模式与白底蓝图打印输出高清 PDF | 本地矢量引擎 | 全平台通用 |
| **数据/归档** | **万能解压与密码提取工坊** | 支持 7z、RAR、ZIP、TAR 等主流格式离线流式解压，支持密码保护解密 | 本地解压引擎 | 全平台通用 |
| **数据/归档** | **万能信息摘要与多重编解码** | 支持 MD5、SHA1/SHA256/SHA512、Base64、Hex、URL、Unicode 批量编解码 | QuickJS 动态沙箱 | 全平台通用 |
| **音视频** | **视频/音频格式转换与降噪分段**| 依托深度优化的本地多媒体流水线提取纯音频、分段截取与视频压缩 | FFmpeg 多媒体内核 | 全平台通用 |
| **算力沙箱** | **WebAssembly 全能算力工坊** | 支持直接拖拽加载 C/Rust 编译的 `.wasm`/`.wat` 模块，自省导出表并沙箱执行 | Wasm 微核解释器 | 全平台通用 |
| **Windows工坊**| **Windows 独立扩展工坊** | 声明式外挂运行外部 CLI 命令行、Python、PowerShell，带流式终端回显 | Windows 宿主桥 | Windows 专享 |

---

## 📐 插件包清单规范 (Manifest v2.0)

插件由单个 `.json` 清单（或包含资源和脚本的 `.zip` 包）定义。示例如下：

```json
{
  "id": "my-awesome-tool",
  "name": "示例自定义工具",
  "version": "1.0.0",
  "minAppVersion": "1.0.0",
  "category": "other",
  "platforms": ["universal"],
  "description": "基于 WASM 运行的高性能加密运算工具",
  "author": "社区开发者",
  "executionType": "wasm",
  "icon": {
    "type": "code",
    "data": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><rect x=\"2\" y=\"2\" width=\"20\" height=\"20\" rx=\"4\" fill=\"#3B82F6\"/></svg>",
    "maxPixels": 512,
    "maxSizeBytes": 524288
  },
  "inputs": [
    {
      "id": "inputFile",
      "label": "选择待处理文件",
      "type": "file_picker",
      "required": true,
      "allowedExtensions": ["wasm", "bin"]
    }
  ],
  "action": {
    "handler": "wasm_runner",
    "params": {
      "entryFunction": "process"
    }
  }
}
```

> **图标属性说明**：
> - `type`: `'code'`（SVG 代码）、`'image'`（Base64 或文件路径）、`'material'`（系统关键词）。
> - `maxPixels`: 允许的最大宽高（像素），默认 512。
> - `maxSizeBytes`: 允许的最大字节数，默认 512KB。
> - 若未配置或不符合规范，客户端将统一降级展示官方默认功能模块图标。

---

## 🛠️ 本地编译与构建指南

### 前置环境
- [Flutter SDK](https://flutter.dev) (>= 3.24.0)
- [Dart SDK](https://dart.dev) (>= 3.5.0)
- Android SDK & NDK（针对 Android 端构建）
- Visual Studio 2022 C++ 桌面工作负荷（针对 Windows 桌面端构建）

### 常用命令

```bash
# 1. 克隆代码仓库
git clone https://github.com/SuJiuOvO/Multi-Toolbox.git
cd Multi-Toolbox

# 2. 安装并同步依赖
flutter pub get

# 3. 运行静态代码语法分析与自动化测试套件
flutter analyze lib test
flutter test

# 4. 构建 Windows Release 独立发布版
flutter build windows --release
# 产物输出路径: build/windows/x64/runner/Release/

# 5. 构建分架构 Android Release APK (推荐，包体积更小)
flutter build apk --split-per-abi --release
# 产物分别位于:
# - app-arm64-v8a-release.apk (主流真机，体积约 88MB)
# - app-x86_64-release.apk (主流电脑安卓模拟器，体积约 93MB)
# - app-armeabi-v7a-release.apk (旧型32位设备，体积约 116MB)

# 6. 构建全架构通用版 APK (兼容所有 ABI)
flutter build apk --release
# 产物输出路径: build/app/outputs/flutter-apk/app-release.apk
```

---

## 🤝 社区插件市场与贡献

Multi-Toolbox 的插件市场生态完全开放，欢迎向社区官方注册表贡献您的实用工具：

- **官方社区仓库**：[SuJiuOvO/Toolbox-Community-Registry](https://github.com/SuJiuOvO/Toolbox-Community-Registry)
- **提交方式**：Fork 社区仓库，在 `registry/` 目录下添加您的功能清单与依赖，提交 Pull Request 即可自动完成合入与多节点同步分发。

---

## 📄 开源许可证

本项目基于 [MIT 许可证](LICENSE) 开源发布。保留所有权利，欢迎自由学习、使用与二次开发。
