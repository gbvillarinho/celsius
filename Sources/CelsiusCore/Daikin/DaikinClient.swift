import Foundation

public enum DaikinClientError: Error, LocalizedError, Equatable, Sendable {
    case invalidKey
    case invalidState
    case unsupportedCommand

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "Enter the Daikin integration key from the Daikin Smart AC app."
        case .invalidState: "The Daikin response could not be decrypted or read. Check that the Device Key was generated for this air conditioner's Wi-Fi network; firmware compatibility may also be the cause."
        case .unsupportedCommand: "This Daikin function is not supported by the documented local protocol."
        }
    }
}

/// Provider for Daikin units on the same local network as this Mac.
public struct DaikinClient: ACProvider {
    public static let localCapabilities = ACCapabilities(
        modes: [ACMode.auto, ACMode.dry, ACMode.cool, ACMode.fan],
        fanSpeeds: ["LOW", "MID_LOW", "MID", "MID_HIGH", "HIGH", "AUTO", "SILENT"],
        minTemperature: 18, maxTemperature: 32, temperatureStep: 1,
        supportsEco: true, supportsSwing: true, supportsSleep: false, supportsPowerful: true
    )

    private let key: Data
    private let transport: DaikinLocalTransport
    private let displayName: String

    public init(address: String, key: String, displayName: String? = nil, transport: DaikinLocalTransport? = nil) throws {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawKey = Data(normalized.utf8)
        let decodedKey = Data(base64Encoded: normalized)
        let keyData: Data
        if let decodedKey, [16, 24, 32].contains(decodedKey.count) {
            // Daikin Smart AC exposes its Device Key as Base64 text. The HA integration
            // decodes it before AES; retain raw text support for existing local setups.
            keyData = decodedKey
        } else if [16, 24, 32].contains(rawKey.count) {
            keyData = rawKey
        } else {
            throw DaikinClientError.invalidKey
        }
        self.key = keyData
        self.transport = transport ?? DaikinLocalTransport(address: address)
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.displayName = trimmedName.isEmpty ? "Daikin air conditioner" : trimmedName
    }

    public func devices() async throws -> [ACDevice] {
        [ACDevice(id: "daikin-local", provider: .daikin, modelName: "FTKP09S5VL", displayName: displayName)]
    }

    public func capabilities(deviceID: String) async throws -> ACCapabilities {
        try validate(deviceID)
        return Self.localCapabilities
    }

    public func status(deviceID: String) async throws -> ACStatus {
        try validate(deviceID)
        let response = try await transport.request(method: "GET", path: "/acstatus")
        let frame = try decodeBase64Body(response)
        let plaintext = try DaikinCrypto.decode(frame, key: key, route: .acstatus)
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: plaintext), let port = json["port1"] else {
            throw DaikinClientError.invalidState
        }
        let modeCode = Int(port["mode"]?.double ?? -1)
        let fanCode = Int(port["fan"]?.double ?? -1)
        return ACStatus(
            isOn: port["power"]?.double == 1,
            mode: Self.modeName(modeCode),
            currentTemperature: port["sensors"]?["room_temp"]?.double,
            targetTemperature: port["temperature"]?.double,
            fanSpeed: Self.fanName(fanCode),
            swing: port["v_swing"]?.double.map { $0 == 1 },
            eco: port["econo"]?.double.map { $0 == 1 },
            powerful: port["powerchill"]?.double.map { $0 == 1 },
            firmwareVersion: port["fw_ver"]?.string,
            sleepMinutesLeft: nil
        )
    }

    public func send(_ command: ACCommand, deviceID: String) async throws {
        try validate(deviceID)
        var fields: [String: JSONValue] = [:]
        switch command {
        case .power(let on): fields["power"] = .number(on ? 1 : 0)
        case .mode(let mode): fields["mode"] = .number(Double(try Self.modeCode(mode)))
        case .targetTemperature(let temperature): fields["temperature"] = .number(temperature)
        case .fanSpeed(let fan): fields["fan"] = .number(Double(try Self.fanCode(fan)))
        case .swing(let on): fields["v_swing"] = .number(on ? 1 : 0)
        case .eco(let on):
            fields["econo"] = .number(on ? 1 : 0)
            fields["powerchill"] = .number(0)
        case .powerful(let on):
            fields["powerchill"] = .number(on ? 1 : 0)
            fields["econo"] = .number(0)
        case .sleep: throw DaikinClientError.unsupportedCommand
        }
        let payload = try JSONEncoder().encode(JSONValue.object(["port1": .object(fields)]))
        let encrypted = try DaikinCrypto.encode(payload, key: key)
        let body = Data(encrypted.base64EncodedString().utf8)
        let response = try await transport.request(method: "POST", path: "/acstatus", body: body)
        let responseFrame = try decodeBase64Body(response)
        _ = try DaikinCrypto.decode(responseFrame, key: key, route: .acstatus)
    }

    private func validate(_ deviceID: String) throws {
        guard deviceID == "daikin-local" else { throw DaikinClientError.invalidState }
    }

    private func decodeBase64Body(_ body: Data) throws -> Data {
        let encoded = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let frame = Data(base64Encoded: encoded) else { throw DaikinClientError.invalidState }
        return frame
    }

    private static func modeName(_ code: Int) -> String {
        switch code {
        case 0, 1: ACMode.auto
        case 2: ACMode.dry
        case 3: ACMode.cool
        case 4: ACMode.heat
        case 6: ACMode.fan
        default: "DAIKIN_MODE_\(code)"
        }
    }

    private static func modeCode(_ mode: String) throws -> Int {
        switch mode {
        case ACMode.auto: 1
        case ACMode.dry: 2
        case ACMode.cool: 3
        case ACMode.heat: 4
        case ACMode.fan: 6
        default: try rawCode(mode, prefix: "DAIKIN_MODE_")
        }
    }

    private static func fanName(_ code: Int) -> String {
        switch code {
        case 3: "LOW"
        case 4: "MID_LOW"
        case 5: "MID"
        case 6: "MID_HIGH"
        case 7: "HIGH"
        case 17: "AUTO"
        case 18: "SILENT"
        default: "DAIKIN_FAN_\(code)"
        }
    }

    private static func fanCode(_ fan: String) throws -> Int {
        switch fan {
        case "LOW": 3
        case "MID_LOW": 4
        case "MID": 5
        case "MID_HIGH": 6
        case "HIGH": 7
        case "AUTO": 17
        case "SILENT": 18
        default: try rawCode(fan, prefix: "DAIKIN_FAN_")
        }
    }

    private static func rawCode(_ value: String, prefix: String) throws -> Int {
        guard value.hasPrefix(prefix), let code = Int(value.dropFirst(prefix.count)) else {
            throw DaikinClientError.unsupportedCommand
        }
        return code
    }
}
