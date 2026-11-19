package dev.localfiles.drop

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

/// 开机后台启动：系统允许时打开 Flutter 引擎后立即退到后台，
/// 同时拉起前台传输服务；部分国产系统还需手动允许“自启动/后台运行”。
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
        val preferences = TransferService.preferences(context)
        if (!preferences.getBoolean(TransferService.keyBootAutostart, false)) return

        try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, TransferService::class.java)
                    .setAction(TransferService.actionStart),
            )
        } catch (_: Throwable) {
            // Android 新版本对开机启动前台服务有限制，失败时保留通知渠道，
            // 用户手动打开仍可继续接收。
        }

        // 尝试后台启动 Activity 以创建 Dart 引擎；MainActivity 会自动退到后台。
        // 部分系统会拦截，此时前台服务与通知仍保留，用户点开即可恢复接收。
        try {
            context.startActivity(
                Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    putExtra("boot_start", true)
                }
            )
        } catch (_: Throwable) {
            // 被系统拦截时不影响后续手动启动。
        }
    }
}
