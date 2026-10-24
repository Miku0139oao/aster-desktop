package app.aster.desktop

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "app.astercore/android"
        private const val NOTIFICATION_REQUEST = 41
        private const val VPN_REQUEST = 42
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val serviceLock = Any()
    private var service: AsterVpnService? = null
    private var bound = false
    private var vpnResult: MethodChannel.Result? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            synchronized(serviceLock) {
                service = (binder as? AsterVpnService.LocalBinder)?.service()
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            synchronized(serviceLock) {
                service = null
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "call" -> executor.execute {
                        val request = call.argument<String>("request") ?: "{}"
                        runCatching { awaitService().call(request) }
                            .onSuccess(result::success)
                            .onFailure { result.error("operation", describe(it), null) }
                    }
                    "listApplications" -> executor.execute {
                        runCatching { InstalledApplications.list(this) }
                            .onSuccess(result::success)
                            .onFailure { result.error("operation", describe(it), null) }
                    }
                    "appRouting" -> result.success(
                        AsterVpnService.readRouting(this).toString(),
                    )
                    "saveAppRouting" -> executor.execute {
                        val encoded = call.argument<String>("routing")
                        if (encoded == null) {
                            result.error("operation", "Application routing is missing", null)
                        } else {
                            runCatching { AsterVpnService.writeRouting(this, encoded).toString() }
                                .onSuccess(result::success)
                                .onFailure { result.error("operation", describe(it), null) }
                        }
                    }
                    "startVpn" -> prepareVpn(result)
                    "stopVpn" -> executor.execute {
                        runCatching { awaitService().stopVpn() }
                            .onSuccess(result::success)
                            .onFailure { result.error("operation", describe(it), null) }
                    }
                    else -> result.notImplemented()
                }
            }
        bound = bindService(
            Intent(this, AsterVpnService::class.java),
            connection,
            Context.BIND_AUTO_CREATE,
        )
    }

    private fun prepareVpn(result: MethodChannel.Result) {
        // Ask for notifications first. Showing both system dialogs at once
        // delays the foreground service start until the second one closes.
        if (needsNotificationPermission()) {
            val previous = vpnResult
            if (previous != null) {
                previous.error("vpn_busy", "Another VPN permission request is pending", null)
            }
            vpnResult = result
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_REQUEST,
            )
            return
        }
        beginVpnConsent(result)
    }

    private fun beginVpnConsent(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            val previous = vpnResult
            if (previous != null) {
                previous.error("vpn_busy", "Another VPN permission request is pending", null)
            }
            vpnResult = result
            try {
                startActivityForResult(intent, VPN_REQUEST)
            } catch (error: Throwable) {
                vpnResult = null
                result.error("operation", describe(error), null)
            }
        } else {
            connectVpn(result)
        }
    }

    private fun connectVpn(result: MethodChannel.Result?) {
        val pending = result ?: return
        executor.execute {
            try {
                // A started service keeps running after the activity is
                // backgrounded or destroyed; binding only provides RPC.
                val intent = Intent(this, AsterVpnService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }
                pending.success(awaitService().startVpn())
            } catch (error: Throwable) {
                pending.error("operation", describe(error), null)
            }
        }
    }

    @Deprecated("FlutterActivity does not expose the Activity Result registry")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_REQUEST) return
        val pending = vpnResult
        vpnResult = null
        if (resultCode == RESULT_OK) {
            connectVpn(pending)
        } else if (pending != null) {
            pending.error("vpn_denied", "Android VPN permission was denied", null)
        }
    }

    private fun awaitService(timeoutMillis: Long = 8000): AsterVpnService {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (true) {
            synchronized(serviceLock) { service }?.let { return it }
            if (System.currentTimeMillis() >= deadline) break
            try {
                Thread.sleep(25)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                break
            }
        }
        throw IllegalStateException("Aster service is still starting")
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_REQUEST) return
        val pending = vpnResult
        vpnResult = null
        // Notifications are optional; continue even when they were denied.
        if (pending != null) beginVpnConsent(pending)
    }

    private fun needsNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        return checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
    }

    private fun describe(error: Throwable): String =
        error.message?.takeIf { it.isNotBlank() } ?: error.toString()

    override fun onDestroy() {
        if (bound) {
            runCatching { unbindService(connection) }
            bound = false
        }
        synchronized(serviceLock) { service = null }
        super.onDestroy()
    }
}
