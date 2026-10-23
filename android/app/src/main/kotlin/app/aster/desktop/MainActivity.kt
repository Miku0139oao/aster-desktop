package app.aster.desktop

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.VpnService
import android.os.IBinder
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "app.astercore/android"
    private val executor = Executors.newSingleThreadExecutor()
    private var service: AsterVpnService? = null
    private var vpnResult: MethodChannel.Result? = null
    private var vpnLauncher: ActivityResultLauncher<Intent>? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = (binder as? AsterVpnService.LocalBinder)?.service()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        vpnLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            val pending = vpnResult
            vpnResult = null
            if (result.resultCode == RESULT_OK) {
                connectVpn(pending)
            } else if (pending != null) {
                pending.error("vpn_denied", "Android VPN permission was denied", null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "call" -> executor.execute {
                        try {
                            val request = call.argument<String>("request") ?: "{}"
                            result.success(awaitService().call(request))
                        } catch (error: Throwable) {
                            result.error("operation", error.message, null)
                        }
                    }
                    "startVpn" -> prepareVpn(result)
                    "stopVpn" -> executor.execute {
                        try {
                            result.success(awaitService().stopVpn())
                        } catch (error: Throwable) {
                            result.error("operation", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        bindService(
            Intent(this, AsterVpnService::class.java),
            connection,
            Context.BIND_AUTO_CREATE,
        )
    }

    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            vpnResult = result
            vpnLauncher?.launch(intent)
        } else {
            connectVpn(result)
        }
    }

    private fun connectVpn(result: MethodChannel.Result?) {
        val pending = result ?: return
        executor.execute {
            try {
                pending.success(awaitService().startVpn())
            } catch (error: Throwable) {
                pending.error("operation", error.message, null)
            }
        }
    }

    private fun awaitService(): AsterVpnService {
        service?.let { return it }
        Thread.sleep(250)
        return service ?: throw IllegalStateException("Aster service is starting")
    }

    override fun onDestroy() {
        unbindService(connection)
        service = null
        super.onDestroy()
    }
}
