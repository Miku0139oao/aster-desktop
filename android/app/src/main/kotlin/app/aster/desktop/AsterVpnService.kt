package app.aster.desktop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.net.ConnectivityManager
import android.net.VpnService
import android.os.Binder
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import mobileapi.Host
import mobileapi.Mobileapi
import mobileapi.SocketProtector
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

class AsterVpnService : VpnService(), SocketProtector {
    companion object {
        private const val TAG = "AsterVpnService"
        private const val CHANNEL_ID = "aster_vpn"
        private const val NOTIFICATION_ID = 1
        const val ACTION_DISCONNECT = "app.aster.desktop.action.DISCONNECT"
        private const val PREFS = "aster_android"
        private const val ROUTING_KEY = "app_routing"
        private const val MAX_APPS = 512
        private val packagePattern =
            Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)*$")
        private val routeModes = setOf("proxy", "direct", "exclude")

        fun readRouting(context: Context): JSONObject {
            val encoded = context
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(ROUTING_KEY, null)
            if (encoded.isNullOrEmpty()) return defaultRouting()
            return try {
                normalizeRouting(JSONObject(encoded))
            } catch (error: Throwable) {
                Log.w(TAG, "Stored application routing is invalid; resetting", error)
                defaultRouting()
            }
        }

        fun writeRouting(context: Context, encoded: String): JSONObject {
            val routing = normalizeRouting(JSONObject(encoded))
            context
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(ROUTING_KEY, routing.toString())
                .apply()
            return routing
        }

        private fun defaultRouting() = JSONObject()
            .put("mode", "all")
            .put("apps", JSONObject())

        private fun normalizeRouting(value: JSONObject): JSONObject {
            val mode = if (value.optString("mode") == "selected") "selected" else "all"
            val apps = JSONObject()
            val source = value.optJSONObject("apps") ?: JSONObject()
            val names = source.keys().asSequence().sorted().take(MAX_APPS)
            for (name in names) {
                if (!packagePattern.matches(name)) continue
                val route = source.optString(name)
                if (route in routeModes) apps.put(name, route)
            }
            return JSONObject().put("mode", mode).put("apps", apps)
        }

        // The core uses these only as a hint: VpnService.Builder performs the
        // real per-app filtering because a detached TUN descriptor cannot
        // attribute packets to packages by itself.
        private fun packageOptions(routing: JSONObject): JSONObject {
            val selectedOnly = routing.optString("mode") == "selected"
            val include = JSONArray()
            val exclude = JSONArray()
            val apps = routing.optJSONObject("apps") ?: JSONObject()
            for (name in apps.keys()) {
                when (apps.optString(name)) {
                    "proxy" -> if (selectedOnly) include.put(name)
                    else -> exclude.put(name)
                }
            }
            return JSONObject()
                .put("includePackages", include)
                .put("excludePackages", exclude)
        }
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val binder = LocalBinder()
    private var host: Host? = null

