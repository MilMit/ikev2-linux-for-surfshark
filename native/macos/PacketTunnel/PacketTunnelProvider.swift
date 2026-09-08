import NetworkExtension
import os.log

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "net.milmit.vpn", category: "PacketTunnel")

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol else {
            completionHandler(NSError(domain: "net.milmit.vpn", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid tunnel provider configuration"]))
            return
        }

        // This extension is the signed native boundary for WireGuard/OpenVPN-style packet tunnels.
        // Protocol engines are intentionally not faked here. Until an engine is linked, return a
        // clear configuration error instead of reporting a connected tunnel.
        let providerConfig = protocolConfiguration.providerConfiguration ?? [:]
        guard providerConfig["engine"] != nil else {
            completionHandler(NSError(domain: "net.milmit.vpn", code: 2, userInfo: [NSLocalizedDescriptionKey: "Packet tunnel engine is not configured yet"]))
            return
        }

        logger.error("Packet tunnel engine requested but no signed engine bridge is linked")
        completionHandler(NSError(domain: "net.milmit.vpn", code: 3, userInfo: [NSLocalizedDescriptionKey: "Signed packet tunnel engine bridge is not linked"] ))
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("Stopping packet tunnel, reason: \(reason.rawValue)")
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        let response = ["ok": false, "error": "engine_bridge_not_linked"] as [String : Any]
        completionHandler?(try? JSONSerialization.data(withJSONObject: response))
    }
}
