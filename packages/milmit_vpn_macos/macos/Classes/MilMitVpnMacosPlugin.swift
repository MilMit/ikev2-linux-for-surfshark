import FlutterMacOS
import Foundation
import NetworkExtension
import Security

public final class MilMitVpnMacosPlugin: NSObject, FlutterPlugin {
    private static let wireGuardBundleIdentifier = "net.milmit.vpn.PacketTunnel"
    private static let openVpnBundleIdentifier = "net.milmit.vpn.OpenVPNPacketTunnel"
    private static let keychainService = "net.milmit.vpn.macos.credentials"

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "net.milmit.vpn/macos", binaryMessenger: registrar.messenger)
        registrar.addMethodCallDelegate(MilMitVpnMacosPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "supportedProtocols":
            result(["wireguard", "ikev2", "openvpn"])
        case "credentialsSaved":
            result((try? credentials()) != nil)
        case "saveCredentials":
            guard let args = call.arguments as? [String: Any],
                  let username = args["username"] as? String,
                  let password = args["password"] as? String,
                  !username.isEmpty, !password.isEmpty else {
                result(FlutterError(code: "invalid_credentials", message: "Username and password are required", details: nil)); return
            }
            do { try saveCredential(username, account: "username"); try saveCredential(password, account: "password"); result(nil) }
            catch { result(flutterError("credential_store_failed", error)) }
        case "start":
            guard let args = call.arguments as? [String: Any],
                  let serverAddress = args["serverAddress"] as? String,
                  let protocolName = args["protocol"] as? String,
                  !serverAddress.isEmpty else {
                result(FlutterError(code: "invalid_arguments", message: "Missing macOS tunnel configuration", details: nil)); return
            }
            switch protocolName.lowercased() {
            case "wireguard": startWireGuard(args, serverAddress: serverAddress, result: result)
            case "ikev2": startIkev2(serverAddress: serverAddress, result: result)
            case "openvpn": startOpenVpn(args, serverAddress: serverAddress, result: result)
            default: result(FlutterError(code: "unsupported_protocol", message: protocolName, details: nil))
            }
        case "stop": stopAll(result: result)
        case "status": status(result: result)
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func startWireGuard(_ args: [String: Any], serverAddress: String, result: @escaping FlutterResult) {
        guard let config = args["wireGuardQuickConfig"] as? String, !config.isEmpty else {
            result(FlutterError(code: "profile_missing", message: "WireGuard configuration is missing", details: nil)); return
        }
        let endpoint = args["endpoint"] as? String ?? serverAddress
        configureTunnel(bundle: Self.wireGuardBundleIdentifier, title: "MilMit VPN — WireGuard", server: serverAddress, options: [
            "wireGuardQuickConfig": config as NSString,
            "endpoint": endpoint as NSString,
        ], result: result)
    }

    private func startOpenVpn(_ args: [String: Any], serverAddress: String, result: @escaping FlutterResult) {
        guard let config = args["openVpnConfig"] as? String, !config.isEmpty,
              let creds = try? credentials() else {
            result(FlutterError(code: "profile_or_credentials_missing", message: "OpenVPN profile or credentials are missing", details: nil)); return
        }
        configureTunnel(bundle: Self.openVpnBundleIdentifier, title: "MilMit VPN — OpenVPN", server: serverAddress, options: [
            "ovpn": Data(config.utf8) as NSData,
            "username": creds.0 as NSString,
            "password": creds.1 as NSString,
        ], result: result)
    }

    private func startIkev2(serverAddress: String, result: @escaping FlutterResult) {
        guard let creds = try? credentials(), let passwordRef = try? persistentReference(account: "password") else {
            result(FlutterError(code: "credentials_missing", message: "IKEv2 credentials are missing", details: nil)); return
        }
        let manager = NEVPNManager.shared()
        manager.loadFromPreferences { error in
            if let error { result(self.flutterError("load_failed", error)); return }
            let proto = NEVPNProtocolIKEv2()
            proto.serverAddress = serverAddress
            proto.remoteIdentifier = serverAddress
            proto.authenticationMethod = .none
            proto.useExtendedAuthentication = true
            proto.username = creds.0
            proto.passwordReference = passwordRef
            proto.enablePFS = true
            proto.deadPeerDetectionRate = .medium
            manager.protocolConfiguration = proto
            manager.localizedDescription = "MilMit VPN — IKEv2"
            manager.isEnabled = true
            manager.saveToPreferences { saveError in
                if let saveError { result(self.flutterError("save_failed", saveError)); return }
                manager.loadFromPreferences { reloadError in
                    if let reloadError { result(self.flutterError("reload_failed", reloadError)); return }
                    do { try manager.connection.startVPNTunnel(); result(nil) }
                    catch { result(self.flutterError("start_failed", error)) }
                }
            }
        }
    }

    private func configureTunnel(bundle: String, title: String, server: String, options: [String: NSObject], result: @escaping FlutterResult) {
        loadTunnelManager(bundle: bundle) { manager, error in
            if let error { result(self.flutterError("load_failed", error)); return }
            let manager = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = bundle
            proto.serverAddress = server
            manager.protocolConfiguration = proto
            manager.localizedDescription = title
            manager.isEnabled = true
            manager.saveToPreferences { saveError in
                if let saveError { result(self.flutterError("save_failed", saveError)); return }
                manager.loadFromPreferences { reloadError in
                    if let reloadError { result(self.flutterError("reload_failed", reloadError)); return }
                    do { try manager.connection.startVPNTunnel(options: options); result(nil) }
                    catch { result(self.flutterError("start_failed", error)) }
                }
            }
        }
    }

    private func loadTunnelManager(bundle: String, completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error { completion(nil, error); return }
            completion(managers?.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundle }), nil)
        }
    }

    private func stopAll(result: @escaping FlutterResult) {
        NEVPNManager.shared().loadFromPreferences { _ in
            NEVPNManager.shared().connection.stopVPNTunnel()
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error { result(self.flutterError("load_failed", error)); return }
                managers?.forEach { manager in
                    let bundle = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    if bundle == Self.wireGuardBundleIdentifier || bundle == Self.openVpnBundleIdentifier { manager.connection.stopVPNTunnel() }
                }
                result(nil)
            }
        }
    }

    private func status(result: @escaping FlutterResult) {
        let ike = NEVPNManager.shared()
        ike.loadFromPreferences { _ in
            if Self.active(ike.connection.status) { result(["state": self.statusName(ike.connection.status), "protocol": "ikev2"]); return }
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error { result(["state": "error", "message": error.localizedDescription]); return }
                for manager in managers ?? [] {
                    guard Self.active(manager.connection.status), let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { continue }
                    if proto.providerBundleIdentifier == Self.wireGuardBundleIdentifier { result(["state": self.statusName(manager.connection.status), "protocol": "wireguard"]); return }
                    if proto.providerBundleIdentifier == Self.openVpnBundleIdentifier { result(["state": self.statusName(manager.connection.status), "protocol": "openvpn"]); return }
                }
                result(["state": "disconnected"])
            }
        }
    }

    private func saveCredential(_ value: String, account: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: account]
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound { var add = base; add.merge(attrs) { _, new in new }; let s = SecItemAdd(add as CFDictionary, nil); if s != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) } }
        else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private func readCredential(account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return value
    }

    private func credentials() throws -> (String, String) { (try readCredential(account: "username"), try readCredential(account: "password")) }

    private func persistentReference(account: String) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: account, kSecReturnPersistentRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let ref = item as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return ref
    }

    private static func active(_ status: NEVPNStatus) -> Bool { [.connected, .connecting, .reasserting, .disconnecting].contains(status) }
    private func statusName(_ status: NEVPNStatus) -> String {
        switch status { case .connected: return "connected"; case .connecting, .reasserting: return "connecting"; case .disconnecting: return "disconnecting"; case .disconnected: return "disconnected"; default: return "invalid" }
    }
    private func flutterError(_ code: String, _ error: Error) -> FlutterError { FlutterError(code: code, message: error.localizedDescription, details: nil) }
}
