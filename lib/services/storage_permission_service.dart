import 'dart:io';
import 'package:flutter/services.dart';

/// 跨平台存储与文件管理权限检测与申请服务
class StoragePermissionService {
  static const MethodChannel _channel = MethodChannel('com.toolbox.app/office_bridge');

  /// 检查当前是否具备完整文件访问/管理权限
  static Future<bool> checkPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('checkStoragePermission');
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 调起系统设置页或系统对话框申请【管理所有文件】权限
  static Future<void> requestPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestStoragePermission');
    } catch (_) {}
  }
}
