import Foundation
import NetworkExtension
import OpenVPNAdapter

extension NEPacketTunnelFlow: OpenVPNAdapterPacketFlow {}

final class OpenVPNPacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter: OpenVPNAdapter = {
        let value = OpenVPNAdapter()
        value.delegate = self
        return value
    }()

    private let reachability = OpenVPNReachability()
    private var startHandler: ((Error?) -> Void)?
    private var stopHandler: (() -> Void)?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard
            let ovpn = options?["ovpn"] as? NSData,
            ovpn.length > 0,
            ovpn.length <= 512 * 1024
        else {
            completionHandler(OpenVpnTunnelError.configurationMissing)
            return
        }

        let configuration = OpenVPNConfiguration()
        configuration.fileContent = ovpn as Data
        configuration.tunPersist = true

        let evaluation: OpenVPNConfigurationEvaluation
        do {
            evaluation = try adapter.apply(configuration: configuration)
        } catch {
            completionHandler(error)
            return
        }

        if !evaluation.autologin {
            guard
                let username = options?["username"] as? String,
                let password = options?["password"] as? String,
                !username.isEmpty,
                !password.isEmpty
            else {
                completionHandler(OpenVpnTunnelError.credentialsMissing)
                return
            }
            let credentials = OpenVPNCredentials()
            credentials.username = username
            credentials.password = password
            do {
                try adapter.provide(credentials: credentials)
            } catch {
                completionHandler(error)
                return
            }
        }

        reachability.startTracking { [weak self] status in
            if status == .reachableViaWiFi {
                self?.adapter.reconnect(interval: 5)
            }
        }

        startHandler = completionHandler
        adapter.connect(using: packetFlow)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        stopHandler = completionHandler
        if reachability.isTracking { reachability.stopTracking() }
        adapter.disconnect()
    }
}

extension OpenVPNPacketTunnelProvider: OpenVPNAdapterDelegate {
    func openVPNAdapter(
        _ openVPNAdapter: OpenVPNAdapter,
        configureTunnelWithNetworkSettings networkSettings: NEPacketTunnelNetworkSettings?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        networkSettings?.dnsSettings?.matchDomains = [""]
        setTunnelNetworkSettings(networkSettings, completionHandler: completionHandler)
    }

    func openVPNAdapter(
        _ openVPNAdapter: OpenVPNAdapter,
        handleEvent event: OpenVPNAdapterEvent,
        message: String?
    ) {
        switch event {
        case .connected:
            reasserting = false
            startHandler?(nil)
            startHandler = nil
        case .disconnected:
            if reachability.isTracking { reachability.stopTracking() }
            stopHandler?()
            stopHandler = nil
        case .reconnecting:
            reasserting = true
        default:
            break
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleError error: Error) {
        guard (error as NSError).userInfo[OpenVPNAdapterErrorFatalKey] as? Bool == true else { return }
        if reachability.isTracking { reachability.stopTracking() }
        if let handler = startHandler {
            handler(error)
            startHandler = nil
        } else {
            cancelTunnelWithError(error)
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleLogMessage logMessage: String) {
        // Never forward profile contents, credentials, or raw OpenVPN logs to Flutter.
    }
}

enum OpenVpnTunnelError: LocalizedError {
    case configurationMissing
    case credentialsMissing

    var errorDescription: String? {
        switch self {
        case .configurationMissing: return "openvpn_configuration_missing"
        case .credentialsMissing: return "openvpn_credentials_missing"
        }
    }
}
