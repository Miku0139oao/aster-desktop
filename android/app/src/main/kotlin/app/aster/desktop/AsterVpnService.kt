package app.aster.desktop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Binder
import android.os.Build
import android.os.ParcelFileDescriptor
import mobileapi.MobileHost
import mobileapi.SocketProtector
import java.util.concurrent.Executors

class AsterVpnService : VpnService(), SocketProtector {
    private val executor = Executors.newSingleThreadExecutor()
    private val binder = LocalBinder()
    private var host: MobileHost? = null
    private var tun: ParcelFileDescriptor? = null

    inner class LocalBinder : Binder() {
        fun service(): AsterVpnService = this@AsterVpnService
    }

    override fun onBind(intent: Intent?) = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsterForeground("Preparing connection")
        return START_NOT_STICKY
    }

    override fun Protect(fd: Int): Boolean = protect(fd)

    fun call(request: String): String {
        ensureHost()
        return host?.call(request) ?: throw IllegalStateException("Aster engine is not ready")
    }

    fun startVpn(): String {
        ensureHost()
        synchronized(this) {
            val mobileHost = host ?: throw IllegalStateException("Aster engine is not ready")
            mobileHost.setProtector(this)
            startAsterForeground("Connecting")
            val descriptor = buildTun()
            try {
                val fd = descriptor.detachFd()
                try {
                    return mobileHost.startVPN(fd.toLong())
                } catch (error: Throwable) {
                    ParcelFileDescriptor.adoptFd(fd).close()
                    throw error
                }
            } finally {
                if (tun != null) {
                    tun?.close()
                    tun = null
                }
            }
        }
    }

    fun stopVpn(): String {
        val mobileHost = synchronized(this) { host }
        val response = mobileHost?.stopVPN() ?: "{\"result\":true}"
        tun?.close()
        tun = null
        return response
    }

    override fun onRevoke() {
        executor.execute {
            try {
                host?.stopVPN()
            } catch (_: Throwable) {
            } finally {
                tun?.close()
                tun = null
            }
        }
        super.onRevoke()
    }

    override fun onDestroy() {
        executor.execute {
            try {
                host?.close()
            } catch (_: Throwable) {
            }
        }
        host = null
        super.onDestroy()
    }

    private fun ensureHost() {
        if (host == null) {
            synchronized(this) {
                if (host == null) {
                    host = MobileHost.newHost(filesDir.absolutePath)
                }
            }
        }
    }

    private fun buildTun(): ParcelFileDescriptor {
        val builder = Builder()
            .setSession("Aster")
            .setMtu(9000)
            .addAddress("198.18.0.1", 30)
            .addDnsServer("198.18.0.2")
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
        val descriptor = builder.establish() ?: throw IllegalStateException("Android refused the VPN connection")
        tun = descriptor
        return descriptor
    }

    private fun startAsterForeground(message: String) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel("aster_vpn", "Aster VPN", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val content = launch?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        val notification = Notification.Builder(this, "aster_vpn")
            .setContentTitle("Aster")
            .setContentText(message)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(content)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(1, notification)
        }
    }
}
