import 'dart:io';
import 'package:flutter/services.dart';

/// Android 平台办公软件（WPS Office / Microsoft Office）交互桥接器
class AndroidOfficeBridge {
  AndroidOfficeBridge._();

  static const MethodChannel _channel = MethodChannel('com.toolbox.app/office_bridge');

  /// 检查 Android 设备上是否安装了 WPS Office 或 Microsoft Office
  static Future<Map<String, dynamic>> checkOfficeInstalled() async {
    if (!Platform.isAndroid) {
      return {'isInstalled': false, 'installedList': []};
    }
    try {
      final res = await _channel.invokeMethod<Map>('checkOfficeInstalled');
      return Map<String, dynamic>.from(res ?? {});
    } catch (e) {
      return {'isInstalled': false, 'error': e.toString(), 'installedList': []};
    }
  }

  /// 直接在手机 WPS Office 或 Microsoft Office 中打开目标文档
  static Future<Map<String, dynamic>> openInOffice(String filePath) async {
    if (!Platform.isAndroid) {
      return {'success': false, 'message': '当前非 Android 设备'};
    }
    try {
      final res = await _channel.invokeMethod<Map>('openInOffice', {'filePath': filePath});
      return Map<String, dynamic>.from(res ?? {});
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }
}
