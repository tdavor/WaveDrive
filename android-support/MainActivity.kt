package com.wavedrive.wavedrive

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URL
import javax.net.ssl.HttpsURLConnection

class MainActivity : AudioServiceActivity() {
    private val channelName = "wavedrive/update"
    private var downloading = false
    private val apkFile get() = File(cacheDir, "updates/wavedrive.apk")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "device" -> {
                        @Suppress("DEPRECATION")
                        val info = packageManager.getPackageInfo(packageName, 0)
                        result.success(mapOf("abi" to Build.SUPPORTED_ABIS.firstOrNull(),
                            "version" to info.versionName))
                    }
                    "download" -> {
                        val address = call.argument<String>("url") ?: ""
                        if (downloading) {
                            result.error("BUSY", "Download already running", null)
                        } else if (!address.startsWith("https://github.com/tdavor/WaveDrive/releases/download/")) {
                            result.error("URL", "Unexpected update source", null)
                        } else {
                            downloading = true
                            Thread {
                                try {
                                    apkFile.parentFile?.mkdirs()
                                    val temp = File(apkFile.parentFile, "download.apk")
                                    try {
                                        var url = URL(address)
                                        var done = false
                                        for (i in 0..5) {
                                            require(url.protocol == "https" && (url.host == "github.com" || url.host == "release-assets.githubusercontent.com" || url.host == "objects.githubusercontent.com"))
                                            val connection = url.openConnection() as HttpsURLConnection
                                            connection.instanceFollowRedirects = false
                                            connection.connectTimeout = 15000
                                            connection.readTimeout = 30000
                                            try {
                                                val status = connection.responseCode
                                                if (status in 300..399) {
                                                    url = URL(url, connection.getHeaderField("Location") ?: error("Missing redirect"))
                                                    continue
                                                }
                                                check(status == 200) { "HTTP $status" }
                                                connection.inputStream.use { input ->
                                                    temp.outputStream().use { out ->
                                                        val buffer = ByteArray(65536)
                                                        var total = 0L
                                                        while (true) {
                                                            val n = input.read(buffer)
                                                            if (n < 0) break
                                                            total += n
                                                            check(total <= 250L * 1024 * 1024) { "APK too large" }
                                                            out.write(buffer, 0, n)
                                                        }
                                                    }
                                                }
                                                done = true
                                                break
                                            } finally { connection.disconnect() }
                                        }
                                        check(done) { "Too many redirects" }
                                        verify(temp)
                                        apkFile.delete()
                                        check(temp.renameTo(apkFile)) { "Cannot store update" }
                                    } finally { temp.delete() }
                                    runOnUiThread { downloading = false; result.success(true) }
                                } catch (e: Exception) {
                                    runOnUiThread { downloading = false; result.error("DOWNLOAD", e.message, null) }
                                }
                            }.start()
                        }
                    }
                    "install" -> {
                        try {
                            verify(apkFile)
                            if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                                result.success("permission")
                            } else {
                                val uri = FileProvider.getUriForFile(this, "$packageName.updates", apkFile)
                                startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                result.success("installer")
                            }
                        } catch (e: Exception) { result.error("INSTALL", e.message, null) }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION")
    private fun verify(file: File) {
        require(file.isFile) { "Update file missing" }
        val installed = packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
        val archive = packageManager.getPackageArchiveInfo(file.absolutePath, PackageManager.GET_SIGNATURES)
            ?: error("Invalid APK")
        check(archive.packageName == packageName) { "Wrong application package" }
        val oldCode = if (Build.VERSION.SDK_INT >= 28) installed.longVersionCode else installed.versionCode.toLong()
        val newCode = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
        check(newCode > oldCode) { "APK is not newer" }
        val installedSignatures = installed.signatures?.map { it.toCharsString() }?.toSet().orEmpty()
        val archiveSignatures = archive.signatures?.map { it.toCharsString() }?.toSet().orEmpty()
        check(installedSignatures.isNotEmpty() && installedSignatures == archiveSignatures) { "APK signing certificate differs" }
    }
}
