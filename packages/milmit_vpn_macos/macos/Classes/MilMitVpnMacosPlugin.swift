import FlutterMacOS
import Foundation
import NetworkExtension

public final class MilMitVpnMacosPlugin: NSObject, FlutterPlugin {
    private static let providerBundleIdentifier = "net.milmit.vpn.PacketTunnel"
    private static let localizedDescription = "MilMit VPN"

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "net.milmit.vpn/macos", binaryMessenger: registrar.messenger)
        let instance = MilMitVpnMacosPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            guard let args = call.arguments as? [String: Any],
                  let serverAddress = args["serverAddress"] as? String,
                  let engine = args["engine"] as? String,
                  let endpoint = args["endpoint"] as? String,
                  let wgQuick = args["wireGuardQuickConfig"] as? String,
                  !serverAddress.isEmpty, !endpoint.isEmpty, !wgQuick.isEmpty else {
                result(FlutterError(code: "invalid_arguments", message: "Missing macOS tunnel configuration", details: nil))
                return
            }
            let dns = args["dnsServers"] as? [String] ?? []
            let included = args["includedRoutes"] as? [String] ?? []
            let excluded = args["excludedRoutes"] as? [String] ?? []
            configureAndStart(
                serverAddress: serverAddress,
                engine: engine,
                endpoint: endpoint,
                dnsServers: dns,
                includedRoutes: included,
                excludedRoutes: excluded,
                wireGuardQuickConfig: wgQuick,
                result: result
            )
        case "stop":
            loadManager { manager, error in
                if let error { result(self.flutterError("load_failed", error)); return }
                manager?.connection.stopVPNTunnel()
                result(nil)
            }
        case "status":
            loadManager { manager, error in
                if let error { result(self.flutterError("load_failed", error)); return }
                result(self.statusName(manager?.connection.status ?? .invalid))
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func loadManager(completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error { completion(nil, error); return }
            if let existing = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleIdentifier
            }) {
                completion(existing, nil)
            } else {
                completion(NETunnelProviderManager(), nil)
            }
        }
    }

    private func configureAndStart(
        serverAddress: String,
        engine: String,
        endpoint: String,
        dnsServers: [String],
        includedRoutes: [String],
        excludedRoutes: [String],
        wireGuardQuickConfig: String,
        result: @escaping FlutterResult
    ) {
        loadManager { manager, error in
            if let error { result(self.flutterError("load_failed", error)); return }
            guard let manager else {
                result(FlutterError(code: "manager_unavailable", message: "NetworkExtension manager unavailable", details: nil))
                return
            }

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleIdentifier
            proto.serverAddress = serverAddress
            proto.providerConfiguration = [
                "engine": engine,
                "endpoint": endpoint,
                "dnsServers": dnsServers,
                "includedRoutes": includedRoutes,
                "excludedRoutes": excludedRoutes,
            ]
            manager.protocolConfiguration = proto
            manager.localizedDescription = Self.localizedDescription
            manager.isEnabled = true
            manager.saveToPreferences { saveError in
                if let saveError { result(self.flutterError("save_failed", saveError)); return }
                manager.loadFromPreferences { reloadError in
                    if let reloadError { result(self.flutterError("reload_failed", reloadError)); return }
                    do {
                        try manager.connection.startVPNTunnel(options: [
                            "wireGuardQuickConfig": wireGuardQuickConfig as NSString,
                        ])
                        result(nil)
                    } catch {
                        result(self.flutterError("start_failed", error))
                    }
                }
            }
        }
    }

    private func statusName(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "invalid"
        }
    }

    private func flutterError(_ code: String, _ error: Error) -> FlutterError {
        FlutterError(code: code, message: error.localizedDescription, details: nil)
    }
}
