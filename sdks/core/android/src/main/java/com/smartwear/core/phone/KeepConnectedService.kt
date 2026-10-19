package com.smartwear.core.phone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.smartwear.core.ConnectionState
import com.smartwear.core.DeviceManager
import com.smartwear.core.SmartWearLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch

/**
 * Foreground service (loại connectedDevice) giữ tiến trình sống khi app chạy nền, để kết nối BLE không bị hệ thống cắt
 * (đã gặp: lowmemorykiller tắt app đang chạy nền lúc 18:03 ngày 2026-10-13, mất kết nối Y25). Khai báo sẵn trong manifest
 * của core. Thông báo dùng tên app và mở màn khởi động của app; nội dung theo số thiết bị đang kết nối của [DeviceManager]
 * truyền vào [bind].
 */
class KeepConnectedService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onBind(intent: Intent?): IBinder? = null

    @OptIn(ExperimentalCoroutinesApi::class)
    override fun onCreate() {
        super.onCreate()
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(
            NotificationChannel(CHANNEL, "Kết nối thiết bị", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Giữ kết nối Bluetooth với thiết bị đeo khi app chạy nền"
            },
        )
        val notification = build("Đang giữ kết nối thiết bị")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(ID, notification)
        }
        // Cập nhật nội dung thông báo theo số thiết bị đang kết nối.
        val deviceManager = manager ?: return
        scope.launch {
            deviceManager.devices
                .flatMapLatest { list -> if (list.isEmpty()) flowOf(emptyList()) else combine(list.map { it.state }) { it.toList() } }
                .collect { states ->
                    val connected = states.count { it == ConnectionState.CONNECTED }
                    val text = if (connected > 0) "Đang giữ kết nối $connected thiết bị" else "Đang chờ thiết bị kết nối lại"
                    notifications.notify(ID, build(text))
                }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun build(text: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val open = launch?.let { PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE) }
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle(applicationInfo.loadLabel(packageManager))
            .setContentText(text)
            .apply { open?.let { setContentIntent(it) } }
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL = "connections"
        private const val ID = 1

        @Volatile
        private var manager: DeviceManager? = null

        fun start(context: Context) {
            context.startForegroundService(Intent(context, KeepConnectedService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KeepConnectedService::class.java))
        }

        private var bound = false

        /**
         * Bật service khi [DeviceManager.keepConnected] > 0, tắt khi về 0. Gọi khi app đang ở foreground (Android 12+ không cho
         * bật foreground service từ nền); gọi lại không làm gì.
         */
        fun bind(context: Context, manager: DeviceManager, scope: CoroutineScope) {
            this.manager = manager
            if (bound) return
            bound = true
            val app = context.applicationContext
            scope.launch {
                manager.keepConnected.collect { count ->
                    runCatching { if (count > 0) start(app) else stop(app) }
                        .onFailure { SmartWearLog.w("Không bật được foreground service: ${it.message}") }
                }
            }
        }
    }
}
