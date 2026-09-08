package net.milmit.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import java.io.File
import java.util.concurrent.atomic.AtomicReference

class MilMitVpnService : Service() {
    companion object {
        const val ACTION_CONNECT = "net.milmit.vpn.CONNECT"
        const val ACTION_DISCONNECT = "net.milmit.vpn.DISCONNECT"
        const val EXTRA_SERVER_ID = "server_id"
        const val EXTRA_PROVIDER_ID = "provider_id"
        const val EXTRA_PROTOCOL = "protocol"
        private const val CHANNEL_ID = "milmit_vpn"
        private const val NOTIFICATION_ID = 4101

        private val state = AtomicReference("disconnected")
        fun currentState(): String = state.get()
    }

    private val wireGuardBackend: WireGuardBackend = WireGuardAndroidBackend()
    private val openVpnBackend: OpenVpnBackend = IcsOpenVpnBackend()
    private var activeProtocol: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CONNECT -> startTunnel(intent)
            ACTION_DISCONNECT -> stopTunnel()
        }
        return START_NOT_STICKY
    }

    private fun startTunnel(intent: Intent) {
        if (VpnService.prepare(this) != null) {
            fail("permission_required")
            return
        }

        val serverId = intent.getStringExtra(EXTRA_SERVER_ID)?.takeIf {
            it.matches(Regex("[A-Za-z0-9._:-]{1,160}"))
        } ?: run {
            fail("invalid_server")
            return
        }
        val protocol = intent.getStringExtra(EXTRA_PROTOCOL)?.lowercase() ?: "wireguard"
        if (protocol !in setOf("wireguard", "openvpn")) {
            fail("unsupported_protocol")
            return
        }

        activeProtocol = protocol
        state.set("connecting")
        MobileVpnRuntimeState.update("connecting", protocol)
        startForeground(NOTIFICATION_ID, buildNotification("Connecting with ${protocolLabel(protocol)}…"))

        val result = when (protocol) {
            "wireguard" -> startWireGuard(serverId)
            "openvpn" -> startOpenVpn(serverId)
            else -> Result.failure(IllegalStateException("unsupported_protocol"))
        }
        if (result.isFailure) {
            fail(result.exceptionOrNull()?.message ?: "${protocol}_start_failed")
            return
        }

        val backendState = when (protocol) {
            "wireguard" -> wireGuardBackend.state()
            "openvpn" -> openVpnBackend.state()
            else -> "error"
        }
        if (backendState == "error") {
            fail("${protocol}_backend_failed")
            return
        }

        // Some backends report UP only after their own foreground service finishes setup.
        // The Dart layer confirms final CONNECTED via Android's TRANSPORT_VPN state.
        state.set("connecting")
        MobileVpnRuntimeState.update("connecting", protocol)
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification("${protocolLabel(protocol)} starting…"))
    }

    private fun startWireGuard(serverId: String): Result<Unit> {
        val profile = File(filesDir, "wireguard/$serverId.conf")
        if (!profile.isFile || profile.length() == 0L || profile.length() > 64 * 1024) {
            return Result.failure(IllegalStateException("profile_missing"))
        }
        val tunnelName = safeTunnelName(serverId)
            ?: return Result.failure(IllegalStateException("invalid_tunnel_name"))
        return wireGuardBackend.start(this, tunnelName, profile)
    }

    private fun startOpenVpn(serverId: String): Result<Unit> {
        if (!openVpnBackend.available()) {
            return Result.failure(IllegalStateException("openvpn_engine_unavailable"))
        }
        val profile = File(filesDir, "openvpn/$serverId.ovpn")
        if (!profile.isFile || profile.length() == 0L || profile.length() > 512 * 1024) {
            return Result.failure(IllegalStateException("profile_missing"))
        }
        val tunnelName = safeTunnelName(serverId)
            ?: return Result.failure(IllegalStateException("invalid_tunnel_name"))
        return openVpnBackend.start(this, tunnelName, profile)
    }

    private fun safeTunnelName(serverId: String): String? {
        val value = serverId.replace(Regex("[^A-Za-z0-9_=+.-]"), "-").take(15)
        return value.takeIf { it.isNotBlank() }
    }

    private fun fail(code: String) {
        runCatching { wireGuardBackend.stop() }
        runCatching { openVpnBackend.stop(this) }
        state.set("error")
        MobileVpnRuntimeState.update("error", activeProtocol, code)
        stopForegroundCompat()
        stopSelf()
    }

    private fun stopTunnel() {
        state.set("disconnecting")
        MobileVpnRuntimeState.update("disconnecting", activeProtocol)
        when (activeProtocol) {
            "wireguard" -> runCatching { wireGuardBackend.stop() }
            "openvpn" -> runCatching { openVpnBackend.stop(this) }
            else -> {
                runCatching { wireGuardBackend.stop() }
                runCatching { openVpnBackend.stop(this) }
            }
        }
        activeProtocol = null
        state.set("disconnected")
        MobileVpnRuntimeState.clear()
        stopForegroundCompat()
        stopSelf()
    }

    private fun protocolLabel(protocol: String): String = when (protocol) {
        "wireguard" -> "WireGuard"
        "openvpn" -> "OpenVPN"
        else -> protocol
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "VPN connection",
                NotificationManager.IMPORTANCE_LOW,
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle("MilMit VPN")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
