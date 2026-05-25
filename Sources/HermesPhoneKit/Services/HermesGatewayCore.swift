import Foundation

struct HermesChatBootstrapStatus: Equatable, Sendable {
    var sshConnected = false
    var pythonAvailable = false
    var hermesCLIAvailable = false
    var hermesVersion: String?
    var tuiGatewayAvailable = false
    var apiServerAvailable = false
    var apiAuthenticated = false
    var apiServerPort = 8642
    var apiModel: String?
    var canUseNativeChat = false
    var fallbackReason: String?
}

struct HermesGatewayEvent: Identifiable, Hashable, Sendable {
    let id = UUID()
    let type: String
    let sessionID: String?
    let payload: [String: JSONValue]
    let rawLine: String?
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}
