package dev.localfiles.drop

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

        companion object {
            // 供 TransferService（同进程）向 Dart 推送下载目录事件的通道。
            @Volatile
            var sharedChannel: MethodChannel? = null

            fun notifyDownloaded(path: String, size: Long) {
                val channel = sharedChannel ?: return
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    channel.invokeMethod(
                        "onDownloaded",
                        mapOf("path" to path, "size" to size),
                    )
                }
            }
        }

    private val channelName = "local_file_drop/system"
    private val pickFilesRequest = 9201
    private val pickFolderRequest = 9202
    private val pickImagesRequest = 9205
    private var pendingResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        sharedChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        sharedChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFiles" -> pickFiles(result)
                "pickImages" -> pickImages(result)
                "pickFolder" -> pickFolder(result)
                "readChunk" -> readChunk(call, result)
                "hasStorageAccess" -> result.success(hasStorageAccess())
                "requestStorageAccess" -> {
                    requestStorageAccess()
                    result.success(false)
                }
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= 33) {
                        ActivityCompat.requestPermissions(this, arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 9203)
                    }
                    result.success(null)
                }
                "startBackgroundService" -> {
                    val intent = Intent(this, TransferService::class.java).setAction(TransferService.actionStart)
                    ContextCompat.startForegroundService(this, intent)
                    result.success(null)
                }
                "stopBackgroundService" -> {
                    stopService(Intent(this, TransferService::class.java))
                    result.success(null)
                }
                "hasOverlayPermission" -> result.success(canDrawOverlay())
                "requestOverlayPermission" -> {
                    requestOverlayPermission()
                    result.success(null)
                }
                "isFloatingWindowEnabled" -> result.success(
                    TransferService.preferences(this).getBoolean(TransferService.keyOverlay, false) && canDrawOverlay()
                )
                "setFloatingWindow" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled && !canDrawOverlay()) {
                        result.error("NO_OVERLAY_PERMISSION", "请先允许原传显示在其他应用上层", null)
                    } else {
                        TransferService.preferences(this).edit()
                            .putBoolean(TransferService.keyOverlay, enabled).apply()
                        val action = if (enabled) TransferService.actionOverlayShow else TransferService.actionOverlayHide
                        ContextCompat.startForegroundService(
                            this,
                            Intent(this, TransferService::class.java).setAction(action),
                        )
                        result.success(null)
                    }
                }
                "isBootAutostartEnabled" -> result.success(
                    TransferService.preferences(this).getBoolean(TransferService.keyBootAutostart, false)
                )
                "setBootAutostart" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    TransferService.preferences(this).edit()
                        .putBoolean(TransferService.keyBootAutostart, enabled).apply()
                    result.success(null)
                }
                "updateBackgroundService" -> {
                    val intent = Intent(this, TransferService::class.java)
                        .setAction(TransferService.actionUpdate)
                        .putExtra("text", call.argument<String>("text") ?: "等待传输")
                    startService(intent)
                    result.success(null)
                }
                "installApk" -> installApk(call, result)
                "openPath" -> openPath(call, result)
                else -> result.notImplemented()
            }
        }
        // 开机自启时打开引擎后立刻退到后台，保留局域网接收能力而不挡住桌面。
        if (intent?.getBooleanExtra("boot_start", false) == true) {
            intent.removeExtra("boot_start")
            mainHandler.postDelayed({ moveTaskToBack(true) }, 1500)
        }
    }

    private fun pickFiles(result: MethodChannel.Result) {
        if (!setPending(result)) return
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, pickFilesRequest)
    }

    private fun pickImages(result: MethodChannel.Result) {
        if (!setPending(result)) return
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, pickImagesRequest)
    }

    private fun pickFolder(result: MethodChannel.Result) {
        if (!setPending(result)) return
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, pickFolderRequest)
    }

    private fun setPending(result: MethodChannel.Result): Boolean {
        if (pendingResult != null) {
            result.error("BUSY", "另一个文件选择窗口尚未结束", null)
            return false
        }
        pendingResult = result
        return true
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickFilesRequest && requestCode != pickFolderRequest &&
            requestCode != pickImagesRequest) return
        val pending = pendingResult ?: return
        pendingResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.success(emptyList<Map<String, Any>>())
            return
        }
        thread(name = "LocalFileDropPicker") {
            try {
                val items = if (requestCode == pickFilesRequest ||
                    requestCode == pickImagesRequest) {
                    val uris = mutableListOf<Uri>()
                    data.clipData?.let { clip ->
                        for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
                    }
                    data.data?.let { uris.add(it) }
                    uris.distinct().map { uri ->
                        persist(uri)
                        documentItem(uri, null)
                    }
                } else {
                    val tree = data.data ?: throw IllegalArgumentException("未选择文件夹")
                    persist(tree)
                    folderItems(tree)
                }
                respond { pending.success(items) }
            } catch (error: Throwable) {
                respond { pending.error("PICK_FAILED", error.message, null) }
            }
        }
    }

    private fun persist(uri: Uri) {
        try {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: SecurityException) {
            // 某些提供方不支持持久授权；当前选择仍可读取。
        }
    }

    private fun documentItem(uri: Uri, relativePath: String?): Map<String, Any> {
        var name = "未命名文件"
        var size = -1L
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
            }
        }
        if (size < 0) {
            contentResolver.openAssetFileDescriptor(uri, "r")?.use { size = it.length }
        }
        if (size < 0) throw IllegalArgumentException("无法获取文件大小：$name")
        return mapOf(
            "uri" to uri.toString(),
            "name" to name,
            "relativePath" to (relativePath ?: name),
            "size" to size,
        )
    }

    private data class FolderNode(val tree: Uri, val documentId: String, val relativePath: String)

    private fun folderItems(tree: Uri): List<Map<String, Any>> {
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val rootUri = DocumentsContract.buildDocumentUriUsingTree(tree, rootId)
        val rootName = documentItemName(rootUri)
        val output = mutableListOf<Map<String, Any>>()
        val stack = ArrayDeque<FolderNode>()
        stack.add(FolderNode(tree, rootId, rootName))
        while (stack.isNotEmpty()) {
            val node = stack.removeLast()
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(node.tree, node.documentId)
            val cursor = contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE,
                ),
                null,
                null,
                null,
            ) ?: throw IllegalArgumentException("无法读取所选文件夹")
            cursor.use {
                while (cursor.moveToNext()) {
                    val id = cursor.getString(0)
                    val name = cursor.getString(1) ?: "未命名"
                    val mime = cursor.getString(2)
                    val relative = "${node.relativePath}/$name"
                    val documentUri = DocumentsContract.buildDocumentUriUsingTree(node.tree, id)
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        stack.add(FolderNode(node.tree, id, relative))
                    } else {
                        var size = if (cursor.isNull(3)) -1L else cursor.getLong(3)
                        if (size < 0) contentResolver.openAssetFileDescriptor(documentUri, "r")?.use { size = it.length }
                        if (size < 0) throw IllegalArgumentException("无法获取文件大小：$name")
                        output.add(mapOf(
                            "uri" to documentUri.toString(),
                            "name" to name,
                            "relativePath" to relative,
                            "size" to size,
                        ))
                    }
                }
            }
        }
        return output
    }

    private fun documentItemName(uri: Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) return cursor.getString(0)
        }
        return "所选文件夹"
    }

    private fun readChunk(call: MethodCall, result: MethodChannel.Result) {
        val uriText = call.argument<String>("uri")
        val offset = call.argument<Number>("offset")?.toLong()
        val length = call.argument<Number>("length")?.toInt()
        if (uriText == null || offset == null || length == null || offset < 0 || length <= 0) {
            result.error("BAD_ARGS", "读取参数无效", null)
            return
        }
        thread(name = "LocalFileDropReader") {
            try {
                val uri = Uri.parse(uriText)
                val descriptor = contentResolver.openFileDescriptor(uri, "r")
                    ?: throw IllegalArgumentException("无法打开源文件")
                val bytes = descriptor.use { pfd ->
                    FileInputStream(pfd.fileDescriptor).use { input ->
                        input.channel.position(offset)
                        val buffer = ByteArray(length)
                        var total = 0
                        while (total < length) {
                            val count = input.read(buffer, total, length - total)
                            if (count < 0) break
                            total += count
                        }
                        if (total == length) buffer else buffer.copyOf(total)
                    }
                }
                respond { result.success(bytes) }
            } catch (error: Throwable) {
                respond { result.error("READ_FAILED", error.message, null) }
            }
        }
    }

    private fun installApk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
            result.error("BAD_PATH", "更新包路径无效", null)
            return
        }
        try {
            val file = java.io.File(path)
            if (!file.exists()) throw IllegalArgumentException("更新包不存在")
            val apkUri: Uri
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10+ 用 MediaStore 分享 Download 目录下的包，免 FileProvider。
                val collection = android.provider.MediaStore.Downloads.getContentUri("external")
                val values = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                    put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "application/vnd.android.package-archive")
                }
                apkUri = contentResolver.insert(collection, values)
                    ?: throw IllegalStateException("无法注册更新包")
                contentResolver.openOutputStream(apkUri)?.use { out ->
                    FileInputStream(file).use { input -> input.copyTo(out) }
                }
            } else {
                @Suppress("DEPRECATION")
                apkUri = Uri.fromFile(file)
            }
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(apkUri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(null)
        } catch (error: Throwable) {
            result.error("INSTALL_FAILED", error.message, null)
        }
    }

    /// 打开本地文件：优先用系统查看器（FileProvider content uri），
    /// 没有可用查看器时回落到系统“下载内容”列表。
    private fun openPath(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
            result.success(false)
            return
        }
        try {
            val file = java.io.File(path)
            if (!file.exists()) {
                result.success(false)
                return
            }
            val uri = androidx.core.content.FileProvider.getUriForFile(
                this, "$packageName.fileprovider", file)
            val mime = android.webkit.MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(file.extension.lowercase()) ?: "*/*"
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                result.success(true)
            } else {
                openDownloads()
                result.success(true)
            }
        } catch (error: Exception) {
            try {
                openDownloads()
                result.success(true)
            } catch (fatal: Exception) {
                result.success(false)
            }
        }
    }

    private fun openDownloads() {
        startActivity(Intent(android.app.DownloadManager.ACTION_VIEW_DOWNLOADS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun canDrawOverlay(): Boolean =
        Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(this)

    private fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT >= 23) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName"),
                )
            )
        }
    }

    private fun hasStorageAccess(): Boolean {        return when {
            Build.VERSION.SDK_INT >= 30 -> Environment.isExternalStorageManager()
            else -> ContextCompat.checkSelfPermission(this, android.Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestStorageAccess() {
        if (Build.VERSION.SDK_INT >= 30) {
            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))
            startActivity(intent)
        } else {
            ActivityCompat.requestPermissions(this, arrayOf(android.Manifest.permission.WRITE_EXTERNAL_STORAGE), 9204)
        }
    }

    private fun respond(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action() else mainHandler.post(action)
    }
}
