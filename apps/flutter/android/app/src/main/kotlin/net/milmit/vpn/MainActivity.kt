package net.milmit.vpn

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Ikev2VpnProfile
import android.net.VpnManager
import android.net.VpnService
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "net.milmit.vpn/android"
    private val prepareRequestCode = 4102
    private val ikev2ProvisionRequestCode = 4103
    private var pendingPrepareResult: MethodChannel.Result? = null
    private var pendingIkev2Result: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "supportedProtocols" -> result.success(supportedProtocols())
                    "prepare" -> prepareVpn(call.argument<String>("protocol") ?: "wireguard", result)
                    "connect" -> connect(call, result)
                    "disconnect" -> disconnect(result)
                    "status" -> result.success(MobileVpnRuntimeState.snapshot(this))
                    "credentialsSaved" -> result.success(MobileCredentialStore.exists(this))
                    "saveCredentials" -> saveCredentials(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun supportedProtocols(): List<String> = buildList {
        add("wireguard")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_IPSEC_TUNNELS)
        ) {
            add("ikev2")
        }
        if (IcsOpenVpnBackend().available()) add("openvpn")
    }

    private fun prepareVpn(protocolRaw: String, result: MethodChannel.Result) {
        val protocol = protocolRaw.lowercase()
        if (protocol == "ikev2") {
            result.success(
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                    packageManager.hasSystemFeature(PackageManager.FEATURE_IPSEC_TUNNELS),
            )
            return
        }
        if (protocol !in setOf("wireguard", "openvpn")) {
            result.error("unsupported_protocol", "Unsupported Android VPN protocol: $protocol", null)
            return
        }
        if (protocol == "openvpn" && !IcsOpenVpnBackend().available()) {
            result.success(false)
            return
        }

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

    private fun connect(call: MethodCall, result: MethodChannel.Result) {
        val providerId = call.argument<String>("providerId")
        val serverId = call.argument<String>("serverId")
        val hostname = call.argument<String>("hostname")
        val protocol = call.argument<String>("protocol")?.lowercase()

        val safeProvider = providerId?.takeIf { it.matches(Regex("[A-Za-z0-9._-]{1,80}")) }
        val safeServer = serverId?.takeIf { it.matches(Regex("[A-Za-z0-9._:-]{1,160}")) }
        val safeHost = hostname?.takeIf {
            it.length in 1..253 && it.matches(Regex("[A-Za-z0-9.-]+"))
        }
        val safeProtocol = protocol?.takeIf { it in setOf("wireguard", "ikev2", "openvpn") }
        if (safeProvider == null || safeServer == null || safeHost == null || safeProtocol == null) {
            result.error("invalid_request", "Invalid mobile VPN connect request", null)
            return
        }

        if (safeProtocol == "ikev2") {
            connectIkev2(safeHost, result)
            return
        }

        if (VpnService.prepare(this) != null) {
            result.error("permission_required", "VPN permission has not been granted", null)
            return
        }
        if (safeProtocol == "openvpn" && !IcsOpenVpnBackend().available()) {
            result.error("openvpn_engine_unavailable", "Embedded OpenVPN engine is unavailable", null)
            return
        }

        val intent = Intent(this, MilMitVpnService::class.java).apply {
            action = MilMitVpnService.ACTION_CONNECT
            putExtra(MilMitVpnService.EXTRA_PROVIDER_ID, safeProvider)
            putExtra(MilMitVpnService.EXTRA_SERVER_ID, safeServer)
            putExtra(MilMitVpnService.EXTRA_PROTOCOL, safeProtocol)
        }
        MobileVpnRuntimeState.update("connecting", safeProtocol)
        ContextCompat.startForegroundService(this, intent)
        result.success(null)
    }

    private fun connectIkev2(hostname: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
            !packageManager.hasSystemFeature(PackageManager.FEATURE_IPSEC_TUNNELS)
        ) {
            result.error("ikev2_unavailable", "Android platform IKEv2 requires API 30+ with IPsec tunnel support", null)
            return
        }
        val credentials = MobileCredentialStore.load(this)
        if (credentials == null) {
            result.error("credentials_missing", "IKEv2 service credentials are not saved", null)
            return
        }

        val (username, password) = credentials
        val profile = runCatching {
            Ikev2VpnProfile.Builder(hostname, hostname)
                .setAuthUsernamePassword(username, password, null)
                .build()
        }.getOrElse {
            result.error("ikev2_profile_failed", it.message ?: "Failed to create IKEv2 profile", null)
            return
        }

        val manager = getSystemService(VpnManager::class.java)
        val consentIntent = runCatching { manager.provisionVpnProfile(profile) }.getOrElse {
            result.error("ikev2_provision_failed", it.message ?: "Failed to provision IKEv2 profile", null)
            return
        }
        MobileVpnRuntimeState.update("connecting", "ikev2")
        if (consentIntent != null) {
            if (pendingIkev2Result != null) {
                result.error("prepare_in_progress", "IKEv2 consent request is already open", null)
                return
            }
            pendingIkev2Result = result
            startActivityForResult(consentIntent, ikev2ProvisionRequestCode)
            return
        }
        startProvisionedIkev2(manager, result)
    }

    private fun startProvisionedIkev2(manager: VpnManager, result: MethodChannel.Result) {
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                manager.startProvisionedVpnProfileSession()
            } else {
                @Suppress("DEPRECATION")
                manager.startProvisionedVpnProfile()
            }
        }.onSuccess {
            MobileVpnRuntimeState.update("connecting", "ikev2")
            result.success(null)
        }.onFailure {
            MobileVpnRuntimeState.update("error", "ikev2", it.message ?: "ikev2_start_failed")
            result.error("ikev2_start_failed", it.message ?: "Failed to start IKEv2", null)
        }
    }

    private fun disconnect(result: MethodChannel.Result) {
        val protocol = MobileVpnRuntimeState.activeProtocol()
        if (protocol == "ikev2" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            runCatching { getSystemService(VpnManager::class.java).stopProvisionedVpnProfile() }
                .onFailure {
                    result.error("disconnect_failed", it.message ?: "Failed to stop IKEv2", null)
                    return
                }
            MobileVpnRuntimeState.clear()
            result.success(null)
            return
        }

        val intent = Intent(this, MilMitVpnService::class.java).apply {
            action = MilMitVpnService.ACTION_DISCONNECT
        }
        startService(intent)
        MobileVpnRuntimeState.update("disconnecting", protocol)
        result.success(null)
    }

    private fun saveCredentials(call: MethodCall, result: MethodChannel.Result) {
        val username = call.argument<String>("username")
        val password = call.argument<String>("password")
        if (username.isNullOrBlank() || password.isNullOrEmpty()) {
            result.error("invalid_credentials", "Username and password are required", null)
            return
        }
        runCatching { MobileCredentialStore.save(this, username, password) }
            .onSuccess { result.success(null) }
            .onFailure { result.error("credential_store_failed", it.message, null) }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            prepareRequestCode -> {
                pendingPrepareResult?.success(resultCode == Activity.RESULT_OK)
                pendingPrepareResult = null
            }
            ikev2ProvisionRequestCode -> {
                val pending = pendingIkev2Result
                pendingIkev2Result = null
                if (pending == null) return
                if (resultCode != Activity.RESULT_OK) {
                    MobileVpnRuntimeState.update("error", "ikev2", "permission_denied")
                    pending.error("permission_denied", "IKEv2 permission was not granted", null)
                    return
                }
                startProvisionedIkev2(getSystemService(VpnManager::class.java), pending)
            }
        }
    }
}
