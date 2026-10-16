import Foundation
import Security
import Network

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
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: account == "daikin-local-key" ? "Celsius – Daikin integration key" : "Celsius – LG ThinQ token",
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = account == "daikin-local-key" ? "Celsius – Daikin integration key" : "Celsius – LG ThinQ token"
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

/// Injectable wrapper around generic-password Keychain operations.
public protocol CredentialStorage: AnyObject {
    func read(account: String) -> String?
    @discardableResult func write(_ value: String, account: String) -> Bool
    func delete(account: String)
}

public final class KeychainCredentialStorage: CredentialStorage {
    public init() {}
    public func read(account: String) -> String? { Keychain.read(account) }
    @discardableResult public func write(_ value: String, account: String) -> Bool { Keychain.write(value, account: account) }
    public func delete(account: String) { Keychain.delete(account) }
}

/// Where the app keeps its configuration. Abstracted so tests and snapshots don't touch the keychain.
public protocol SettingsStorage: AnyObject {
    var providerKind: ACProviderKind { get set }
    var daikinAddress: String? { get set }
    var daikinName: String? { get set }
    var daikinKey: String? { get set }
    var token: String? { get set }
    var clientID: String { get }
    var deviceID: String? { get set }
    var temperatureLimits: TemperatureLimits { get set }
}

public final class AppSettings: SettingsStorage {
    private let defaults: UserDefaults
    private let credentials: CredentialStorage
    private static let tokenAccount = "thinq-pat"
    private static let daikinKeyAccount = "daikin-local-key"

    public init(defaults: UserDefaults = .standard, credentials: CredentialStorage = KeychainCredentialStorage()) {
        self.defaults = defaults
        self.credentials = credentials
    }

    public var providerKind: ACProviderKind {
        get { defaults.string(forKey: "providerKind").flatMap(ACProviderKind.init(rawValue:)) ?? .thinQ }
        set { defaults.set(newValue.rawValue, forKey: "providerKind") }
    }

    public var daikinAddress: String? {
        get { defaults.string(forKey: "daikinAddress") }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(value?.isEmpty == true ? nil : value, forKey: "daikinAddress")
        }
    }

    public var daikinName: String? {
        get { defaults.string(forKey: "daikinName") }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(value?.isEmpty == true ? nil : value, forKey: "daikinName")
        }
    }

    public var daikinKey: String? {
        get { credentials.read(account: Self.daikinKeyAccount) }
        set {
            if let newValue, !newValue.isEmpty { credentials.write(newValue, account: Self.daikinKeyAccount) }
            else { credentials.delete(account: Self.daikinKeyAccount) }
        }
    }

    public static func isValidDaikinAddress(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.contains("/"), !candidate.contains("@"), !candidate.contains("#") else { return false }
        if let ip = IPv4Address(candidate) { return ip.rawValue.count == 4 }
        if let ip = IPv6Address(candidate) { return ip.rawValue.count == 16 }
        return false
    }

    /// `CELSIUS_PAT` overrides the keychain, for development runs from the terminal.
    public var token: String? {
        get {
            if let env = ProcessInfo.processInfo.environment["CELSIUS_PAT"], !env.isEmpty { return env }
            return credentials.read(account: Self.tokenAccount)
        }
        set {
            if let newValue, !newValue.isEmpty {
                credentials.write(newValue, account: Self.tokenAccount)
            } else {
                credentials.delete(account: Self.tokenAccount)
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
}

public final class InMemorySettings: SettingsStorage {
    public var providerKind: ACProviderKind = .thinQ
    public var daikinAddress: String?
    public var daikinName: String?
    public var daikinKey: String?
    public var token: String?
    public var clientID = "celsius-test"
    public var deviceID: String?
    public var temperatureLimits: TemperatureLimits

    public init(token: String? = nil, deviceID: String? = nil, temperatureLimits: TemperatureLimits = .standard) {
        self.token = token
        self.deviceID = deviceID
        self.temperatureLimits = temperatureLimits
    }
}
