import Foundation
import NetworkExtension

final class MilMitHostTunnelManager {
    static let shared = MilMitHostTunnelManager()
    private let providerBundleIdentifier = "net.milmit.vpn.PacketTunnel"
    private let localizedDescription = "MilMit VPN"

    private init() {}

    private func loadManager(completion: @escaping (Result<NETunnelProviderManager, Error>) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let existing = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.providerBundleIdentifier
            }) {
                completion(.success(existing))
                return
            }
            completion(.success(NETunnelProviderManager()))
        }
    }

    func configure(
        serverAddress: String,
        engine: String,
        endpoint: String,
        dnsServers: [String],
        includedRoutes: [String] = [],
        excludedRoutes: [String] = [],
        completion: @escaping (Error?) -> Void
    ) {
        loadManager { result in
            switch result {
            case .failure(let error):
                completion(error)
            case .success(let manager):
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = self.providerBundleIdentifier
                proto.serverAddress = serverAddress
                proto.providerConfiguration = [
                    "engine": engine,
                    "endpoint": endpoint,
                    "dnsServers": dnsServers,
                    "includedRoutes": includedRoutes,
                    "excludedRoutes": excludedRoutes,
                ]
                manager.protocolConfiguration = proto
                manager.localizedDescription = self.localizedDescription
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    if let error {
                        completion(error)
                        return
                    }
                    manager.loadFromPreferences { reloadError in completion(reloadError) }
                }
            }
        }
    }

    func start(completion: @escaping (Error?) -> Void) {
        loadManager { result in
            switch result {
            case .failure(let error): completion(error)
            case .success(let manager):
                do {
                    try manager.connection.startVPNTunnel()
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
        }
    }

    func stop(completion: @escaping () -> Void) {
        loadManager { result in
            if case .success(let manager) = result {
                manager.connection.stopVPNTunnel()
            }
            completion()
        }
    }

    func status(completion: @escaping (NEVPNStatus) -> Void) {
        loadManager { result in
            switch result {
            case .success(let manager): completion(manager.connection.status)
            case .failure: completion(.invalid)
            }
        }
    }
}
