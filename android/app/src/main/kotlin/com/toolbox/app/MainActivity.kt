package com.toolbox.app

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        init {
            try {
                System.loadLibrary("wasm_run_dart")
            } catch (e: Throwable) {
                android.util.Log.w("MainActivity", "Preload wasm_run_dart warning: $e")
            }
        }
    }

    private val CHANNEL = "com.toolbox.app/office_bridge"

    private val wpsPackages = listOf(
        "cn.wps.moffice_eng" to "WPS Office",
        "cn.wps.moffice_pro" to "WPS Office 专业版",
        "com.kingsoft.moffice_pro" to "WPS Office 移动版",
        "com.kingsoft.moffice_eng" to "WPS Office 国际版"
    )

    private val msPackages = listOf(
        "com.microsoft.office.officehubrow" to "Microsoft 365 (Office)",
        "com.microsoft.office.word" to "Microsoft Word",
        "com.microsoft.office.powerpoint" to "Microsoft PowerPoint",
        "com.microsoft.office.excel" to "Microsoft Excel"
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkOfficeInstalled" -> {
                    val installedList = mutableListOf<Map<String, String>>()
                    val pm = packageManager
                    val allCandidatePackages = wpsPackages + msPackages
                    for ((pkg, name) in allCandidatePackages) {
                        try {
                            pm.getPackageInfo(pkg, 0)
                            installedList.add(mapOf("package" to pkg, "name" to name))
                        } catch (_: Exception) {
                            // not installed
                        }
                    }

                    val isInstalled = installedList.isNotEmpty()
                    val primaryApp = if (isInstalled) installedList.first()["name"] else null
                    val primaryPackage = if (isInstalled) installedList.first()["package"] else null

                    result.success(
                        mapOf(
                            "isInstalled" to isInstalled,
                            "primaryName" to primaryApp,
                            "primaryPackage" to primaryPackage,
                            "installedList" to installedList
                        )
                    )
                }

                "openInOffice" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath == null) {
                        result.error("INVALID_PATH", "文件路径为空", null)
                        return@setMethodCallHandler
                    }

                    val file = File(filePath)
                    if (!file.exists()) {
                        result.error("FILE_NOT_FOUND", "文件不存在: $filePath", null)
                        return@setMethodCallHandler
                    }

                    val pm = packageManager
                    val allCandidatePackages = wpsPackages + msPackages
                    var targetPackage: String? = null
                    var targetName: String? = null

                    for ((pkg, name) in allCandidatePackages) {
                        try {
                            pm.getPackageInfo(pkg, 0)
                            targetPackage = pkg
                            targetName = name
                            break
                        } catch (_: Exception) {
                            // continue
                        }
                    }

                    if (targetPackage == null) {
                        result.success(
                            mapOf(
                                "success" to false,
                                "message" to "未检测到手机上安装 WPS Office 或 Microsoft Office 办公软件。"
                            )
                        )
                        return@setMethodCallHandler
                    }

                    try {
                        val uri: Uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.fileProvider",
                            file
                        )

                        val mimeType = when {
                            file.name.endsWith(".pptx", ignoreCase = true) -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
                            file.name.endsWith(".ppt", ignoreCase = true) -> "application/vnd.ms-powerpoint"
                            file.name.endsWith(".docx", ignoreCase = true) -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                            file.name.endsWith(".doc", ignoreCase = true) -> "application/msword"
                            file.name.endsWith(".xlsx", ignoreCase = true) -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                            file.name.endsWith(".xls", ignoreCase = true) -> "application/vnd.ms-excel"
                            else -> "*/*"
                        }

                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mimeType)
                            setPackage(targetPackage)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }

                        startActivity(intent)
                        result.success(
                            mapOf(
                                "success" to true,
                                "appName" to targetName,
                                "packageName" to targetPackage
                            )
                        )
                    } catch (e: Exception) {
                        result.success(
                            mapOf(
                                "success" to false,
                                "message" to "调起 $targetName 失败: ${e.message}"
                            )
                        )
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}
