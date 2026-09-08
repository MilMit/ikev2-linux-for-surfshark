package net.milmit.vpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "net.milmit.vpn/android"
    private val prepareRequestCode = 4102
    private var pendingPrepareResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> prepareVpn(result)
                    "connect" -> connect(call.argument<String>("providerId"), call.argument<String>("serverId"), call.argument<String>("protocol"), result)
                    "disconnect" -> disconnect(result)
                    "status" -> result.success(mapOf("state" to MilMitVpnService.currentState()))
                    else -> result.notImplemented()
                }
            }
    }

    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        if (pendingPrepareResult != null) {
            result.error("prepare_in_progress", "VPN permission request is already open", null)
            return
        }
        pendingPrepareResult = result
        startActivityForResult(intent, prepareRequestCode)
    }

    private fun connect(providerId: String?, serverId: String?, protocol: String?, result: MethodChannel.Result) {
        if (VpnService.prepare(this) != null) {
            result.error("permission_required", "VPN permission has not been granted", null)
            return
        }
        val safeProvider = providerId?.takeIf { it.matches(Regex("[A-Za-z0-9._-]{1,80}")) }
        val safeServer = serverId?.takeIf { it.matches(Regex("[A-Za-z0-9._:-]{1,160}")) }
        val safeProtocol = protocol?.lowercase()?.takeIf { it in setOf("wireguard") }
        if (safeProvider == null || safeServer == null || safeProtocol == null) {
            result.error("invalid_request", "Invalid mobile VPN connect request", null)
            return
        }
        val intent = Intent(this, MilMitVpnService::class.java).apply {
            action = MilMitVpnService.ACTION_CONNECT
            putExtra(MilMitVpnService.EXTRA_PROVIDER_ID, safeProvider)
            putExtra(MilMitVpnService.EXTRA_SERVER_ID, safeServer)
            putExtra(MilMitVpnService.EXTRA_PROTOCOL, safeProtocol)
        }
        ContextCompat.startForegroundService(this, intent)
        result.success(null)
    }

    private fun disconnect(result: MethodChannel.Result) {
        val intent = Intent(this, MilMitVpnService::class.java).apply {
            action = MilMitVpnService.ACTION_DISCONNECT
        }
        startService(intent)
        result.success(null)
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == prepareRequestCode) {
            pendingPrepareResult?.success(resultCode == Activity.RESULT_OK)
            pendingPrepareResult = null
        }
    }
}