    inner class LocalBinder : Binder() {
        fun service(): AsterVpnService = this@AsterVpnService
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onBind(intent: Intent?) = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_DISCONNECT) {
            executor.execute {
                runCatching { stopVpn() }
                    .onFailure { Log.e(TAG, "Disconnect from notification failed", it) }
            }
            return START_NOT_STICKY
        }
        startAsterForeground("Preparing connection")
        return START_NOT_STICKY
    }

    /** gomobile maps the Go interface method Protect(int32) to protect(int). */
    override fun protect(fd: Int): Boolean = super.protect(fd)

    fun call(request: String): String {
        ensureHost()
        return host?.call(request) ?: throw IllegalStateException("Aster engine is not ready")
    }

    fun startVpn(): String {
        ensureHost()
        synchronized(this) {
            val mobileHost = host ?: throw IllegalStateException("Aster engine is not ready")
            mobileHost.setProtector(this)
            applySystemDNS(mobileHost)
            val routing = readRouting(this)
            startAsterForeground("Connecting")
            // The detached descriptor is owned by the core from here on.
            val fd = buildTun(routing).detachFd()
            try {
                val encoded = mobileHost.startVPN(fd, packageOptions(routing).toString())
                updateNotification("Connected")
                Log.i(TAG, "VPN connected")
                return encoded
            } catch (error: Throwable) {
                // The descriptor was transferred to the core. Do not adopt and
                // close the same descriptor here, or a recycled descriptor
                // could be closed while the core still owns it.
                runCatching { mobileHost.stopVPN() }
                stopAsterForeground()
                Log.e(TAG, "VPN start failed", error)
                throw error
            }
        }
    }

    fun stopVpn(): String {
        val mobileHost = synchronized(this) { host }
        val response = try {
            mobileHost?.stopVPN() ?: "{\"result\":true}"
        } finally {
            stopAsterForeground()
        }
        Log.i(TAG, "VPN disconnected")
        return response
    }

    override fun onRevoke() {
        executor.execute {
            try {
                host?.stopVPN()
            } catch (error: Throwable) {
                Log.e(TAG, "Stopping the core after VPN revoke failed", error)
            } finally {
                stopAsterForeground()
            }
        }
        super.onRevoke()
    }

    override fun onDestroy() {
        val mobileHost = host
        host = null
        executor.execute {
            try {
                mobileHost?.close()
            } catch (error: Throwable) {
                Log.e(TAG, "Closing the Aster core failed", error)
            }
        }
        super.onDestroy()
    }

    private fun ensureHost() {
        if (host == null) {
            synchronized(this) {
                if (host == null) {
                    host = Mobileapi.newHost(filesDir.absolutePath)
                }
            }
        }
    }

    private fun buildTun(routing: JSONObject): ParcelFileDescriptor {
        val builder = Builder()
            .setSession("Aster")
            .setMtu(9000)
            .addAddress("198.18.0.1", 30)
            // The IPv6 default route needs an IPv6 address on the interface;
            // otherwise IPv6 sockets have no source address and fail before
            // falling back to IPv4.
            .addAddress("fdfe:dcba:9876::1", 126)
            .addDnsServer("198.18.0.2")
            .addDnsServer("fdfe:dcba:9876::2")
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
        val apps = routing.optJSONObject("apps") ?: JSONObject()
        if (routing.optString("mode") == "selected") {
            var allowed = 0
            for (name in apps.keys()) {
                if (apps.optString(name) != "proxy") continue
                if (addApplication(builder, name, allowed = true)) allowed++
            }
            if (allowed == 0) {
                throw IllegalStateException(
                    "Select at least one application to proxy, or turn off selected applications only",
                )
            }
        } else {
            // The VPN must never capture its own management traffic. Sockets
            // used by the core are also passed through protect().
            runCatching { builder.addDisallowedApplication(packageName) }
            for (name in apps.keys()) {
                if (apps.optString(name) == "proxy") continue
                addApplication(builder, name, allowed = false)
            }
        }
        return builder.establish()
            ?: throw IllegalStateException("Android refused the VPN connection")
    }

    private fun addApplication(builder: Builder, name: String, allowed: Boolean): Boolean {
        return try {
            if (allowed) builder.addAllowedApplication(name)
            else builder.addDisallowedApplication(name)
            true
        } catch (error: Throwable) {
            // A package can be uninstalled between selection and connecting.
            Log.w(TAG, "Skipping unavailable package $name", error)
            false
        }
    }

    private fun applySystemDNS(mobileHost: Host) {
        val servers = try {
            val manager = getSystemService(ConnectivityManager::class.java)
            if (manager == null) {
                ""
            } else {
                val network = manager.activeNetwork
                if (network == null) {
                    ""
                } else {
                    manager.getLinkProperties(network)?.dnsServers
                        ?.mapNotNull { it.hostAddress }
                        ?.joinToString(",")
                        .orEmpty()
                }
            }
        } catch (error: Throwable) {
            Log.w(TAG, "Could not read the active DNS servers", error)
            ""
        }
        val value = servers.ifBlank { "1.1.1.1,8.8.8.8" }
        try {
            mobileHost.setSystemDNS(value)
        } catch (error: Throwable) {
            Log.w(TAG, "Core system DNS initialization failed", error)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Aster VPN", NotificationManager.IMPORTANCE_LOW),
        )
    }

    private fun notification(message: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val content = launch?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        val disconnect = PendingIntent.getService(
            this,
            1,
            Intent(this, AsterVpnService::class.java).setAction(ACTION_DISCONNECT),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        builder
            .setContentTitle("Aster")
            .setContentText(message)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                    "Disconnect",
                    disconnect,
                ).build(),
            )
        content?.let(builder::setContentIntent)
        return builder.build()
    }

    private fun startAsterForeground(message: String) {
        val value = notification(message)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, value, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, value)
        }
    }

    private fun updateNotification(message: String) {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        manager.notify(NOTIFICATION_ID, notification(message))
    }

    private fun stopAsterForeground() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }
}
