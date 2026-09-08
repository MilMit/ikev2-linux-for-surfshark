import Foundation
import NetworkExtension
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter: WireGuardAdapter = {
        WireGuardAdapter(with: self) { _, _ in
            // Never log tunnel configuration, keys, or credentials.
        }
    }()

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard
            let config = options?["wgQuickConfig"] as? String,
            !config.isEmpty,
            config.utf8.count <= 64 * 1024
        else {
            completionHandler(MobileTunnelError.configurationMissing)
            return
        }

        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try TunnelConfiguration(fromWgQuickConfig: config, called: "MilMit VPN")
        } catch {
            completionHandler(MobileTunnelError.configurationInvalid)
            return
        }

        adapter.start(tunnelConfiguration: tunnelConfiguration) { error in
            if let error = error {
                completionHandler(MobileTunnelError.backendStartFailed(error.localizedDescription))
                return
            }
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter.stop { _ in
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard messageData == Data([0]) else {
            completionHandler?(nil)
            return
        }
        adapter.getRuntimeConfiguration { value in
            completionHandler?(value?.data(using: .utf8))
        }
    }
}

enum MobileTunnelError: LocalizedError {
    case configurationMissing
    case configurationInvalid
    case backendStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "wireguard_configuration_missing"
        case .configurationInvalid:
            return "wireguard_configuration_invalid"
        case .backendStartFailed:
            return "wireguard_backend_start_failed"
        }
    }
}
