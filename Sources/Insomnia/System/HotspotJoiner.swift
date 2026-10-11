import CoreWLAN
import Foundation

protocol HotspotJoining: Sendable {
    /// Returns false when the SSID-filtered scan finds no matching network.
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool
}

enum HotspotJoinError: Error, LocalizedError {
    case missingInterface(String)

    var errorDescription: String? {
        switch self {
        case let .missingInterface(name):
            return "CoreWLAN could not open Wi-Fi interface \(name)"
        }
    }
}

struct CoreWLANHotspotJoiner: HotspotJoining {
    /// The scan and the association block for seconds, so they run on a
    /// GCD thread rather than holding a thread of Swift's cooperative pool.
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try Self.joinBlocking(ssid: ssid, password: password, interfaceName: interfaceName)
                })
            }
        }
    }

    private static func joinBlocking(ssid: String, password: String, interfaceName: String) throws -> Bool {
        guard let interface = CWWiFiClient.shared().interface(withName: interfaceName) else {
            throw HotspotJoinError.missingInterface(interfaceName)
        }
        // macOS may require Location Services permission for SSID visibility.
        // Keep this scan SSID-filtered: association works with the returned
        // CWNetwork even when its `ssid` property is redacted.
        let networks = try interface.scanForNetworks(withSSID: ssid.data(using: .utf8))
        guard let network = networks.first else { return false }
        try interface.associate(to: network, password: password)
        return true
    }
}
