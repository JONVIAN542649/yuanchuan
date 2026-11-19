package dev.localfiles.drop

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.os.FileObserver
import java.io.File
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlin.math.abs

class TransferService : Service() {
    companion object {
        const val actionStart = "local_file_drop.START"
        const val actionUpdate = "local_file_drop.UPDATE"
        const val actionOverlayShow = "local_file_drop.OVERLAY_SHOW"
        const val actionOverlayHide = "local_file_drop.OVERLAY_HIDE"
        const val actionOverlayBadge = "local_file_drop.OVERLAY_BADGE"

        const val prefsName = "local_file_drop_native"
        const val keyOverlay = "floating_window"
        const val keyBootAutostart = "boot_autostart"

        private const val channelId = "file_transfer"
        private const val notificationId = 761

        fun preferences(context: Context) =
            context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var downloadObserver: FileObserver? = null
    private var windowManager: WindowManager? = null
    private var floatingView: View? = null
    private var statusDot: TextView? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        val action = intent?.action
        if (action == actionOverlayHide) {
            preferences(this).edit().putBoolean(keyOverlay, false).apply()
            removeFloating()
        } else if (action == actionOverlayShow) {
            preferences(this).edit().putBoolean(keyOverlay, true).apply()
        }

        val text = intent?.getStringExtra("text") ?: "等待传输"
        val notification = buildNotification(text)
        ServiceCompat.startForeground(
            this,
            notificationId,
            notification,
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
        )
        acquireMulticastLock()
        acquireWifiLock()
        startDownloadObserver()
        updateWakeLock(text)

        if (action == actionOverlayBadge) {
            setBadge(intent?.getIntExtra("count", 0) ?: 0)
        } else if (action == actionOverlayShow ||
            preferences(this).getBoolean(keyOverlay, false)
        ) {
            showFloating()
        }
        return START_STICKY
    }

    private fun buildNotification(text: String) = NotificationCompat.Builder(this, channelId)
        .setContentTitle("原传")
        .setContentText(text)
        .setSmallIcon(android.R.drawable.stat_sys_download)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setCategory(NotificationCompat.CATEGORY_SERVICE)
        .setContentIntent(PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        ))
        .build()

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(channelId, "文件传输", NotificationManager.IMPORTANCE_LOW)
            channel.description = "保持局域网文件在后台原样传输"
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun updateWakeLock(text: String) {
        if (text == "等待传输") {
            wakeLock?.let { if (it.isHeld) it.release() }
            return
        }
        if (wakeLock?.isHeld != true) {
            val manager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = manager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "LocalFileDrop:Transfer").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld != true) {
            val manager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = manager.createMulticastLock("LocalFileDropDiscovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    /// 高性能 Wi-Fi 锁：锁屏后 Wi-Fi 休眠/降速是手机传输不稳、变慢的主因之一。
    @Suppress("DEPRECATION")
    private fun acquireWifiLock() {
        if (wifiLock?.isHeld != true) {
            val manager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = manager.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "LocalFileDrop:Transfer",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    /// 监听系统下载目录：新图片/新文件（写完或移入）推给 Dart 自动同步。
    /// 具体开关与去重在 Dart 侧（AutoSyncService）处理。
    private fun startDownloadObserver() {
        if (downloadObserver != null) return
        val dir = File(
            android.os.Environment.getExternalStoragePublicDirectory(
                android.os.Environment.DIRECTORY_DOWNLOADS,
            ).absolutePath,
        )
        if (!dir.exists()) return
        val mask = FileObserver.CLOSE_WRITE or FileObserver.MOVED_TO
        downloadObserver = object : FileObserver(dir, mask) {
            override fun onEvent(event: Int, path: String?) {
                if (path == null) return
                val full = File(dir, path)
                if (!full.isFile || full.length() == 0L) return
                MainActivity.notifyDownloaded(full.absolutePath, full.length())
            }
        }
        downloadObserver!!.startWatching()
    }

    private fun stopDownloadObserver() {
        downloadObserver?.stopWatching()
        downloadObserver = null
    }

    private fun canDrawOverlay(): Boolean =
        Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(this)

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    private fun showFloating() {
        if (!canDrawOverlay() || floatingView != null) return
        val manager = windowManager ?: return
        if (Build.VERSION.SDK_INT >= 26 &&
            !Settings.canDrawOverlays(this)
        ) return

        val size = dp(56)
        val frame = FrameLayout(this)
        val bubble = TextView(this).apply {
            text = "∞"
            setTextColor(Color.WHITE)
            textSize = 25f
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#087F8C"))
                setStroke(dp(2), Color.WHITE)
            }
        }
        frame.addView(bubble, FrameLayout.LayoutParams(size, size))

        val dotSize = dp(15)
        val dot = TextView(this).apply {
            text = ""
            visibility = View.GONE
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#E53935"))
                setStroke(dp(2), Color.WHITE)
            }
        }
        frame.addView(
            dot,
            FrameLayout.LayoutParams(
                dotSize,
                dotSize,
                Gravity.TOP or Gravity.END,
            ),
        )
        statusDot = dot

        val type = if (Build.VERSION.SDK_INT >= 26) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val params = WindowManager.LayoutParams(
            size,
            size,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = resources.displayMetrics.widthPixels - size - dp(12)
            y = resources.displayMetrics.heightPixels / 3
        }

        var downRawX = 0f
        var downRawY = 0f
        var startX = 0
        var startY = 0
        var moved = false
        frame.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startX = params.x
                    startY = params.y
                    moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY
                    if (abs(dx) > dp(4) || abs(dy) > dp(4)) moved = true
                    if (moved) {
                        params.x = startX + dx.toInt()
                        params.y = startY + dy.toInt()
                        try {
                            manager.updateViewLayout(frame, params)
                        } catch (_: Throwable) {
                            // 窗口被系统回收时忽略拖动更新。
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) openApp()
                    true
                }
                else -> false
            }
        }

        try {
            manager.addView(frame, params)
            floatingView = frame
        } catch (error: Throwable) {
            removeFloating()
        }
    }

    private fun setBadge(count: Int) {
        val dot = statusDot ?: return
        dot.text = if (count > 0) "" else ""
        dot.visibility = if (count > 0) View.VISIBLE else View.GONE
    }

    private fun openApp() {
        try {
            startActivity(
                Intent(this, MainActivity::class.java).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP
                    )
                }
            )
        } catch (_: Throwable) {
            // 系统限制后台启动时，用户仍可从通知进入。
        }
    }

    private fun removeFloating() {
        val view = floatingView
        val manager = windowManager
        if (view != null && manager != null) {
            try {
                manager.removeView(view)
            } catch (_: Throwable) {
                // 已被系统移除。
            }
        }
        floatingView = null
        statusDot = null
    }

    override fun onDestroy() {
        removeFloating()
        wakeLock?.let { if (it.isHeld) it.release() }
        multicastLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        multicastLock = null
        wifiLock = null
        stopDownloadObserver()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
