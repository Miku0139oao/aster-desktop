package app.aster.desktop

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.Locale

/** Lists launchable packages for Android split tunneling without a plugin. */
object InstalledApplications {
    fun list(context: Context): String {
        val manager = context.packageManager
        val entries = mutableListOf<Pair<String, JSONObject>>()
        val packages = try {
            manager.getInstalledApplications(PackageManager.GET_META_DATA)
        } catch (_: Throwable) {
            emptyList()
        }
        for (application in packages) {
            if (application.packageName == context.packageName) continue
            val label = try {
                manager.getApplicationLabel(application).toString()
            } catch (_: Throwable) {
                application.packageName
            }
            val icon = try {
                icon(manager, application)
            } catch (_: Throwable) {
                ""
            }
            entries.add(
                label.lowercase(Locale.ROOT) to JSONObject()
                    .put("package", application.packageName)
                    .put("name", label)
                    .put("system", application.flags and ApplicationInfo.FLAG_SYSTEM != 0)
                    .put("enabled", application.enabled)
                    .put("icon", icon),
            )
        }
        entries.sortBy { it.first }
        val result = JSONArray()
        for ((_, application) in entries) result.put(application)
        return result.toString()
    }

    private fun icon(manager: PackageManager, application: ApplicationInfo): String {
        val drawable = manager.getApplicationIcon(application)
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 80, stream)
        bitmap.recycle()
        return Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
    }
}
