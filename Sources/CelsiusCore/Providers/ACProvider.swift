import Foundation

/// The service used to control the configured air conditioner.
public enum ACProviderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case thinQ
    case daikin
}

/// Provider-independent identity and display information for an air conditioner.
public struct ACDevice: Sendable, Equatable, Identifiable {
    public let id: String
    public let provider: ACProviderKind
    public let modelName: String?
    public let displayName: String
    public var isAirConditioner: Bool { true }
    public var deviceInfo: ThinQDevice.Info {
        ThinQDevice.Info(deviceType: "DEVICE_AIR_CONDITIONER", modelName: modelName, alias: displayName)
    }

    public init(id: String, provider: ACProviderKind, modelName: String? = nil, displayName: String) {
        self.id = id
        self.provider = provider
        self.modelName = modelName
        self.displayName = displayName
    }

    public init(thinQ device: ThinQDevice) {
        self.init(
            id: device.id,
            provider: .thinQ,
            modelName: device.deviceInfo.modelName,
            displayName: device.displayName
        )
    }
}

/// Common operations exposed by a supported air-conditioner integration.
public protocol ACProvider: Sendable {
    func devices() async throws -> [ACDevice]
    func capabilities(deviceID: String) async throws -> ACCapabilities
    func status(deviceID: String) async throws -> ACStatus
    func send(_ command: ACCommand, deviceID: String) async throws
}

/// Builds a provider from the user's locally saved settings.
public typealias ACProviderFactory = @MainActor (SettingsStorage) throws -> any ACProvider
