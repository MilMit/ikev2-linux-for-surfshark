import Flutter
import NetworkExtension
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        if let controller = window?.rootViewController as? FlutterViewController {
            MobileVpnBridge.register(with: controller.binaryMessenger)
        }
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}

final class MobileVpnBridge: NSObject {
    static let channelName = "net.milmit.vpn/ios"
    static let providerBundleIdentifier = "net.milmit.vpn.PacketTunnel"
    static let appGroup = "group.net.milmit.vpn"

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        let bridge = MobileVpnBridge()
        channel.setMethodCallHandler(bridge.handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "prepare":
            result(true)
        case "connect":
            guard
                let args = call.arguments as? [String: Any],
                let providerId = args["providerId"] as? String,
                let serverId = args["serverId"] as? String,
                let protocolName = args["protocol"] as? String,
                Self.safeToken(providerId, max: 80),
                Self.safeToken(serverId, max: 160),
                protocolName.lowercased() == "wireguard"
            else {
                result(FlutterError(code: "invalid_request", message: "Invalid iOS VPN request", details: nil))
                return
            }
            connect(providerId: providerId, serverId: serverId, result: result)
        case "disconnect":
            loadManager { manager, error in
                if let error = error {
                    result(FlutterError(code: "manager_load_failed", message: error.localizedDescription, details: nil))
                    return
                }
                manager?.connection.stopVPNTunnel()
                result(nil)
            }
        case "status":
            loadManager { manager, error in
                if let error = error {
                    result(["state": "error", "message": error.localizedDescription])
                    return
                }
                result(["state": Self.statusName(manager?.connection.status ?? .invalid)])
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func connect(providerId: String, serverId: String, result: @escaping FlutterResult) {
        guard let wgQuickConfig = Self.loadProfile(serverId: serverId) else {
            result(FlutterError(code: "profile_missing", message: "WireGuard profile is missing from the app group", details: nil))
            return
        }

        loadManager { manager, error in
            if let error = error {
                result(FlutterError(code: "manager_load_failed", message: error.localizedDescription, details: nil))
                return
            }

            let vpnManager = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleIdentifier
            proto.serverAddress = serverId
            proto.providerConfiguration = [
                "providerId": providerId,
                "serverId": serverId,
                "protocol": "wireguard"
            ]
            vpnManager.protocolConfiguration = proto
            vpnManager.localizedDescription = "MilMit VPN"
            vpnManager.isEnabled = true

            vpnManager.saveToPreferences { saveError in
                if let saveError = saveError {
                    result(FlutterError(code: "save_failed", message: saveError.localizedDescription, details: nil))
                    return
                }
                vpnManager.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        result(FlutterError(code: "reload_failed", message: loadError.localizedDescription, details: nil))
                        return
                    }
                    do {
                        try vpnManager.connection.startVPNTunnel(options: [
                            "serverId" as NSString: serverId as NSString,
                            "providerId" as NSString: providerId as NSString,
                            "wgQuickConfig" as NSString: wgQuickConfig as NSString
                        ])
                        result(nil)
                    } catch {
                        result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
                    }
                }
            }
        }
    }

    private func loadManager(completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                completion(nil, error)
                return
            }
            let manager = managers?.first { candidate in
                guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol else { return false }
                return proto.providerBundleIdentifier == Self.providerBundleIdentifier
            }
            completion(manager, nil)
        }
    }

    private static func loadProfile(serverId: String) -> String? {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return nil
        }
        let url = root
            .appendingPathComponent("wireguard", isDirectory: true)
            .appendingPathComponent("\(serverId).conf", isDirectory: false)
        guard let data = try? Data(contentsOf: url), data.count <= 64 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func safeToken(_ value: String, max: Int) -> Bool {
        guard !value.isEmpty, value.count <= max else { return false }
        return value.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
    }

    private static func statusName(_ status: NEVPNStatus) -> String {
        switch status {
        case .connected: return "connected"
        case .connecting, .reasserting: return "connecting"
        case .disconnecting: return "disconnecting"
        case .disconnected, .invalid: return "disconnected"
        @unknown default: return "error"
        }
    }
}
