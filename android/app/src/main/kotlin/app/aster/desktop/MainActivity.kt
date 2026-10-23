package app.aster.desktop

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "app.astercore/android"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    "startVpn" -> {
                        result.error("not_ready", "Android VPN routing is not connected yet", null)
                    }
                    "stopVpn" -> {
                        stopService(Intent(this, AsterVpnService::class.java))
                        result.success(false)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
