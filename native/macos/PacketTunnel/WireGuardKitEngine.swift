#if canImport(WireGuardKit)
import Foundation
import NetworkExtension
import WireGuardKit

final class WireGuardKitPacketTunnelEngine: MilMitPacketTunnelEngine {
    private let adapter: WireGuardAdapter

    init(provider: NEPacketTunnelProvider) {
        self.adapter = WireGuardAdapter(with: provider) { _, message in
            NSLog("[MilMit WireGuard] %@", message)
        }
    }

    func start(configuration: MilMitTunnelConfiguration, packetFlow: NEPacketTunnelFlow, completion: @escaping (Error?) -> Void) {
        guard let wgQuick = configuration.wireGuardQuickConfig, !wgQuick.isEmpty else {
            completion(NSError(domain: "net.milmit.vpn", code: 40, userInfo: [NSLocalizedDescriptionKey: "WireGuard runtime configuration is missing"]))
            return
        }

        do {
            let tunnel = try MilMitWgQuickParser.parse(wgQuick, name: "MilMit")
            adapter.start(tunnelConfiguration: tunnel) { error in
                completion(error)
            }
        } catch {
            completion(error)
        }
    }

    func stop(completion: @escaping () -> Void) {
        adapter.stop { _ in completion() }
    }

    func handle(message: Data, completion: @escaping (Data?) -> Void) {
        adapter.getRuntimeConfiguration { text in
            completion(text?.data(using: .utf8))
        }
    }
}

enum MilMitWgQuickParser {
    static func parse(_ text: String, name: String?) throws -> TunnelConfiguration {
        enum Section { case none, interface, peer }
        var section = Section.none
        var interfaceValues: [String: [String]] = [:]
        var peerValues = [[String: [String]]]()
        var currentPeer: [String: [String]]?

        func add(_ key: String, _ value: String, to dict: inout [String: [String]]) {
            dict[key.lowercased(), default: []].append(value)
        }

        for rawLine in text.split(whereSeparator: \ .isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.caseInsensitiveCompare("[Interface]") == .orderedSame {
                if let currentPeer { peerValues.append(currentPeer) }
                currentPeer = nil
                section = .interface
                continue
            }
            if trimmed.caseInsensitiveCompare("[Peer]") == .orderedSame {
                if let currentPeer { peerValues.append(currentPeer) }
                currentPeer = [:]
                section = .peer
                continue
            }
            guard let equal = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equal]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            switch section {
            case .interface:
                add(key, value, to: &interfaceValues)
            case .peer:
                if currentPeer == nil { currentPeer = [:] }
                add(key, value, to: &currentPeer!)
            case .none:
                continue
            }
        }
        if let currentPeer { peerValues.append(currentPeer) }

        guard let privateKeyText = interfaceValues["privatekey"]?.last,
              let privateKey = PrivateKey(base64Key: privateKeyText) else {
            throw parseError("Missing or invalid WireGuard private key")
        }
        var interface = InterfaceConfiguration(privateKey: privateKey)
        interface.addresses = csv(interfaceValues["address"]).compactMap { IPAddressRange(from: $0) }
        interface.dns = csv(interfaceValues["dns"]).compactMap { DNSServer(from: $0) }
        if let port = interfaceValues["listenport"]?.last.flatMap(UInt16.init) { interface.listenPort = port }
        if let mtu = interfaceValues["mtu"]?.last.flatMap(UInt16.init) { interface.mtu = mtu }

        let peers: [PeerConfiguration] = try peerValues.map { values in
            guard let publicKeyText = values["publickey"]?.last,
                  let publicKey = PublicKey(base64Key: publicKeyText) else {
                throw parseError("Missing or invalid WireGuard peer public key")
            }
            var peer = PeerConfiguration(publicKey: publicKey)
            if let pskText = values["presharedkey"]?.last, !pskText.isEmpty {
                guard let psk = PreSharedKey(base64Key: pskText) else { throw parseError("Invalid WireGuard preshared key") }
                peer.preSharedKey = psk
            }
            peer.allowedIPs = csv(values["allowedips"]).compactMap { IPAddressRange(from: $0) }
            if let endpointText = values["endpoint"]?.last {
                guard let endpoint = Endpoint(from: endpointText) else { throw parseError("Invalid WireGuard endpoint") }
                peer.endpoint = endpoint
            }
            if let keepalive = values["persistentkeepalive"]?.last.flatMap(UInt16.init) {
                peer.persistentKeepAlive = keepalive
            }
            return peer
        }

        guard !peers.isEmpty else { throw parseError("WireGuard configuration has no peers") }
        return TunnelConfiguration(name: name, interface: interface, peers: peers)
    }

    private static func csv(_ values: [String]?) -> [String] {
        (values ?? []).flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
    }

    private static func parseError(_ message: String) -> NSError {
        NSError(domain: "net.milmit.vpn.wireguard", code: 41, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
