# 《多功能百宝箱 (Multi-Toolbox) 插件与功能模块开发技术手册》

> **版本**：v1.0.0  
> **适用对象**：核心开发人员、功能插件开发者、运维与内容维护人员  
> **核心原则**：**客户端长效稳定，功能云端热插拔**（无需重新打包发版客户端，即可动态新增、更新、下架工具）

---

## 目录
1. [系统整体架构与设计理念](#1-系统整体架构与设计理念)
2. [插件目录规范与包结构](#2-插件目录规范与包结构)
3. [Manifest.json 配置全字段速查](#3-manifestjson-配置全字段速查)
4. [动态 UI 表单输入组件定义规范](#4-动态-ui-表单输入组件定义规范)
5. [Action 动作与参数模板映射机制](#5-action-动作与参数模板映射机制)
6. [客户端执行引擎扩展 (ToolEngineService)](#6-客户端执行引擎扩展-toolengineservice)
7. [开发实战教程 1：纯配置扩充功能（无需改动客户端）](#7-开发实战教程-1纯配置扩充功能无需改动客户端)
8. [开发实战教程 2：开发全新底层处理能力（全链路开发）](#8-开发实战教程-2开发全新底层处理能力全链路开发)
9. [插件编译打包与服务端部署流程](#9-插件编译打包与服务端部署流程)
10. [跨平台兼容性规范 (Windows 与 Android)](#10-跨平台兼容性规范-windows-与-android)
11. [常见问题排查与避坑指南 (FAQ)](#11-常见问题排查与避坑指南-faq)

---

## 1. 系统整体架构与设计理念

本工具箱采用 **“宿主容器（Host Container）+ 数据驱动动态表单（Schema-Driven UI）+ 通用处理引擎（Unified Engine）+ 云端插件注册中心（Plugin Registry）”** 的分层设计。

```mermaid
flowchart TD
    subgraph Cloud["云端静态/服务节点 (Plugin Server)"]
        Registry["index.json (插件注册清单)"]
        ZipFiles["*.zip (功能插件包)"]
    end

    subgraph Client["多平台客户端 (Flutter Host App)"]
        subgraph UI["表现层"]
            Home["首页功能看板 (ToolboxHomePage)"]
            Store["功能中心/商店 (PluginStorePage)"]
            DynamicRunner["动态工具运行器 (DynamicToolRunnerPage)"]
        end

        subgraph Core["核心逻辑层"]
            PM["插件生命周期管理 (PluginManagerService)"]
            Engine["执行引擎分发器 (ToolEngineService)"]
        end

        subgraph Drivers["基础驱动能力 (Native Drivers)"]
            PureDart["纯 Dart 算法 (image / crypto / archive)"]
            SubProcess["底层外部进程 (FFmpeg 管道)"]
        end
    end

    Registry -->|HTTP GET 获取元数据| PM
    ZipFiles -->|下载并解压至本地目录| PM
    PM -->|构建已安装列表| Home
    Home -->|传递 Manifest 实例| DynamicRunner
    DynamicRunner -->|解析 JSON Schema 动态生成表单| DynamicRunner
    DynamicRunner -->|收集用户参数并执行| Engine
    Engine --> PureDart
    Engine --> SubProcess
    Engine -->|流式回调进度 (onProgress)| DynamicRunner
    Engine -->|返回 ProcessingResult| DynamicRunner
```

### 为什么能做到“免重新安装客户端”？
1. **界面声明化**：插件开发者不需要在客户端写 Flutter Widget。只需在 `manifest.json` 中用 JSON 声明需要哪些输入项（滑块、文件选择器、下拉框等），客户端通过 `DynamicToolRunnerPage` 在运行时自动渲染界面。
2. **引擎解耦化**：底层引擎抽象为通用的处理动作管道（如 `media_pipeline`、`image_compress`）。同一引擎只需接受动态参数即可派生出数十种具体功能（例如倒放、转码、提音、抽帧本质上都是 `media_pipeline` 的不同参数组合）。
3. **静默热加载**：下载完 `.zip` 后，客户端直接解压至本地存储目录（`app_plugins/`），并在内存中刷新索引，用户立即可以使用新功能。

---

## 2. 插件目录规范与包结构

每一个独立的功能模块必须是一个标准目录，打包前在服务端 `server_mock/plugins/` 下的组织形式如下：

```text
server_mock/plugins/
  ├── <plugin-id>/                    # 插件唯一标识目录名（必须与 manifest 中的 id 一致）
  │     ├── manifest.json             # 【必须】插件元数据、UI 规则、动作定义配置文件
  │     ├── icon.png                  # 【可选】自定义高分辨率图标（若使用系统 Icon 别名则不强求）
  │     ├── README.md                 # 【建议】功能说明文档
  │     └── assets/                   # 【可选】该工具专用的模板、静态资源或预训练权重文件
```

打包发布后，在 `server_mock/dist/` 中生成：
- `<plugin-id>-<version>.zip`：压缩包内部直接包含上述文件（根目录不得多嵌套一层文件夹）。
- `index.json`：汇总所有可用插件的元数据索引文件。

---

## 3. Manifest.json 配置全字段速查

`manifest.json` 是插件的“身份证与控制蓝图”。下面是完整的配置规范：

```json
{
  "id": "video-audio-toolbox",
  "name": "音视频格式与倒放工具",
  "version": "1.0.0",
  "category": "media",
  "description": "提供音视频通用处理指令管道，包括提取音频、视频倒放、格式互转",
  "icon": "movie",
  "author": "Toolbox Team",
  "engineType": "media_pipeline",
  "inputs": [
    {
      "id": "sourceFiles",
      "label": "选择媒体文件 (音/视频)",
      "type": "file_picker",
      "required": true,
      "allowMultiple": false,
      "allowedExtensions": ["mp4", "mkv", "mov", "avi", "mp3", "wav"]
    },
    {
      "id": "operation",
      "label": "执行操作",
      "type": "select",
      "defaultValue": "reverse_video",
      "options": [
        {"label": "视频完全倒放 (画面+音频同时倒放)", "value": "reverse_video"},
        {"label": "快速提取音频为 MP3", "value": "extract_audio"}
      ]
    }
  ],
  "action": {
    "handler": "media_pipeline",
    "params": {
      "op": "${operation}"
    }
  }
}
```

### 字段详细说明：

| 字段名 | 类型 | 必填 | 说明与取值范围 |
| :--- | :--- | :---: | :--- |
| `id` | String | **是** | 插件唯一标识符，全英文字符、中划线，如 `image-compress`、`pdf-to-image`。 |
| `name` | String | **是** | 客户端卡片展示的功能名称，如 `图片批量压缩`。 |
| `version` | String | **是** | 语义化版本号，如 `1.0.0`。客户端据此对比判断是否有更新。 |
| `category` | String | **是** | 所属分类，用于首页顶部标签过滤：`image` (图片)、`media` (音视频)、`document` (文档)、`other` (其他)。 |
| `description` | String | **是** | 简明扼要的功能简介（建议 15~40 字以内）。 |
| `icon` | String | **是** | 图标代号。支持：`compress`、`aspect_ratio`、`badge`、`movie`、`extension` 等（可由客户端持续扩充映射）。 |
| `author` | String | 否 | 开发者名称或团队署名。 |
| `engineType` | String | **是** | 底层引擎类型标记：`native_image`、`media_pipeline`、`custom`。 |
| `inputs` | Array | **是** | 动态渲染到界面的表单输入项集合（详见第 4 节）。 |
| `action` | Object | **是** | 触发处理时的引擎处理器定义与参数映射规则（详见第 5 节）。 |

---

## 4. 动态 UI 表单输入组件定义规范

客户端目前支持 5 种核心输入组件，所有组件均配置在 `inputs` 数组中。

### 4.1 文件选择器 (`type: "file_picker"`)
用于让用户从系统相册、本地磁盘选择输入文件。
```json
{
  "id": "sourceFile",
  "label": "选择原始证件照",
  "type": "file_picker",
  "required": true,
  "allowMultiple": false,
  "allowedExtensions": ["jpg", "jpeg", "png", "webp"]
}
```
- `allowMultiple`: `true` 表示支持多选（如批量压缩）；`false` 为单文件模式。
- `allowedExtensions`: 支持的后缀名数组（无需带点 `.`）。

### 4.2 下拉单选项 (`type: "select"`)
用于模式切换、背景色选择、预设方案挑选等。
```json
{
  "id": "color",
  "label": "目标底色",
  "type": "select",
  "defaultValue": "white",
  "options": [
    { "label": "白色底 (通用考试/工作)", "value": "white" },
    { "label": "蓝色底 (毕业证/社保卡)", "value": "blue" },
    { "label": "红色底 (婚姻登记/证件照)", "value": "red" }
  ]
}
```

### 4.3 滑块数值调节 (`type: "slider"`)
用于连续数值调节，如压缩质量（1~100）、羽化程度（0~10）、缩放比例等。
```json
{
  "id": "quality",
  "label": "压缩质量 (数值越小体积越小)",
  "type": "slider",
  "defaultValue": 75,
  "min": 10,
  "max": 100,
  "step": 5
}
```

### 4.4 数字输入框 (`type: "number"`)
用于离散精确尺寸输入（如目标宽度、高度、端口号等）。
```json
{
  "id": "targetWidth",
  "label": "目标宽度 (px)",
  "type": "number",
  "defaultValue": 1920
}
```

### 4.5 文本输入框 (`type: "text"`)
用于输入任意自定义字符串（如水印文本、重命名格式模板等）。
```json
{
  "id": "watermarkText",
  "label": "水印文字内容",
  "type": "text",
  "defaultValue": "版权所有"
}
```

---

## 5. Action 动作与参数模板映射机制

当用户点击界面的 **“开始执行处理”** 按钮时，客户端会：
1. 校验必填输入项，并收集用户在表单填入的所有值，组成 `_formValues` 字典。
2. 检索 `action.params` 中的模板字符串 `${varName}`，自动替换为用户界面的实际值。
3. 连同被选中的本地文件物理路径列表 `inputFiles`，统一调用 `ToolEngineService.execute(...)`。

### 模板变量映射示例：
在 `manifest.json` 中定义：
```json
"action": {
  "handler": "image_compress",
  "params": {
    "quality": "${quality}",
    "format": "${format}",
    "fixedHeader": "Toolbox_V1"
  }
}
```
若用户在界面将滑块拖到了 `60`，下拉框选了 `webp`：
最终传递给执行引擎的参数字典将完全解析为：
```dart
{
  "quality": 60,
  "format": "webp",
  "fixedHeader": "Toolbox_V1"
}
```

---

## 6. 客户端执行引擎扩展 (ToolEngineService)

所有底层计算最终都在 [`lib/services/tool_engine_service.dart`](../lib/services/tool_engine_service.dart) 中集中调度。

### 6.1 接口调度契约
每一个处理动作必须遵循如下契约签名：

```dart
static Future<ProcessingResult> _handleCustomTool(
  List<String> files,                         // 输入的文件物理路径集合
  Map<String, dynamic> params,               // 已解析好的表单参数
  String outputDir,                          // 标准输出目录 (已自动创建)
  Function(double progress, String stage)? onProgress, // 阶段进度汇报回调
) async {
  // 1. 阶段报告
  onProgress?.call(0.1, '正在准备处理...');

  // 2. 核心业务处理
  // ...
  
  // 3. 返回结构化结果
  return ProcessingResult(
    success: true,
    message: '处理成功完成！共输出 1 个文件',
    outputFiles: ['C:/path/to/result.file'],
  );
}
```

### 6.2 编写新 Handler 的三大核心守则

#### ① 规范使用 `onProgress` 回调
- 进度范围为 `0.0` 到 `1.0`，文本 `stage` 用于向用户展示当前细粒度步骤（如“正在分析色彩空间... 30%”）。
- 长时间耗时任务**必须**保持心跳汇报，避免用户以为应用卡死。

#### ② 外部子进程（如 FFmpeg）防挂死原则
调用系统外部进程（`Process.start`）时，**必须排空或消费 `stdout` 和 `stderr` 管道**：
```dart
final process = await Process.start(ffmpegPath, ffmpegArgs);

// 【重要】如果不 drain，当输出日志超过操作系统管道缓冲区 (通常 4KB~64KB) 时，
// 操作系统会挂起该进程，导致其永远无法退出！
process.stdout.drain<void>();

final stderrBuf = StringBuffer();
process.stderr.transform(const SystemEncoding().decoder).listen((data) {
  stderrBuf.write(data);
});

final exitCode = await process.exitCode;
```

#### ③ 跨平台路径与文件写出规范
- 切勿写死 Windows 反斜杠 `\`。请务必统一引入 `package:path/path.dart as p;`，使用 `p.join(outputDir, outName)`。
- 输出文件统一放置在框架提供的 `outputDir` 下（Windows 默认为用户的 `Downloads/Toolbox_Outputs`，Android 为应用的 Documents 私有目录），确保不产生权限报错。

---

## 7. 开发实战教程 1：纯配置扩充功能（无需改动客户端）

假设我们需要在无需更新客户端的情况下，新增一个 **“GIF 动图提取器 (从视频截取生成 GIF 动图)”**。

由于客户端底层已配置并支持 `media_pipeline` 外部管道引擎，我们只需要定义一个云端插件！

### 步骤 1：新建插件目录
在 `server_mock/plugins/` 下新建文件夹：`video-to-gif/`

### 步骤 2：编写 `manifest.json`
在 `server_mock/plugins/video-to-gif/manifest.json` 中填入：
```json
{
  "id": "video-to-gif",
  "name": "视频一键转 GIF 动图",
  "version": "1.0.0",
  "category": "media",
  "description": "无需安装外部播放器，快速将短视频转换为高清流畅的 GIF 动态表情包",
  "icon": "movie",
  "author": "Cloud Team",
  "engineType": "media_pipeline",
  "inputs": [
    {
      "id": "sourceVideo",
      "label": "选择源视频",
      "type": "file_picker",
      "required": true,
      "allowMultiple": false,
      "allowedExtensions": ["mp4", "mov", "mkv", "avi", "webm"]
    },
    {
      "id": "fps",
      "label": "GIF 帧率 (FPS，越高越流畅体积越大)",
      "type": "slider",
      "defaultValue": 15,
      "min": 5,
      "max": 30,
      "step": 1
    },
    {
      "id": "scaleWidth",
      "label": "目标宽度 (默认 480，高度按比例自适应)",
      "type": "number",
      "defaultValue": 480
    }
  ],
  "action": {
    "handler": "media_pipeline",
    "params": {
      "op": "to_gif",
      "fps": "${fps}",
      "width": "${scaleWidth}"
    }
  }
}
```

### 步骤 3：打包与发布
在社区仓库（`Toolbox-Community-Registry`）根目录执行：
```bash
python tools/build_registry.py
```
执行完成后，打开客户端的 **“功能中心 / 下载新工具”**，立刻就能搜索并一键下载安装此插件，点击即可正常弹出表单并运行！

---

## 8. 开发实战教程 2：开发全新底层处理能力（全链路开发）

如果我们要增加一个目前客户端完全不具备的基础算法，例如 **“文件散列值哈希计算器 (MD5 / SHA256)”**，则需要客户端引擎层配合编写底层 Dart 逻辑。

### 步骤 1：在客户端引擎增加 Handler 分发
打开 `app/lib/services/tool_engine_service.dart`：

1. 在 `execute` 方法的 `switch (handler)` 中增加分支：
```dart
case 'hash_checksum':
  return await _handleHashChecksum(inputFiles, params, outputDir, onProgress);
```

2. 编写具体处理函数：
```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';

static Future<ProcessingResult> _handleHashChecksum(
  List<String> files,
  Map<String, dynamic> params,
  String outputDir,
  Function(double, String)? onProgress,
) async {
  final algo = params['algorithm']?.toString() ?? 'md5';
  List<String> logs = [];

  for (int i = 0; i < files.length; i++) {
    final filePath = files[i];
    final file = File(filePath);
    final fileName = p.basename(filePath);

    onProgress?.call(i / files.length, '正在计算: $fileName');

    final bytes = await file.readAsBytes();
    String hashResult = '';
    if (algo == 'sha256') {
      hashResult = sha256.convert(bytes).toString();
    } else {
      hashResult = md5.convert(bytes).toString();
    }

    logs.add('$fileName\n[$algo] $hashResult');
  }

  // 输出文本校验报告
  final outReportPath = p.join(outputDir, 'checksum_report_${DateTime.now().millisecondsSinceEpoch}.txt');
  await File(outReportPath).writeAsString(logs.join('\n\n'));

  onProgress?.call(1.0, '计算完成！');
  return ProcessingResult(
    success: true,
    message: '已完成 ${files.length} 个文件的哈希计算！\n\n' + logs.take(3).join('\n\n'),
    outputFiles: [outReportPath],
  );
}
```

### 步骤 2：在服务端定义插件元数据
在 `server_mock/plugins/file-hasher/manifest.json` 中配置：
```json
{
  "id": "file-hasher",
  "name": "文件安全哈希计算器",
  "version": "1.0.0",
  "category": "other",
  "description": "极速计算任意文件的 MD5、SHA256 散列校验值，并导出校验报告",
  "icon": "extension",
  "author": "Security Team",
  "engineType": "custom",
  "inputs": [
    {
      "id": "targetFiles",
      "label": "选择待校验的文件",
      "type": "file_picker",
      "required": true,
      "allowMultiple": true,
      "allowedExtensions": []
    },
    {
      "id": "algo",
      "label": "散列算法选择",
      "type": "select",
      "defaultValue": "md5",
      "options": [
        { "label": "MD5 (通用完整性校验)", "value": "md5" },
        { "label": "SHA-256 (高安全性数字签名)", "value": "sha256" }
      ]
    }
  ],
  "action": {
    "handler": "hash_checksum",
    "params": {
      "algorithm": "${algo}"
    }
  }
}
```

### 步骤 3：打包发布
运行 `node package_plugins.js` 生成新包与 `index.json`。

---

## 9. 插件编译打包与服务端部署流程

### 9.1 本地自动化打包脚本
在社区注册表仓库中，根目录下配有自动化打包脚本 `tools/build_registry.py`。

该脚本自动完成以下工作：
1. 遍历 `plugins/` 目录下的所有插件。
2. 读取各自的 `manifest.json`，验证基本结构与必要字段。
3. 压缩打包生成纯净的标准插件包至 `packages/` 目录。
4. 计算文件的二进制 SHA256 校验码和文件体积字节数。
5. 自动汇总生成规范的 `registry/index.json` 索引文件及国内镜像加速分发地址。

运行打包：
```bash
python tools/build_registry.py
```

### 9.2 本地调试与第三方源测试
客户端支持添加自定义 Registry 源地址：
- 打开客户端的 **功能中心 / 模块市场**。
- 点击右上角的源设置，可添加局域网测试地址或个人搭建的源（例如 `http://192.168.1.100:8088/index.json`）。
- 客户端会自动探测节点延迟并支持故障一键平滑降级切换。

### 9.3 生产环境部署
通过 GitHub / Gitee 的 Git 仓库直接托管插件发布包，亦可结合 GitHub Actions 持续集成自动化打 tag 并发布到 Releases 或 jsDelivr CDN。

---

## 10. 跨平台兼容性规范 (Windows 与 Android)

| 兼容性关注点 | Windows 平台处理规范 | Android 平台处理规范 |
| :--- | :--- | :--- |
| **文件输出路径** | 使用 `getDownloadsDirectory()`，通常输出在 `C:\Users\用户名\Downloads\Toolbox_Outputs`。 | 使用 `getApplicationDocumentsDirectory()`，保存在应用沙盒，避免触碰高版本 Android Scoped Storage 强权限限制。 |
| **结果交互** | 支持点击直接调起 `explorer.exe /select, <path>` 高亮定位文件。 | 结果卡片展示详细绝对路径，并自动提供图片实时缩略图预览。 |
| **字体与高 DPI** | 已在全局配置微软雅黑及无衬线字体回退 (`Microsoft YaHei`)，杜绝字体粗细不均。 | 继承系统原生 Roboto / Noto Sans SC，保证 Material Design 3 风格。 |
| **外部命令行 (FFmpeg)** | 自动扫描系统 PATH，支持从 WinGet 默认安装路径智能回退定位。 | Android 端建议对于高频基础图像直接采用纯 Dart 算法库；复杂编解码后续可接入编译好的共享库 `.so`。 |

---

## 11. 常见问题排查与避坑指南 (FAQ)

### Q1：为什么在“功能中心”点击安装后，首页没有出现新工具？
- **检查项 1**：确认下载解压是否成功。检查应用数据目录下的 `app_plugins/` 文件夹中是否存在对应插件的文件夹，且文件夹内直接包含 `manifest.json`。
- **检查项 2**：`manifest.json` 的 JSON 格式是否合法。可以使用在线 JSON 格式化工具检测是否有逗号多余或未闭合括号。

### Q2：为什么点击“开始执行处理”提示“未识别的处理引擎动作”？
- **原因**：`manifest.json` 中配置的 `action.handler` 名称在客户端 `ToolEngineService.dart` 的 `switch` 分支中没有找到匹配项。
- **解决**：检查两处的拼写大小写是否严格一致。

### Q3：为什么音视频处理大文件时程序像卡死了一样，没有任何进展？
- **原因**：FFmpeg 处理时产生了大量日志并打满了系统的 stdout/stderr 管道缓冲区。
- **解决**：确保在启动子进程后调用了 `process.stdout.drain()`，并对 `process.stderr` 进行异步监听消费。

### Q4：为什么证件照修改底色对某些人像会出现白边或边缘有残余背景色？
- **原理与调试**：算法采用四边种子泛洪 + 欧氏色彩距离场（Distance Field）抗锯齿。
- **调优技巧**：在参数中适当增大 `feather`（羽化半径，如调至 4~6）可增加边缘柔和度；若背景光照不均匀，可在 `manifest.json` 针对该工具适当放宽色彩距离容差阈值。

---

> 如有更多扩展疑问或需求，请查阅工程源代码仓库或联系架构团队。
