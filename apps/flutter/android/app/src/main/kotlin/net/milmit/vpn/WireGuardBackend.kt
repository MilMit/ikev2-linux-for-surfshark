package net.milmit.vpn

import android.content.Context
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.State
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import java.io.File

interface WireGuardBackend {
    fun start(context: Context, tunnelName: String, profile: File): Result<Unit>
    fun stop(): Result<Unit>
    fun state(): String
}

class WireGuardAndroidBackend : WireGuardBackend {
    private var backend: GoBackend? = null
    private var tunnel: Tunnel? = null

    override fun start(context: Context, tunnelName: String, profile: File): Result<Unit> = runCatching {
        require(Tunnel.isNameInvalid(tunnelName).not()) { "invalid_tunnel_name" }
        val config = profile.inputStream().use(Config::parse)
        val goBackend = backend ?: GoBackend(context.applicationContext).also { backend = it }
        val target = object : Tunnel {
            override fun getName(): String = tunnelName
            override fun onStateChange(newState: State) = Unit
        }
        val newState = goBackend.setState(target, State.UP, config)
        check(newState == State.UP) { "wireguard_backend_not_up" }
        tunnel = target
    }

    override fun stop(): Result<Unit> = runCatching {
        val goBackend = backend ?: return@runCatching
        val target = tunnel ?: return@runCatching
        goBackend.setState(target, State.DOWN, null)
        tunnel = null
    }

    override fun state(): String {
        val goBackend = backend ?: return "disconnected"
        val target = tunnel ?: return "disconnected"
        return when (goBackend.getState(target)) {
            State.UP -> "connected"
            State.DOWN -> "disconnected"
            State.TOGGLE -> "error"
        }
    }
}
