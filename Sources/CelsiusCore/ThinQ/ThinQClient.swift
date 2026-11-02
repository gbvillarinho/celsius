import Foundation
import os

public enum ThinQError: Error, Equatable, Sendable {
    /// The token is missing, invalid or lacks permission.
    case unauthorized
    /// The unit isn't reachable from LG's cloud.
    case deviceOffline
    case rateLimited
    /// The unit rejected the command in its current state (e.g. powered off).
    case rejected(String)
    case api(code: String, message: String)
    case network(String)
    /// LG's servers failed (HTTP 5xx) without a usable error body.
    case serverError(Int)
    case invalidResponse

    /// Worth trying again shortly: the same request may well succeed. A unit the cloud reports as offline
    /// isn't included, because that's a definite answer rather than a hiccup.
    public var isTransient: Bool {
        switch self {
        case .network, .rateLimited, .serverError: true
        case .unauthorized, .deviceOffline, .rejected, .api, .invalidResponse: false
        }
    }

    /// "Not provided feature" or "Fail device control". Some units answer this now and then to a target
    /// they do take, and accept the very same command a moment later.
    public var isMomentaryRefusal: Bool {
        if case .api(let code, _) = self { code == "2201" || code == "2208" } else { false }
    }

    public var message: String {
        switch self {
        case .unauthorized: "Token is invalid or expired"
        case .deviceOffline: "The air conditioner is offline"
        case .rateLimited: "Too many requests, try again soon"
        case .rejected(let message): message
        case .api(_, let message): message
        case .network(let message): message
        case .serverError: "LG's servers are having trouble"
        case .invalidResponse: "Unexpected response from LG"
        }
    }

    static func from(code: String, message: String, status: Int) -> ThinQError {
        switch code {
        case "1103", "1218", "1301", "1302", "1303", "1305", "1309":
            return .unauthorized
        case "1222", "2209", "2301":
            return .deviceOffline
        case "1306":
            return .rateLimited
        case "2302", "2303", "2304", "2305":
            return .rejected(message)
        default:
            if status == 401 { return .unauthorized }
            if status >= 500 { return .serverError(status) }
            return .api(code: code, message: message)
        }
    }
}

/// Client for the official LG ThinQ Connect REST API, authenticated with a Personal Access Token.
public struct ThinQClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Brazil is served by the Americas region.
    public static let baseURL = URL(string: "https://api-aic.lgthinq.com/")!
    public static let country = "BR"
    static let apiKey = "v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3"

    private static let log = Logger(subsystem: "com.gabrielvillarinho.celsius", category: "api")

    let token: String
    let clientID: String
    let transport: Transport

    public init(token: String, clientID: String, transport: Transport? = nil) {
        self.token = token
        self.clientID = clientID
        self.transport = transport ?? { request in
            try await URLSession.shared.data(for: request)
        }
    }

    public func devices() async throws -> [ThinQDevice] {
        let response = try await perform("GET", "devices")
        let data = try JSONEncoder().encode(response)
        do {
            return try JSONDecoder().decode([ThinQDevice].self, from: data)
        } catch {
            throw ThinQError.invalidResponse
        }
    }

    public func capabilities(deviceID: String) async throws -> ACCapabilities {
        ACCapabilities(profile: try await perform("GET", "devices/\(deviceID)/profile"))
    }

    public func status(deviceID: String) async throws -> ACStatus {
        ACStatus(json: try await perform("GET", "devices/\(deviceID)/state"))
    }

    public func send(_ command: ACCommand, deviceID: String) async throws {
        _ = try await perform("POST", "devices/\(deviceID)/control", body: command.payload)
    }

    /// Reads the raw state and logs it next to a command the unit kept refusing, for bug reports.
    public func logState(deviceID: String, refused command: ACCommand) async {
        guard let state = try? await perform("GET", "devices/\(deviceID)/state") else { return }
        Self.log.notice("refused \(Self.text(command.payload), privacy: .public) in state \(Self.text(state), privacy: .public)")
    }

    static func text(_ value: JSONValue) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }

    func makeRequest(_ method: String, _ path: String, body: JSONValue? = nil) throws -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.country, forHTTPHeaderField: "x-country")
        request.setValue(Self.messageID(), forHTTPHeaderField: "x-message-id")
        request.setValue(clientID, forHTTPHeaderField: "x-client-id")
        request.setValue(Self.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("OP", forHTTPHeaderField: "x-service-phase")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            // Rejects commands the unit can't run right now instead of queueing them.
            request.setValue("true", forHTTPHeaderField: "x-conditional-control")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func perform(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        let request = try makeRequest(method, path, body: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError {
            Self.log.error("\(method, privacy: .public) \(path, privacy: .public) failed: \(error.code.rawValue, privacy: .public)")
            throw ThinQError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let envelope = try? JSONDecoder().decode(JSONValue.self, from: data)

        if let error = envelope?["error"] {
            let code = error["code"]?.string ?? ""
            Self.log.error("\(method, privacy: .public) \(path, privacy: .public) status \(status, privacy: .public) code \(code, privacy: .public)")
            throw ThinQError.from(
                code: code,
                message: error["message"]?.string ?? "Request failed",
                status: status
            )
        }
        guard (200..<300).contains(status), let envelope else {
            Self.log.error("\(method, privacy: .public) \(path, privacy: .public) status \(status, privacy: .public)")
            if status >= 500 { throw ThinQError.serverError(status) }
            throw status == 401 ? ThinQError.unauthorized : ThinQError.invalidResponse
        }
        return envelope["response"] ?? .null
    }

    /// 16 random bytes, URL-safe base64 without padding (22 characters).
    static func messageID() -> String {
        let bytes = withUnsafeBytes(of: UUID().uuid) { Data($0) }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
