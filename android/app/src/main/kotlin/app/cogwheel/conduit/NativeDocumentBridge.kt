package app.cogwheel.conduit

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File

class NativeDocumentBridge(private val activity: Activity) : NativeDocumentHostApi {
    override fun openFile(path: String, mimeType: String): Boolean {
        val file = File(path).canonicalFile
        val root = File(activity.cacheDir, "open-with").canonicalFile
        if (!file.isFile || !file.path.startsWith(root.path + File.separator)) return false
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.documents", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType.ifBlank { "application/octet-stream" })
            clipData = ClipData.newRawUri("", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            activity.startActivity(Intent.createChooser(intent, null))
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }
}
