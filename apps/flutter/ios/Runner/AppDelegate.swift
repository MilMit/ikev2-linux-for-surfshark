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
    static let wireGuardBundleIdentifier = "net.milmit.vpn.PacketTunnel"
    static let openVpnBundleIdentifier = "net.milmit.vpn.OpenVPNPacketTunnel"
    static let appGroup = "group.net.milmit.vpn"

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        let bridge = MobileVpnBridge()
        channel.setMethodCallHandler(bridge.handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "supportedProtocols":
            result(["wireguard", "ikev2", "openvpn"])

        case "prepare":
            guard let args = call.arguments as? [String: Any],
                  let protocolName = args["protocol"] as? String,
                  Self.isProtocol(protocolName) else {
                result(FlutterError(code: "invalid_request", message: "Invalid iOS VPN protocol", details: nil))
                return
            }
            result(true)

        case "credentialsSaved":
            result(MobileCredentialStore.exists())

        case "saveCredentials":
            guard let args = call.arguments as? [String: Any],
                  let username = args["username"] as? String,
                  let password = args["password"] as? String else {
                result(FlutterError(code: "invalid_credentials", message: "Username and password are required", details: nil))
                return
            }
            do {
                try MobileCredentialStore.save(username: username, password: password)
                result(nil)
            } catch {
                result(FlutterError(code: "credential_store_failed", message: error.localizedDescription, details: nil))
            }

        case "connect":
            guard
                let args = call.arguments as? [String: Any],
                let providerId = args["providerId"] as? String,
                let serverId = args["serverId"] as? String,
                let hostname = args["hostname"] as? String,
                let protocolName = args["protocol"] as? String,
                Self.safeToken(providerId, max: 80),
                Self.safeToken(serverId, max: 160),
                Self.safeHostname(hostname),
                Self.isProtocol(protocolName)
            else {
                result(FlutterError(code: "invalid_request", message: "Invalid iOS VPN request", details: nil))
                return
            }
            connect(
                providerId: providerId,
                serverId: serverId,
                hostname: hostname,
                protocolName: protocolName.lowercased(),
                result: result
            )

        case "disconnect":
            disconnectAll(result: result)

        case "status":
            status(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func connect(
        providerId: String,
        serverId: String,
        hostname: String,
        protocolName: String,
        result: @escaping FlutterResult
    ) {
        switch protocolName {
        case "wireguard":
            connectWireGuard(providerId: providerId, serverId: serverId, hostname: hostname, result: result)
        case "ikev2":
            connectIkev2(serverId: serverId, hostname: hostname, result: result)
        case "openvpn":
            connectOpenVpn(providerId: providerId, serverId: serverId, hostname: hostname, result: result)
        default:
            result(FlutterError(code: "unsupported_protocol", message: protocolName, details: nil))
        }
    }

    private func connectWireGuard(
        providerId: String,
        serverId: String,
        hostname: String,
        result: @escaping FlutterResult
    ) {
        guard let wgQuickConfig = Self.loadProfile(directory: "wireguard", serverId: serverId, extension: "conf", maxBytes: 64 * 1024) else {
            result(FlutterError(code: "profile_missing", message: "WireGuard profile is missing from the app group", details: nil))
            return
        }

        loadTunnelManager(bundleIdentifier: Self.wireGuardBundleIdentifier) { manager, error in
            if let error = error {
                result(FlutterError(code: "manager_load_failed", message: error.localizedDescription, details: nil))
                return
            }
            let vpnManager = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.wireGuardBundleIdentifier
            proto.serverAddress = hostname
            proto.providerConfiguration = ["providerId": providerId, "serverId": serverId, "protocol": "wireguard"]
            vpnManager.protocolConfiguration = proto
            vpnManager.localizedDescription = "MilMit VPN — WireGuard"
            vpnManager.isEnabled = true
            self.saveAndStart(vpnManager, options: [
                "serverId": serverId as NSString,
                "providerId": providerId as NSString,
                "wgQuickConfig": wgQuickConfig as NSString,
            ], result: result)
        }
    }

    private func connectOpenVpn(
        providerId: String,
        serverId: String,
        hostname: String,
        result: @escaping FlutterResult
    ) {
        guard let ovpn = Self.loadProfileData(directory: "openvpn", serverId: serverId, extension: "ovpn", maxBytes: 512 * 1024) else {
            result(FlutterError(code: "profile_missing", message: "OpenVPN profile is missing from the app group", details: nil))
            return
        }
        let credentials: (username: String, password: String)
        do {
            credentials = try MobileCredentialStore.load()
        } catch {
            result(FlutterError(code: "credentials_missing", message: "OpenVPN credentials are not saved", details: nil))
            return
        }

        loadTunnelManager(bundleIdentifier: Self.openVpnBundleIdentifier) { manager, error in
            if let error = error {
                result(FlutterError(code: "manager_load_failed", message: error.localizedDescription, details: nil))
                return
            }
            let vpnManager = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.openVpnBundleIdentifier
            proto.serverAddress = hostname
            proto.providerConfiguration = ["providerId": providerId, "serverId": serverId, "protocol": "openvpn"]
            vpnManager.protocolConfiguration = proto
            vpnManager.localizedDescription = "MilMit VPN — OpenVPN"
            vpnManager.isEnabled = true
            self.saveAndStart(vpnManager, options: [
                "ovpn": ovpn as NSData,
                "username": credentials.username as NSString,
                "password": credentials.password as NSString,
                "serverId": serverId as NSString,
            ], result: result)
        }
    }

    private func connectIkev2(serverId: String, hostname: String, result: @escaping FlutterResult) {
        let credentials: (username: String, password: String)
        let passwordReference: Data
        do {
            credentials = try MobileCredentialStore.load()
            passwordReference = try MobileCredentialStore.passwordPersistentReference()
        } catch {
            result(FlutterError(code: "credentials_missing", message: "IKEv2 credentials are not saved", details: nil))
            return
        }

        let manager = NEVPNManager.shared()
        manager.loadFromPreferences { error in
            if let error = error {
                result(FlutterError(code: "manager_load_failed", message: error.localizedDescription, details: nil))
                return
            }
            let proto = NEVPNProtocolIKEv2()
            proto.serverAddress = hostname
            proto.remoteIdentifier = hostname
            proto.localIdentifier = nil
            proto.authenticationMethod = .none
            proto.useExtendedAuthentication = true
            proto.username = credentials.username
            proto.passwordReference = passwordReference
            proto.disconnectOnSleep = false
            proto.enablePFS = true
            proto.deadPeerDetectionRate = .medium

            manager.protocolConfiguration = proto
            manager.localizedDescription = "MilMit VPN — IKEv2"
            manager.isEnabled = true
            manager.saveToPreferences { saveError in
                if let saveError = saveError {
                    result(FlutterError(code: "save_failed", message: saveError.localizedDescription, details: nil))
                    return
                }
                manager.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        result(FlutterError(code: "reload_failed", message: loadError.localizedDescription, details: nil))
                        return
                    }
                    do {
                        try manager.connection.startVPNTunnel()
                        result(nil)
                    } catch {
                        result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
                    }
                }
            }
        }
    }

    private func saveAndStart(
        _ manager: NETunnelProviderManager,
        options: [String: NSObject],
        result: @escaping FlutterResult
    ) {
        manager.saveToPreferences { saveError in
            if let saveError = saveError {
                result(FlutterError(code: "save_failed", message: saveError.localizedDescription, details: nil))
                return
            }
            manager.loadFromPreferences { loadError in
                if let loadError = loadError {
                    result(FlutterError(code: "reload_failed", message: loadError.localizedDescription, details: nil))
                    return
                }
                do {
                    try manager.connection.startVPNTunnel(options: options)
                    result(nil)
                } catch {
                    result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func disconnectAll(result: @escaping FlutterResult) {
        NEVPNManager.shared().loadFromPreferences { _ in
            NEVPNManager.shared().connection.stopVPNTunnel()
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error = error {
                    result(FlutterError(code: "manager_load_failed", message: error.localizedDescription, details: nil))
                    return
                }
                managers?.forEach { manager in
                    let bundle = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    if bundle == Self.wireGuardBundleIdentifier || bundle == Self.openVpnBundleIdentifier {
                        manager.connection.stopVPNTunnel()
                    }
                }
                result(nil)
            }
        }
    }

    private func status(result: @escaping FlutterResult) {
        let ikeManager = NEVPNManager.shared()
        ikeManager.loadFromPreferences { _ in
            let ikeStatus = ikeManager.connection.status
            if Self.isActive(ikeStatus) {
                result(["state": Self.statusName(ikeStatus), "protocol": "ikev2"])
                return
            }
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error = error {
                    result(["state": "error", "message": error.localizedDescription])
                    return
                }
                for manager in managers ?? [] {
                    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { continue }
                    let protocolName: String?
                    switch proto.providerBundleIdentifier {
                    case Self.wireGuardBundleIdentifier: protocolName = "wireguard"
                    case Self.openVpnBundleIdentifier: protocolName = "openvpn"
                    default: protocolName = nil
                    }
                    if let protocolName, Self.isActive(manager.connection.status) {
                        result(["state": Self.statusName(manager.connection.status), "protocol": protocolName])
                        return
                    }
                }
                result(["state": "disconnected"])
            }
        }
    }

    private func loadTunnelManager(
        bundleIdentifier: String,
        completion: @escaping (NETunnelProviderManager?, Error?) -> Void
    ) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                completion(nil, error)
                return
            }
            let manager = managers?.first { candidate in
                guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol else { return false }
                return proto.providerBundleIdentifier == bundleIdentifier
            }
            completion(manager, nil)
        }
    }

    private static func loadProfile(
        directory: String,
        serverId: String,
        extension ext: String,
        maxBytes: Int
    ) -> String? {
        guard let data = loadProfileData(directory: directory, serverId: serverId, extension: ext, maxBytes: maxBytes) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func loadProfileData(
        directory: String,
        serverId: String,
        extension ext: String,
        maxBytes: Int
    ) -> Data? {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let url = root
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("\(serverId).\(ext)", isDirectory: false)
        guard let data = try? Data(contentsOf: url), data.count > 0, data.count <= maxBytes else { return nil }
        return data
    }

    private static func safeToken(_ value: String, max: Int) -> Bool {
        guard !value.isEmpty, value.count <= max else { return false }
        return value.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
    }

    private static func safeHostname(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253 else { return false }
        return value.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
    }

    private static func isProtocol(_ value: String) -> Bool {
        ["wireguard", "ikev2", "openvpn"].contains(value.lowercased())
    }

    private static func isActive(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting, .disconnecting: return true
        default: return false
        }
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
