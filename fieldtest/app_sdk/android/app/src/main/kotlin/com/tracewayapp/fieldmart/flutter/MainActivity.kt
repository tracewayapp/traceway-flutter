package com.tracewayapp.fieldmart.flutter

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Fieldmart's launch settings arrive as intent string extras (fmRun,
 * fmVariant, ...). They are handed to Dart as entrypoint arguments
 * ("--fmRun=..."), so main() has them before anything touches the binding,
 * which is where Traceway.run must be first. The harness's marker lines go
 * to logcat with tag FM.
 */
class MainActivity : FlutterActivity() {
    override fun getDartEntrypointArgs(): List<String> {
        val extras = intent?.extras ?: return emptyList()
        return extras.keySet()
            .filter { it.startsWith("fm") }
            .mapNotNull { key -> extras.getString(key)?.let { "--$key=$it" } }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fieldmart/markers")
            .setMethodCallHandler { call, result ->
                if (call.method == "log") Log.i("FM", call.arguments as? String ?: "")
                result.success(null)
            }
    }
}
