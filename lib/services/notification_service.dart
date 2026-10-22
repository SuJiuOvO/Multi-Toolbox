import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'settings_service.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  int _notificationCounter = 100;

  Future<void> init() async {
    if (_initialized) return;

    try {
      AndroidInitializationSettings? androidSettings;
      WindowsInitializationSettings? windowsSettings;

      if (!kIsWeb) {
        if (Platform.isAndroid) {
          androidSettings = const AndroidInitializationSettings('@mipmap/ic_launcher');
        } else if (Platform.isWindows) {
          windowsSettings = const WindowsInitializationSettings(
            appName: 'MultiToolbox',
            appUserModelId: 'SuJiuOvO.MultiToolbox.App.1',
            guid: 'e0d7c71e-b816-47b2-a4f6-8c4d2994e095',
          );
        }
      }

      final initSettings = InitializationSettings(
        android: androidSettings,
        windows: windowsSettings,
      );

      await _notificationsPlugin.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: (response) {
          debugPrint('Notification clicked: ${response.payload}');
        },
      );

      _initialized = true;

      // 在 Android 上创建通知渠道
      if (!kIsWeb && Platform.isAndroid) {
        final androidPlugin = _notificationsPlugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        if (androidPlugin != null) {
          await androidPlugin.createNotificationChannel(
            const AndroidNotificationChannel(
              'toolbox_task_channel',
              '任务处理通知',
              description: '文件转换、音视频压缩及数据处理完成提醒',
              importance: Importance.high,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('NotificationService init error: $e');
    }
  }

  Future<bool> requestPermission() async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final androidPlugin = _notificationsPlugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        final granted = await androidPlugin?.requestNotificationsPermission();
        return granted ?? false;
      }
      return true;
    } catch (e) {
      debugPrint('requestPermission error: $e');
      return false;
    }
  }

  Future<void> showTaskNotification({
    required String title,
    required String body,
    bool isSuccess = true,
    String? payload,
  }) async {
    // 检查用户是否在设置中开启了通知
    if (!SettingsService().notifyOnComplete) {
      return;
    }

    if (!_initialized) {
      await init();
    }

    try {
      final id = _notificationCounter++;

      const androidDetails = AndroidNotificationDetails(
        'toolbox_task_channel',
        '任务处理通知',
        channelDescription: '文件转换、音视频压缩及数据处理完成提醒',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      );

      const notificationDetails = NotificationDetails(
        android: androidDetails,
      );

      await _notificationsPlugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: notificationDetails,
        payload: payload,
      );
    } catch (e) {
      debugPrint('showTaskNotification error: $e');
    }
  }
}
