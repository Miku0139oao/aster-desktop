package app.aster.desktop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build

class AsterVpnService : android.net.VpnService() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground()
        // The VPN fd is owned here. The next stage loads the core in this
        // process and passes the descriptor through its mobile interface.
        return START_NOT_STICKY
    }

    private fun startForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    "aster_vpn",
                    "Aster VPN",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        val content = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(this, "aster_vpn")
            .setContentTitle("Aster")
            .setContentText("VPN routing is being prepared")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(content)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                1,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(1, notification)
        }
    }

    companion object {
    }
}
