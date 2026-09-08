import Foundation
import NetworkExtension

struct MilMitTunnelConfiguration {
    let engine: String
    let endpoint: String
    let dnsServers: [String]
    let includedRoutes: [String]
    let excludedRoutes: [String]

    init(providerConfiguration: [String: Any]) throws {
        guard let engine = providerConfiguration["engine"] as? String, !engine.isEmpty else {
            throw NSError(domain: "net.milmit.vpn", code: 20, userInfo: [NSLocalizedDescriptionKey: "Missing packet tunnel engine"])
        }
        guard ["wireguard", "openvpn"].contains(engine.lowercased()) else {
            throw NSError(domain: "net.milmit.vpn", code: 21, userInfo: [NSLocalizedDescriptionKey: "Unsupported packet tunnel engine"])
        }
        guard let endpoint = providerConfiguration["endpoint"] as? String, !endpoint.isEmpty else {
            throw NSError(domain: "net.milmit.vpn", code: 22, userInfo: [NSLocalizedDescriptionKey: "Missing tunnel endpoint"])
        }
        self.engine = engine.lowercased()
        self.endpoint = endpoint
        self.dnsServers = providerConfiguration["dnsServers"] as? [String] ?? []
        self.includedRoutes = providerConfiguration["includedRoutes"] as? [String] ?? []
        self.excludedRoutes = providerConfiguration["excludedRoutes"] as? [String] ?? []
    }

    func baseNetworkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: endpoint)
        if !dnsServers.isEmpty {
            settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        }
        return settings
    }
}

protocol MilMitPacketTunnelEngine: AnyObject {
    func start(configuration: MilMitTunnelConfiguration, packetFlow: NEPacketTunnelFlow, completion: @escaping (Error?) -> Void)
    func stop(completion: @escaping () -> Void)
    func handle(message: Data, completion: @escaping (Data?) -> Void)
}

enum MilMitPacketTunnelEngineFactory {
    static func make(engine: String) -> MilMitPacketTunnelEngine? {
        // WireGuard/OpenVPN engines must be linked into the signed extension target.
        // Returning nil is intentional until a reviewed engine dependency is integrated.
        return nil
    }
}
