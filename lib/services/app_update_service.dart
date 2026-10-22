import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'plugin_manager_service.dart';

class AppPlatformUpdate {
  final String url;
  final List<String> mirrors;
  final String sha256;
  final String installType; // 'apk_installer' or 'zip_replace'

  AppPlatformUpdate({
    required this.url,
    this.mirrors = const [],
    this.sha256 = '',
    required this.installType,
  });

  factory AppPlatformUpdate.fromJson(Map<String, dynamic> json) {
    return AppPlatformUpdate(
      url: json['url']?.toString() ?? '',
      mirrors: (json['mirrors'] as List?)?.map((e) => e.toString()).toList() ?? [],
      sha256: json['sha256']?.toString() ?? '',
      installType: json['installType']?.toString() ?? '',
    );
  }
}

class AppUpdateInfo {
  final String latestVersion;
  final String minRequiredVersion;
  final String releaseDate;
  final String title;
  final String releaseNotes;
  final bool hasUpdate;
  final AppPlatformUpdate? platformUpdate;

  AppUpdateInfo({
    required this.latestVersion,
    required this.minRequiredVersion,
    required this.releaseDate,
    required this.title,
    required this.releaseNotes,
    required this.hasUpdate,
    this.platformUpdate,
  });
}

class AppUpdateService {
  static final AppUpdateService _instance = AppUpdateService._internal();
  factory AppUpdateService() => _instance;
  AppUpdateService._internal();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 40),
  ));

  /// 检查网络最新版本 (支持多镜像节点自动故障平滑转移)
  Future<AppUpdateInfo?> checkUpdate({String? directUrl}) async {
    final urlsToTry = <String>[];
    if (directUrl != null && directUrl.trim().isNotEmpty) {
      urlsToTry.add(directUrl);
    } else {
      urlsToTry.add(PluginManagerService().currentActiveNode.appVersionUrl);
      for (final n in PluginManagerService().allNodes) {
        if (!urlsToTry.contains(n.appVersionUrl)) {
          urlsToTry.add(n.appVersionUrl);
        }
      }
    }

    for (final targetUrl in urlsToTry) {
      try {
        final response = await _dio.get(
          targetUrl,
          options: Options(receiveTimeout: const Duration(seconds: 8)),
        );
        if (response.statusCode == 200) {
          final data = response.data is String ? jsonDecode(response.data) : response.data;
          final map = data is Map<String, dynamic> ? data : Map<String, dynamic>.from(data);

          final latestVer = map['latestVersion']?.toString() ?? '1.0.0';
          final hasUpdate = PluginManagerService.compareVersions(latestVer, PluginManagerService.currentAppVersion) > 0;

          AppPlatformUpdate? platUpdate;
          final platforms = map['platforms'] as Map?;
          if (platforms != null) {
            final platKey = Platform.isWindows ? 'windows' : (Platform.isAndroid ? 'android' : 'universal');
            if (platforms.containsKey(platKey)) {
              platUpdate = AppPlatformUpdate.fromJson(Map<String, dynamic>.from(platforms[platKey]));
            }
          }

          return AppUpdateInfo(
            latestVersion: latestVer,
            minRequiredVersion: map['minRequiredVersion']?.toString() ?? '1.0.0',
            releaseDate: map['releaseDate']?.toString() ?? '',
            title: map['title']?.toString() ?? '发现百宝箱新版本',
            releaseNotes: map['releaseNotes']?.toString() ?? '无更新日志说明',
            hasUpdate: hasUpdate,
            platformUpdate: platUpdate,
          );
        }
      } catch (e) {
        debugPrint('从 $targetUrl 检查客户端在线更新失败: $e');
      }
    }
    return null;
  }

  /// 下载并执行客户端升级
  Future<bool> downloadAndInstallUpdate(
    AppPlatformUpdate update, {
    required Function(double progress, String status) onProgress,
  }) async {
    final candidateUrls = [update.url, ...update.mirrors];
    final tempDir = await getTemporaryDirectory();

    for (int i = 0; i < candidateUrls.length; i++) {
      final currentUrl = candidateUrls[i];
      if (currentUrl.trim().isEmpty) continue;

      try {
        onProgress(0.05, '正在连接更新源 (${i + 1}/${candidateUrls.length})...');

        if (Platform.isAndroid) {
          // Android APK 下载并调起安装
          final savePath = p.join(tempDir.path, 'toolbox-update.apk');
          if (File(savePath).existsSync()) {
            try {
              File(savePath).deleteSync();
            } catch (_) {}
          }

          await _dio.download(
            currentUrl,
            savePath,
            onReceiveProgress: (rec, total) {
              if (total > 0) {
                final prog = 0.1 + (rec / total) * 0.85;
                onProgress(prog, '正在下载最新安装包: ${(rec / 1024 / 1024).toStringAsFixed(1)} MB / ${(total / 1024 / 1024).toStringAsFixed(1)} MB');
              }
            },
          );

          onProgress(0.98, '下载完成，正在调起系统安装器...');
          final result = await OpenFilex.open(savePath);
          return result.type == ResultType.done;
        } else if (Platform.isWindows) {
          // Windows 便携包下载、解压并通过独立脚本热替换
          final isZip = currentUrl.toLowerCase().endsWith('.zip');
          final savePath = p.join(tempDir.path, isZip ? 'toolbox-update.zip' : 'toolbox-update.exe');
          if (File(savePath).existsSync()) {
            try {
              File(savePath).deleteSync();
            } catch (_) {}
          }

          await _dio.download(
            currentUrl,
            savePath,
            onReceiveProgress: (rec, total) {
              if (total > 0) {
                final prog = 0.1 + (rec / total) * 0.75;
                onProgress(prog, '正在下载最新客户端: ${(rec / 1024 / 1024).toStringAsFixed(1)} MB / ${(total / 1024 / 1024).toStringAsFixed(1)} MB');
              }
            },
          );

          if (isZip) {
            onProgress(0.88, '正在解压新版本文件...');
            final extractedDir = Directory(p.join(tempDir.path, 'toolbox_new_release'));
            if (extractedDir.existsSync()) {
              extractedDir.deleteSync(recursive: true);
            }
            extractedDir.createSync(recursive: true);

            final bytes = await File(savePath).readAsBytes();
            final archive = ZipDecoder().decodeBytes(bytes);
            for (final file in archive) {
              final filename = file.name;
              if (file.isFile) {
                final data = file.content as List<int>;
                final outFile = File(p.join(extractedDir.path, filename));
                outFile.parent.createSync(recursive: true);
                await outFile.writeAsBytes(data);
              } else {
                Directory(p.join(extractedDir.path, filename)).createSync(recursive: true);
              }
            }

            onProgress(0.95, '正在启动升级替换助手并重启应用...');
            final currentAppDir = p.dirname(Platform.resolvedExecutable);

            // 写入伴生升级脚本 apply_update.bat
            final batFile = File(p.join(tempDir.path, 'apply_update.bat'));
            final batContent = '''
@echo off
chcp 65001 >nul
echo 正在等待原百宝箱客户端退出...
timeout /t 2 /nobreak >nul
taskkill /F /IM app.exe >nul 2>&1
echo 正在覆盖更新文件...
xcopy /s /y /e "${extractedDir.path}\\*" "$currentAppDir\\"
echo 更新完成，重新拉起百宝箱...
start "" "$currentAppDir\\app.exe"
exit
''';
            await batFile.writeAsString(batContent);
            await Process.start('cmd.exe', ['/c', batFile.path], mode: ProcessStartMode.detached);
            exit(0);
          } else {
            // 单独可执行安装程序
            onProgress(0.98, '正在调起安装程序...');
            await OpenFilex.open(savePath);
            return true;
          }
        }
        return true;
      } catch (e) {
        debugPrint('更新源下载失败 $currentUrl: $e，尝试下一个镜像节点');
      }
    }
    return false;
  }
}
