package net.milmit.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.util.concurrent.atomic.AtomicReference

internal object MobileVpnRuntimeState {
    private val state = AtomicReference("disconnected")
    private val protocol = AtomicReference<String?>(null)
    private val message = AtomicReference<String?>(null)

    fun update(newState: String, activeProtocol: String? = protocol.get(), detail: String? = null) {
        state.set(newState)
        protocol.set(activeProtocol)
        message.set(detail)
    }

    fun clear() {
        state.set("disconnected")
        protocol.set(null)
        message.set(null)
    }

    fun activeProtocol(): String? = protocol.get()

    fun snapshot(context: Context): Map<String, String?> {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val network = cm?.activeNetwork
        val caps = network?.let(cm::getNetworkCapabilities)
        val systemVpnUp = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        val current = state.get()
        val normalized = when {
            systemVpnUp && current in setOf("connecting", "connected") -> "connected"
            !systemVpnUp && current == "connected" -> "connecting"
            else -> current
        }
        return mapOf(
            "state" to normalized,
            "protocol" to protocol.get(),
            "message" to message.get(),
        )
    }
}
