# 交互式插件（客户端 1.1.0）

本轮实现三种持续交互工具：`handheld-bulletin`、`windows-uninstaller`、`ssh-terminal`。

这些模块使用 `executionType: internal` 和 `action.handler` 选择编译在客户端内的页面。社区 ZIP 提供清单和图标；运行能力由 1.1.0 客户端提供。给旧客户端单独导入 ZIP 不会获得新宿主能力，因此清单必须声明 `minAppVersion: 1.1.0`。

| 插件 | handler | 平台 | 使用方式 |
| --- | --- | --- | --- |
| 手持弹幕举牌 | handheld_bulletin | Android、Windows | 编辑文字和样式，预览后进入全屏播放 |
| 软件卸载 | windows_uninstaller | Windows | 扫描、搜索软件，确认调用官方卸载器，并在卸载后受控清理残留 |
| SSH 终端 | ssh_terminal | Android、Windows | 填写目标主机、端口、用户，选择密码或私钥，核对主机指纹后连接 |

客户端统一入口为 `lib/pages/plugin_runner_page.dart`，首页三种布局都使用此入口。原有文件处理插件继续进入动态表单页面。平台与最低版本在打开页面前检查。新模块预置到默认插件列表中，注册中心同时提供可导入的清单 ZIP。

SSH 会按用户明确指定连接远端主机，网络权限在清单中声明。它不是离线工具。密码、私钥正文与私钥口令不写入连接配置；首次连接需要核对 SHA256 指纹，已记录主机的密钥变化会阻止连接。

Windows 卸载调用软件自身注册的卸载命令，可能弹出该软件向导或系统 UAC。卸载器正常退出后会自动扫描与软件名称、发布者、安装目录和精确注册表项相关的残留；候选默认不勾选，用户核对路径并再次确认后才永久删除，失败项会单独报告。受保护的系统目录和危险注册表根会被拒绝，不执行全盘模糊清理。软件列表不包含完整的 Microsoft Store 应用管理能力。

弹幕展示期间保持屏幕唤醒，退出后恢复先前唤醒状态。Android 大屏设备的强制横屏能力受系统限制；竖屏和旋转参数仍可使用。

## 验证与镜像

在正式 `Multi-Toolbox` 工作区中执行：

```powershell
flutter pub get
flutter analyze
flutter test
python -m unittest discover -s tools/tests -v
python tools/sync_to_app.py
python tools/sync_to_app.py --check
```

在正式 `Toolbox-Community-Registry` 工作区中执行 `python tools/build_registry.py`，生成三个 ZIP 并重建索引。发布时需先发布支持这些页面的客户端，再发布社区索引。

客户端以正式工作区为基础合入交互页面，保留现有 QuickJS 事件调度、WASI 输出收集与资源释放、静态检查修正及完整镜像同步。每次修改客户端后运行镜像同步，并使用 `--check` 确认 `app` 镜像一致。
