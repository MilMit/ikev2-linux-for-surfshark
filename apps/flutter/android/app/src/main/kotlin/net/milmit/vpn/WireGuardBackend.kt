package net.milmit.vpn

import android.content.Context
import android.os.ParcelFileDescriptor
import java.io.File

/**
 * Narrow Android WireGuard backend boundary.
 *
 * Phase 5 deliberately fails closed until the native WireGuard engine is linked.
 * A TUN descriptor alone is never treated as a working VPN connection.
 */
interface WireGuardBackend {
    fun start(context: Context, tun: ParcelFileDescriptor, profile: File): Result<Unit>
    fun stop()
}

class UnavailableWireGuardBackend : WireGuardBackend {
    override fun start(context: Context, tun: ParcelFileDescriptor, profile: File): Result<Unit> =
        Result.failure(IllegalStateException("wireguard_backend_not_linked"))

    override fun stop() = Unit
}
