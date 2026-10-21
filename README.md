# 🧰 Multi-Toolbox (多功能动态百宝箱)

> 🚀 **跨平台（Windows / Android）热插拔动态扩展百宝箱应用**。  
> 客户端原生极致轻量，海量实用工具按需静默下载、即装即用。内置多源智能竞速、故障无缝转移、深度参数检索与客户端在线热升级体系。

---

## 🌟 核心特性

- 🔌 **动态插件化架构**：每个功能均为独立插件（`.json` / `.zip`），支持云端市场一键安装与本地校验加载，告别臃肿单一客户端。
- 🌐 **多源镜像与自动故障转移**：默认组建 **Gitee（国内极速）** + **jsDelivr CDN（免梯全球加速）** + **GitHub Raw（国际直连）** 节点池，智能测速竞速选优，弱网限流时自动无缝切换线路。
- 🔍 **双模功能搜索**：支持「普通搜索」与「深度搜索」，深入扫描模块简介、处理算法、参数字段及可选下拉项。
- 🔄 **客户端在线自更新**：支持在线校验最新客户端，Android 端应用内下载系统原生调起覆盖，Windows 端伴生热替换自动重启。
- 🛡️ **严格安全约束**：引入最低客户端版本（`minAppVersion`）强校验机制，防范跨版本不兼容崩溃与结构非法问题。
- 👥 **开放开源社区生态**：接入 [Toolbox-Community-Registry](https://github.com/SuJiuOvO/Toolbox-Community-Registry)，任何人均可通过提交 PR 为百宝箱贡献新工具。

---

## 📦 预设官方功能矩阵

| 工具分类 | 功能模块 | 核心能力与技术亮点 | 支持平台 |
| :--- | :--- | :--- | :--- |
| **图片处理** | 图片格式与质量压缩 | 有损/无损压缩，支持 JPG/PNG/WebP 质量比率精细调节 | 全平台通用 |
| **图片处理** | 图片等比缩放与尺寸调节 | 双线性插值抗锯齿，支持百分比及目标宽高像素重置 | 全平台通用 |
| **图片处理** | 智能证件照换底色与剪裁 | 纯色底色自由替换，内置标准一寸、二寸、考研考试规格比例 | 全平台通用 |
| **文档/PDF** | PDF 综合拆分/合并/提取 | 高精度矢量合并与页面提取，无失真离线重构 | 全平台通用 |
| **文档/PDF** | Office / PDF / Markdown 互转 | 原生调用系统 Office/WPS 引擎输出真矢量印刷级交付件，含轻量离线回退 | Windows / Android |
| **文档/PDF** | CAD (DXF) 工业图纸转换 | 智能解析 DXF 矢量图元，支持黑底工程模式与白底蓝图打印输出高清 PDF | 全平台通用 |
| **音视频** | 视频/音频格式转换与降噪分段 | 依托 FFmpeg 引擎提取纯音频、视频压缩与音轨分段 | 全平台通用 |
| **其他实用** | 二维码动态生成与解码扫描 | 高容错率二维码制作，本地相册/文件高清解析 | 全平台通用 |
| **其他实用** | 动态照片 (LivePhoto) 提取导出 | 提取实况照片独立静帧高清图与 MOV 视频片段 | 全平台通用 |
| **其他实用** | GIF 动图分解与倒放合成 | 高速提取帧序列，倒放逆序合成及帧率自定义调节 | 全平台通用 |

---

## 🛠️ 本地编译与构建

### 环境要求
- [Flutter SDK](https://flutter.dev) (>= 3.24.0)
- [Dart SDK](https://dart.dev) (>= 3.5.0)
- Android Studio / Android SDK (针对 Android 端)
- Visual Studio 2022 C++ 桌面工作负荷 (针对 Windows 端)

### 常用命令

```bash
# 1. 克隆代码
git clone https://github.com/SuJiuOvO/Multi-Toolbox.git
cd Multi-Toolbox

# 2. 安装依赖
flutter pub get

# 3. 运行静态语法分析与自动化测试
flutter analyze
flutter test

# 4. 构建 Windows 发布版
flutter build windows --release
# 输出位置: build/windows/x64/runner/Release/

# 5. 构建 Android Release APK
flutter build apk --release
# 输出位置: build/app/outputs/flutter-apk/app-release.apk
```

---

## 🤝 开源社区与贡献模块

- 社区模块仓库：[SuJiuOvO/Toolbox-Community-Registry (GitHub)](https://github.com/SuJiuOvO/Toolbox-Community-Registry) / [苏玖/Toolbox-Community-Registry (Gitee)](https://gitee.com/sujiuovo/toolbox-community-registry)
- 详细插件开发规范请参阅 [`docs/PLUGIN_DEVELOPMENT_GUIDE.md`](docs/PLUGIN_DEVELOPMENT_GUIDE.md)。

---

## 📄 开源许可证

本项目基于 [MIT 许可证](LICENSE) 开源发布。
