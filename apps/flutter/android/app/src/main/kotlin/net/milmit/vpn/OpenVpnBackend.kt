package net.milmit.vpn

import android.content.Context
import android.content.Intent
import java.io.File
import java.io.StringReader

internal interface OpenVpnBackend {
    fun start(context: Context, tunnelName: String, profile: File): Result<Unit>
    fun stop(context: Context): Result<Unit>
    fun state(): String
    fun available(): Boolean
}

/**
 * Thin integration layer around the embedded OpenVPN-for-Android engine.
 * Reflection is deliberate: upstream has changed helper method signatures across releases,
 * while ConfigParser/VpnProfile/VPNLaunchHelper semantics have remained compatible.
 */
internal class IcsOpenVpnBackend : OpenVpnBackend {
    override fun available(): Boolean = runCatching {
        Class.forName("de.blinkt.openvpn.core.ConfigParser")
        Class.forName("de.blinkt.openvpn.core.VPNLaunchHelper")
        true
    }.getOrDefault(false)

    override fun start(context: Context, tunnelName: String, profile: File): Result<Unit> = runCatching {
        require(available()) { "openvpn_engine_unavailable" }
        require(profile.isFile && profile.length() in 1..(512 * 1024)) { "openvpn_profile_missing" }
        val configText = profile.readText(Charsets.UTF_8)
        require(configText.contains("remote ") || configText.contains("remote\t")) { "openvpn_profile_invalid" }

        val parserClass = Class.forName("de.blinkt.openvpn.core.ConfigParser")
        val parser = parserClass.getDeclaredConstructor().newInstance()
        val parse = parserClass.methods.firstOrNull {
            it.name == "parseConfig" && it.parameterTypes.size == 1
        } ?: error("openvpn_parse_api_missing")
        parse.invoke(parser, StringReader(configText))

        val convert = parserClass.methods.firstOrNull {
            it.name == "convertProfile" && it.parameterTypes.isEmpty()
        } ?: error("openvpn_convert_api_missing")
        val vpnProfile = convert.invoke(parser) ?: error("openvpn_profile_conversion_failed")

        runCatching {
            vpnProfile.javaClass.getField("mName").set(vpnProfile, tunnelName)
        }

        val helperClass = Class.forName("de.blinkt.openvpn.core.VPNLaunchHelper")
        val launcher = helperClass.methods
            .filter { it.name == "startOpenVpn" }
            .sortedBy { it.parameterTypes.size }
            .firstOrNull { method ->
                method.parameterTypes.any { it.isAssignableFrom(vpnProfile.javaClass) || vpnProfile.javaClass.isAssignableFrom(it) } &&
                    method.parameterTypes.any { Context::class.java.isAssignableFrom(it) }
            } ?: error("openvpn_launch_api_missing")

        val args = launcher.parameterTypes.map { type ->
            when {
                type.isAssignableFrom(vpnProfile.javaClass) || vpnProfile.javaClass.isAssignableFrom(type) -> vpnProfile
                Context::class.java.isAssignableFrom(type) -> context.applicationContext
                type == String::class.java -> "MilMit"
                type == Boolean::class.javaPrimitiveType || type == Boolean::class.java -> true
                type == Int::class.javaPrimitiveType || type == Int::class.java -> 0
                else -> null
            }
        }.toTypedArray()
        launcher.invoke(null, *args)
    }

    override fun stop(context: Context): Result<Unit> = runCatching {
        if (!available()) return@runCatching
        val intent = Intent().apply {
            setClassName(context.packageName, "de.blinkt.openvpn.api.DisconnectVPN")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }

    override fun state(): String = runCatching {
        val statusClass = Class.forName("de.blinkt.openvpn.core.VpnStatus")
        val method = statusClass.methods.firstOrNull {
            it.name == "isVPNActive" && it.parameterTypes.isEmpty()
        } ?: return@runCatching "disconnected"
        if (method.invoke(null) == true) "connected" else "disconnected"
    }.getOrDefault("disconnected")
}
