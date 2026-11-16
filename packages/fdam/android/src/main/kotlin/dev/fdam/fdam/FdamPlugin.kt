package dev.fdam.fdam

import android.os.StatFs
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Native helpers for the Flutter Dynamic Asset Manager.
 *
 * Only one call exists: the real free/total space of the file system that
 * holds a path (StatFs). Dart has no API for this, and FDAM must check real
 * storage before downloading or extracting.
 */
class FdamPlugin : FlutterPlugin, MethodCallHandler {
  private lateinit var channel: MethodChannel

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "dev.fdam/storage")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "getStorageInfo" -> {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
          result.error("bad_args", "path is required", null)
          return
        }
        try {
          val stat = StatFs(path)
          result.success(
            mapOf(
              "availableBytes" to stat.availableBytes,
              "totalBytes" to stat.totalBytes,
            )
          )
        } catch (e: IllegalArgumentException) {
          result.error("statfs_failed", e.message, null)
        }
      }
      else -> result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }
}
