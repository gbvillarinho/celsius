import Foundation

/// The piece of state a command changes. Commands for the same field replace each other.
public enum ACField: Hashable, Sendable, CaseIterable {
    case power, mode, target, fan, swing, eco, powerful, sleep
}

/// A control command, encoded as the `{resource: {property: value}}` body of `POST devices/{id}/control`.
public enum ACCommand: Sendable, Equatable {
    case power(Bool)
    case mode(String)
    case targetTemperature(Double)
    case fanSpeed(String)
    case swing(Bool)
    case eco(Bool)
    /// Daikin PowerChill (boost) preset.
    case powerful(Bool)
    /// Hours until the unit turns off; 0 cancels the sleep timer.
    case sleep(hours: Int)

    public var field: ACField {
        switch self {
        case .power: .power
        case .mode: .mode
        case .targetTemperature: .target
        case .fanSpeed: .fan
        case .swing: .swing
        case .eco: .eco
        case .powerful: .powerful
        case .sleep: .sleep
        }
    }

    public var payload: JSONValue {
        switch self {
        case .power(let on):
            ["operation": ["airConOperationMode": .string(on ? "POWER_ON" : "POWER_OFF")]]
        case .mode(let mode):
            ["airConJobMode": ["currentJobMode": .string(mode)]]
        case .targetTemperature(let value):
            ["temperature": ["targetTemperature": .number(value), "unit": "C"]]
        case .fanSpeed(let speed):
            ["airFlow": ["windStrength": .string(speed)]]
        case .swing(let on):
            ["windDirection": ["rotateUpDown": .bool(on)]]
        case .eco(let on):
            ["powerSave": ["powerSaveEnabled": .bool(on)]]
        case .powerful:
            [:]
        case .sleep(let hours) where hours > 0:
            ["sleepTimer": ["relativeHourToStop": .number(Double(hours)), "relativeMinuteToStop": 0]]
        case .sleep:
            ["sleepTimer": ["relativeStopTimer": "UNSET"]]
        }
    }
}
