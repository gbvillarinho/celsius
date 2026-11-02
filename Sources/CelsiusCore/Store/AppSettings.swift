import Foundation
import Security

/// Generic-password storage in the login keychain.
public enum Keychain {
    public static let service = "com.gabrielvillarinho.celsius"

    public static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func write(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Celsius – LG ThinQ token"
            // Keep the token on this Mac: no iCloud Keychain sync, no backups.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    public static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Where the app keeps its configuration. Abstracted so tests and snapshots don't touch the keychain.
public protocol SettingsStorage: AnyObject {
    var token: String? { get set }
    var clientID: String { get }
    var deviceID: String? { get set }
    var temperatureLimits: TemperatureLimits { get set }
    /// The country of the LG account, sent as `x-country`.
    var country: String { get set }
}

public final class AppSettings: SettingsStorage {
    private let defaults: UserDefaults
    private static let tokenAccount = "thinq-pat"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `CELSIUS_PAT` overrides the keychain, for development runs from the terminal.
    public var token: String? {
        get {
            if let env = ProcessInfo.processInfo.environment["CELSIUS_PAT"], !env.isEmpty { return env }
            return Keychain.read(Self.tokenAccount)
        }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.write(newValue, account: Self.tokenAccount)
            } else {
                Keychain.delete(Self.tokenAccount)
            }
        }
    }

    public var clientID: String {
        if let id = defaults.string(forKey: "clientID") { return id }
        let id = "celsius-\(UUID().uuidString.lowercased())"
        defaults.set(id, forKey: "clientID")
        return id
    }

    public var deviceID: String? {
        get { defaults.string(forKey: "deviceID") }
        set { defaults.set(newValue, forKey: "deviceID") }
    }

    public var temperatureLimits: TemperatureLimits {
        get {
            defaults.data(forKey: "temperatureLimits")
                .flatMap { try? JSONDecoder().decode(TemperatureLimits.self, from: $0) } ?? .standard
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "temperatureLimits") }
    }

    public var country: String {
        get { defaults.string(forKey: "country") ?? ThinQClient.defaultCountry }
        set { defaults.set(newValue, forKey: "country") }
    }
}

public final class InMemorySettings: SettingsStorage {
    public var token: String?
    public var clientID = "celsius-test"
    public var deviceID: String?
    public var temperatureLimits: TemperatureLimits
    public var country = ThinQClient.defaultCountry

    public init(token: String? = nil, deviceID: String? = nil, temperatureLimits: TemperatureLimits = .standard) {
        self.token = token
        self.deviceID = deviceID
        self.temperatureLimits = temperatureLimits
    }
}
