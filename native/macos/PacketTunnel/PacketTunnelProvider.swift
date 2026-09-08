import NetworkExtension
import os.log

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "net.milmit.vpn", category: "PacketTunnel")
    private var engine: MilMitPacketTunnelEngine?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol else {
            completionHandler(NSError(domain: "net.milmit.vpn", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid tunnel provider configuration"]))
            return
        }

        let raw = protocolConfiguration.providerConfiguration ?? [:]
        let configuration: MilMitTunnelConfiguration
        do {
            configuration = try MilMitTunnelConfiguration(providerConfiguration: raw, runtimeOptions: options)
        } catch {
            completionHandler(error)
            return
        }

        guard let engine = MilMitPacketTunnelEngineFactory.make(engine: configuration.engine, provider: self) else {
            logger.error("Requested engine \(configuration.engine, privacy: .public) is not linked into the signed extension")
            completionHandler(NSError(domain: "net.milmit.vpn", code: 3, userInfo: [NSLocalizedDescriptionKey: "Signed packet tunnel engine bridge is not linked"] ))
            return
        }

        self.engine = engine
        setTunnelNetworkSettings(configuration.baseNetworkSettings()) { [weak self] error in
            guard let self else {
                completionHandler(NSError(domain: "net.milmit.vpn", code: 4, userInfo: [NSLocalizedDescriptionKey: "Packet tunnel provider was released during startup"]))
                return
            }
            if let error {
                self.engine = nil
                completionHandler(error)
                return
            }
            engine.start(configuration: configuration, packetFlow: self.packetFlow) { [weak self] startError in
                if startError != nil { self?.engine = nil }
                completionHandler(startError)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("Stopping packet tunnel, reason: \(reason.rawValue)")
        guard let engine else {
            completionHandler()
            return
        }
        engine.stop { [weak self] in
            self?.engine = nil
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let engine else {
            let response = ["ok": false, "error": "engine_bridge_not_linked"] as [String : Any]
            completionHandler?(try? JSONSerialization.data(withJSONObject: response))
            return
        }
        engine.handle(message: messageData) { response in completionHandler?(response) }
    }
}
