package net.milmit.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import java.io.File
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicReference

class MilMitVpnService : VpnService() {
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

    private var tun: ParcelFileDescriptor? = null
    private val wireGuardBackend: WireGuardBackend = UnavailableWireGuardBackend()

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
            state.set("permission_required")
            stopSelf()
            return
        }

        val serverId = intent.getStringExtra(EXTRA_SERVER_ID)?.takeIf { it.matches(Regex("[A-Za-z0-9._:-]{1,160}")) }
            ?: run {
                state.set("error")
                stopSelf()
                return
            }
        val protocol = intent.getStringExtra(EXTRA_PROTOCOL)?.lowercase() ?: "wireguard"
        if (protocol != "wireguard") {
            state.set("unsupported_protocol")
            stopSelf()
            return
        }

        val profile = File(filesDir, "wireguard/$serverId.conf")
        if (!profile.isFile || profile.length() == 0L) {
            state.set("profile_missing")
            stopSelf()
            return
        }

        state.set("connecting")
        startForeground(NOTIFICATION_ID, buildNotification("Connecting…"))

        val address = extractInterfaceAddress(profile) ?: run {
            fail("profile_invalid")
            return
        }

        tun?.close()
        tun = Builder()
            .setSession("MilMit VPN")
            .setMtu(1280)
            .addAddress(address.first, address.second)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1")
            .establish()

        val descriptor = tun ?: run {
            fail("tun_create_failed")
            return
        }

        val backendResult = wireGuardBackend.start(this, descriptor, profile)
        if (backendResult.isFailure) {
            fail(backendResult.exceptionOrNull()?.message ?: "wireguard_start_failed")
            return
        }

        state.set("connected")
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification("Connected"))
    }

    private fun extractInterfaceAddress(profile: File): Pair<String, Int>? {
        val line = profile.useLines { lines ->
            lines.map { it.trim() }
                .firstOrNull { it.startsWith("Address", ignoreCase = true) && it.contains('=') }
        } ?: return null
        val value = line.substringAfter('=').trim().substringBefore(',').trim()
        val host = value.substringBefore('/')
        val prefix = value.substringAfter('/', "32").toIntOrNull() ?: return null
        return try {
            val parsed = InetAddress.getByName(host)
            if (parsed.address.size != 4 || prefix !in 0..32) null else host to prefix
        } catch (_: Exception) {
            null
        }
    }

    private fun fail(code: String) {
        wireGuardBackend.stop()
        tun?.close()
        tun = null
        state.set(code)
        stopForegroundCompat()
        stopSelf()
    }

    private fun stopTunnel() {
        state.set("disconnecting")
        wireGuardBackend.stop()
        tun?.close()
        tun = null
        state.set("disconnected")
        stopForegroundCompat()
        stopSelf()
    }

    override fun onRevoke() {
        stopTunnel()
        super.onRevoke()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "VPN connection", NotificationManager.IMPORTANCE_LOW)
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
