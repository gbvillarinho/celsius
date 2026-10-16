import Foundation
import Testing
@testable import CelsiusCore

private func fixture(_ name: String) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

private func json(_ data: Data?) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: try #require(data))
}

// MARK: - Parsing real responses

@Suite struct ParsingTests {
    @Test func statusFromRealState() throws {
        let status = ACStatus(json: try #require(try fixture("state")["response"]))
        #expect(status == ACStatus(
            isOn: true, mode: "COOL", currentTemperature: 26, targetTemperature: 18,
            fanSpeed: "HIGH", swing: false, eco: false, sleepMinutesLeft: nil, hasError: false
        ))
    }

    @Test func sleepTimerRunning() {
        let json: JSONValue = ["sleepTimer": ["relativeStopTimer": "SET", "relativeHourToStop": 1, "relativeMinuteToStop": 35]]
        #expect(ACStatus(json: json).sleepMinutesLeft == 95)
    }

    @Test func temperatureFallsBackToCelsiusEntry() {
        let json: JSONValue = [
            "temperatureInUnits": .array([
                ["currentTemperature": 78, "targetTemperature": 64, "unit": "F"],
                ["currentTemperature": 25, "targetTemperature": 21.5, "unit": "C"],
            ]),
        ]
        let status = ACStatus(json: json)
        #expect(status.currentTemperature == 25)
        #expect(status.targetTemperature == 21.5)
    }

    @Test func capabilitiesFromRealProfile() throws {
        let caps = ACCapabilities(profile: try #require(try fixture("profile")["response"]))
        #expect(Set(caps.modes) == ["FAN", "AIR_DRY", "AUTO", "COOL"])
        #expect(!caps.modes.contains("HEAT"))
        #expect(caps.fanSpeeds == ["LOW", "MID", "HIGH", "AUTO"])
        #expect(caps.minTemperature == 18)
        #expect(caps.maxTemperature == 30)
        #expect(caps.temperatureStep == 0.5)
        #expect(caps.supportsEco && caps.supportsSwing && caps.supportsSleep)
    }

    @Test func capabilitiesFallBackWhenProfileIsEmpty() {
        #expect(ACCapabilities(profile: .object([:])) == .fallback)
    }

    @Test func capabilitiesHideMissingFeatures() {
        let profile: JSONValue = ["property": ["airConJobMode": ["currentJobMode": ["mode": .array(["r", "w"]), "value": ["w": .array(["COOL"])]]]]]
        let caps = ACCapabilities(profile: profile)
        #expect(caps.modes == ["COOL"])
        #expect(!caps.supportsEco && !caps.supportsSwing && !caps.supportsSleep)
    }

    @Test func togglesRowIsHiddenWithoutEco() {
        var caps = ACCapabilities.fallback
        #expect(caps.hasToggles)
        caps.supportsEco = false
        #expect(!caps.hasToggles)
    }

    @Test func togglesRowIsHiddenForMinimalProfile() {
        let profile: JSONValue = ["property": ["airConJobMode": ["currentJobMode": ["mode": .array(["r", "w"]), "value": ["w": .array(["COOL"])]]]]]
        #expect(!ACCapabilities(profile: profile).hasToggles)
    }

    @Test func commonDeviceMapsProviderAndDisplayName() {
        let thinq = ThinQDevice(
            deviceId: "dev-1",
            deviceInfo: .init(deviceType: "DEVICE_AIR_CONDITIONER", modelName: "RAC-model", alias: "Living room")
        )
        let common = ACDevice(thinQ: thinq)
        #expect(common.id == "dev-1")
        #expect(common.provider == .thinQ)
        #expect(common.modelName == "RAC-model")
        #expect(common.displayName == "Living room")
    }

    @Test func devicesFromRealList() throws {
        let data = try JSONEncoder().encode(try #require(try fixture("devices")["response"]))
        let devices = try JSONDecoder().decode([ThinQDevice].self, from: data)
        #expect(devices.count == 1)
        #expect(devices[0].isAirConditioner)
        #expect(devices[0].displayName == "Ar-condicionado")
    }

    @Test func snapRespectsStepAndRange() {
        let caps = ACCapabilities(
            modes: [], fanSpeeds: [], minTemperature: 18, maxTemperature: 30, temperatureStep: 0.5,
            supportsEco: true, supportsSwing: true, supportsSleep: true
        )
        #expect(caps.snap(23.3) == 23.5)
        #expect(caps.snap(23.2) == 23)
        #expect(caps.snap(10) == 18)
        #expect(caps.snap(31) == 30)
    }

    @Test func limitsNarrowRangeAndDropHalfDegrees() {
        let caps = ACCapabilities.fallback  // 18–30, step 1
        let device = ACCapabilities(
            modes: [], fanSpeeds: [], minTemperature: 18, maxTemperature: 30, temperatureStep: 0.5,
            supportsEco: true, supportsSwing: true, supportsSleep: true
        )
        let limited = device.limited(to: .standard)
        #expect(limited.minTemperature == 18 && limited.maxTemperature == 25)
        #expect(limited.temperatureStep == 1)
        #expect(limited.snap(18.5) == 19)
        #expect(limited.snap(29) == 25)

        let half = device.limited(to: TemperatureLimits(minimum: 18, maximum: 25, halfDegrees: true))
        #expect(half.temperatureStep == 0.5)

        // Limits never go beyond what the device accepts, and a device step of 1 stays 1.
        let wide = caps.limited(to: TemperatureLimits(minimum: 10, maximum: 40, halfDegrees: true))
        #expect(wide.minTemperature == 18 && wide.maxTemperature == 30 && wide.temperatureStep == 1)
    }
}

private final class MemoryCredentials: CredentialStorage {
    var values: [String: String] = [:]
    func read(account: String) -> String? { values[account] }
    func write(_ value: String, account: String) -> Bool { values[account] = value; return true }
    func delete(account: String) { values.removeValue(forKey: account) }
}

@Suite struct ProviderSettingsTests {
    @Test func persistsProviderAndAddress() {
        let defaults = UserDefaults(suiteName: "CelsiusTests-\(UUID().uuidString)")!
        let appSettings = AppSettings(defaults: defaults, credentials: MemoryCredentials())
        appSettings.providerKind = .daikin
        appSettings.daikinAddress = "192.0.2.40"
        let reloaded = AppSettings(defaults: defaults, credentials: MemoryCredentials())
        #expect(reloaded.providerKind == .daikin)
        #expect(reloaded.daikinAddress == "192.0.2.40")
    }

    @Test func storesDaikinKeySeparately() {
        let credentials = MemoryCredentials()
        let appSettings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: credentials)
        appSettings.daikinKey = "synthetic-daikin-key"
        #expect(appSettings.daikinKey == "synthetic-daikin-key")
        #expect(credentials.values["daikin-local-key"] == "synthetic-daikin-key")
        #expect(credentials.values["thinq-pat"] == nil)
    }

    @Test func clearsDaikinKey() {
        let credentials = MemoryCredentials()
        let appSettings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: credentials)
        appSettings.daikinKey = "synthetic-daikin-key"
        appSettings.daikinKey = nil
        #expect(credentials.values["daikin-local-key"] == nil)
    }

    @Test func validatesDaikinAddress() {
        #expect(AppSettings.isValidDaikinAddress("192.0.2.40"))
        #expect(AppSettings.isValidDaikinAddress("2001:db8::4"))
        #expect(!AppSettings.isValidDaikinAddress("https://192.0.2.40"))
        #expect(!AppSettings.isValidDaikinAddress("daikin.local"))
    }
}

// MARK: - Command payloads (formats validated against the real unit)

@Suite struct CommandTests {
    @Test(arguments: [
        (ACCommand.power(true), #"{"operation":{"airConOperationMode":"POWER_ON"}}"#),
        (.power(false), #"{"operation":{"airConOperationMode":"POWER_OFF"}}"#),
        (.mode("AIR_DRY"), #"{"airConJobMode":{"currentJobMode":"AIR_DRY"}}"#),
        (.targetTemperature(18), #"{"temperature":{"targetTemperature":18,"unit":"C"}}"#),
        (.targetTemperature(23.5), #"{"temperature":{"targetTemperature":23.5,"unit":"C"}}"#),
        (.fanSpeed("HIGH"), #"{"airFlow":{"windStrength":"HIGH"}}"#),
        (.swing(true), #"{"windDirection":{"rotateUpDown":true}}"#),
        (.eco(false), #"{"powerSave":{"powerSaveEnabled":false}}"#),
        (.sleep(hours: 2), #"{"sleepTimer":{"relativeHourToStop":2,"relativeMinuteToStop":0}}"#),
        (.sleep(hours: 0), #"{"sleepTimer":{"relativeStopTimer":"UNSET"}}"#),
    ])
    func payload(command: ACCommand, expected: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let sortedExpected = try encoder.encode(try JSONDecoder().decode(JSONValue.self, from: Data(expected.utf8)))
        #expect(String(decoding: try encoder.encode(command.payload), as: UTF8.self) == String(decoding: sortedExpected, as: UTF8.self))
    }

    @Test func applyingSleepKeepsRunningCountdown() {
        let status = ACStatus(isOn: true, sleepMinutesLeft: 100)
        #expect(status.applying(.sleep(hours: 2)) == status)
        #expect(status.applying(.sleep(hours: 3)).sleepMinutesLeft == 180)
        #expect(status.applying(.sleep(hours: 0)).sleepMinutesLeft == nil)
    }

    @Test(arguments: [(nil, nil), (1, 1), (60, 1), (61, 2), (95, 2), (120, 2), (121, 3)] as [(Int?, Int?)])
    func sleepTimerHoursRoundsUp(minutesLeft: Int?, hours: Int?) {
        #expect(ACStatus(isOn: true, sleepMinutesLeft: minutesLeft).sleepTimerHours == hours)
    }
}

// MARK: - Daikin frame codec

@Suite struct DaikinCryptoTests {
    private let key = Data("YELLOW SUBMARINE".utf8)

    @Test func roundTripsReferenceVectors() throws {
        let payload = Data(#"{"port1":{"power":1}}"#.utf8)
        let frame = try DaikinCrypto.encode(payload, key: key, iv: Data(repeating: 0, count: 16))
        #expect(try DaikinCrypto.decode(frame, key: key, route: .command) == payload)
    }

    @Test func calculatesCRC16() {
        #expect(DaikinCrypto.crc16(Data("123456789".utf8)) == 0xd64e)
    }

    @Test func detectsWrongKeyOutputAndRejectsInvalidCRCWithoutSecrets() throws {
        let frame = try DaikinCrypto.encode(Data("{}".utf8), key: key, iv: Data(repeating: 1, count: 16))
        let wrongKey = try DaikinCrypto.decode(frame, key: Data("WRONGKEY12345678".utf8), route: .command)
        #expect(wrongKey != Data("{}".utf8))
        #expect(wrongKey != Data("{}".utf8))
        #expect(!String(decoding: wrongKey, as: UTF8.self).contains("WRONGKEY12345678"))
        var corrupt = frame
        corrupt[corrupt.count - 1] ^= 0xff
        #expect(throws: DaikinCryptoError.invalidCRC) {
            try DaikinCrypto.decode(corrupt, key: key, route: .command)
        }
    }

    @Test func rejectsShortFrames() {
        #expect(throws: DaikinCryptoError.shortFrame) {
            try DaikinCrypto.decode(Data(repeating: 0, count: 17), key: key, route: .command)
        }
    }
}

// MARK: - HTTP client

final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var all: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private func stubTransport(
    status: Int = 200,
    body: String,
    recorder: RecordedRequests? = nil
) -> ThinQClient.Transport {
    { request in
        recorder?.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

@Suite struct ClientTests {
    @Test func thinQProviderKeepsExistingRequests() async throws {
        let recorder = RecordedRequests()
        let client: any ACProvider = ThinQClient(
            token: "tok", clientID: "celsius-x", transport: stubTransport(body: #"{"response":{}}"#, recorder: recorder)
        )
        try await client.send(.eco(true), deviceID: "dev1")
        let request = try #require(recorder.all.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api-aic.lgthinq.com/devices/dev1/control")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "x-country") == "BR")
        #expect(request.value(forHTTPHeaderField: "x-client-id") == "celsius-x")
        #expect(request.value(forHTTPHeaderField: "x-conditional-control") == "true")
        #expect(try json(request.httpBody) == ACCommand.eco(true).payload)
    }

    @Test func sendsRequiredHeaders() async throws {
        let recorder = RecordedRequests()
        let client = ThinQClient(token: "tok", clientID: "celsius-x", transport: stubTransport(body: #"{"response":{}}"#, recorder: recorder))
        try await client.send(.eco(true), deviceID: "dev1")

        let request = try #require(recorder.all.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api-aic.lgthinq.com/devices/dev1/control")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "x-country") == "BR")
        #expect(request.value(forHTTPHeaderField: "x-client-id") == "celsius-x")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3")
        #expect(request.value(forHTTPHeaderField: "x-service-phase") == "OP")
        #expect(request.value(forHTTPHeaderField: "x-conditional-control") == "true")
        #expect(request.value(forHTTPHeaderField: "x-message-id")?.count == 22)
        #expect(try json(request.httpBody) == ACCommand.eco(true).payload)
    }

    @Test func messageIDIsURLSafe() {
        for _ in 0..<50 {
            let id = ThinQClient.messageID()
            #expect(id.count == 22)
            #expect(!id.contains("+") && !id.contains("/") && !id.contains("="))
        }
    }

    @Test func mapsInvalidTokenToUnauthorized() async {
        // Real response for an invalid token.
        let client = ThinQClient(token: "bad", clientID: "c", transport: stubTransport(
            status: 401, body: #"{"messageId":"x","error":{"message":"Not allowed api call","code":"1309"}}"#
        ))
        await #expect(throws: ThinQError.unauthorized) { try await client.devices() }
    }

    @Test func mapsStateRejection() async {
        // Real response for POWER_ON while already on.
        let client = ThinQClient(token: "t", clientID: "c", transport: stubTransport(
            status: 400, body: #"{"messageId":"x","error":{"message":"Command not supported in POWER_ON","code":"2302"}}"#
        ))
        await #expect(throws: ThinQError.rejected("Command not supported in POWER_ON")) {
            try await client.send(.power(true), deviceID: "d")
        }
    }

    @Test func mapsOfflineDevice() async {
        let client = ThinQClient(token: "t", clientID: "c", transport: stubTransport(
            status: 400, body: #"{"error":{"message":"Not connected device","code":"1222"}}"#
        ))
        await #expect(throws: ThinQError.deviceOffline) { try await client.status(deviceID: "d") }
    }
}

// MARK: - Daikin local transport and client

private final class DaikinRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [Data] = []
    func append(_ request: Data) { lock.withLock { requests.append(request) } }
    var last: Data? { lock.withLock { requests.last } }
}

private func daikinHTTPResponse(_ payload: Data, key: Data) throws -> Data {
    var frame = try DaikinCrypto.encode(payload, key: key, iv: Data(repeating: 7, count: 16))
    frame.insert(0, at: 16)
    let crc = DaikinCrypto.crc16(Data(frame.dropLast(2)))
    frame[frame.count - 2] = UInt8(crc & 0xff)
    frame[frame.count - 1] = UInt8(crc >> 8)
    let body = Data(frame.base64EncodedString().utf8)
    var response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
    response.append(body)
    return response
}

@Suite struct DaikinTransportTests {
    @Test func parsesValidResponse() async throws {
        let transport = DaikinLocalTransport(address: "192.0.2.40", exchange: { _, _, _, _ in
            Data("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc".utf8)
        })
        #expect(try await transport.request(method: "GET", path: "/acstatus") == Data("abc".utf8))
    }

    @Test func rejectsMalformedOrTruncatedHTTPResponse() async {
        let transport = DaikinLocalTransport(address: "192.0.2.40", exchange: { _, _, _, _ in Data("broken".utf8) })
        await #expect(throws: DaikinTransportError.invalidResponse) {
            try await transport.request(method: "GET", path: "/acstatus")
        }
        let truncated = DaikinLocalTransport(address: "192.0.2.40", exchange: { _, _, _, _ in
            Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabc".utf8)
        })
        await #expect(throws: DaikinTransportError.invalidResponse) {
            try await truncated.request(method: "GET", path: "/acstatus")
        }
    }

    @Test func timesOutUnreachableDevice() async {
        let transport = DaikinLocalTransport(address: "192.0.2.40", exchange: { _, _, _, _ in
            throw DaikinTransportError.timeout
        })
        await #expect(throws: DaikinTransportError.timeout) {
            try await transport.request(method: "GET", path: "/acstatus")
        }
    }
}

@Suite struct DaikinClientTests {
    private let key = Data("YELLOW SUBMARINE".utf8)

    @Test func mapsKnownStateAndCommands() async throws {
        let state = Data(#"{"port1":{"power":1,"mode":3,"temperature":22,"fan":17,"v_swing":1,"econo":1,"sensors":{"room_temp":24}}}"#.utf8)
        let response = try daikinHTTPResponse(state, key: key)
        let recorder = DaikinRequestRecorder()
        let transport = DaikinLocalTransport(address: "192.0.2.40", exchange: { _, _, request, _ in
            recorder.append(request)
            return response
        })
        let client = try DaikinClient(address: "192.0.2.40", key: String(decoding: key, as: UTF8.self), transport: transport)
        let status = try await client.status(deviceID: "daikin-local")
        #expect(status.isOn)
        #expect(status.mode == ACMode.cool)
        #expect(status.targetTemperature == 22)
        #expect(status.currentTemperature == 24)
        #expect(status.fanSpeed == "AUTO")
        #expect(status.swing == true && status.eco == true)
        try await client.send(.power(false), deviceID: "daikin-local")
        #expect(String(decoding: try #require(recorder.last), as: UTF8.self).contains("POST /acstatus"))
    }

    @Test func rejectsWrongKeyWithoutRevealingIt() async throws {
        let state = Data(#"{"port1":{"power":1,"mode":3,"temperature":22,"fan":17}}"#.utf8)
        let response = try daikinHTTPResponse(state, key: key)
        let transport = DaikinLocalTransport(address: "192.0.2.40", exchange: { _, _, _, _ in response })
        let client = try DaikinClient(address: "192.0.2.40", key: "WRONGKEY12345678", transport: transport)
        await #expect(throws: DaikinClientError.invalidState) {
            try await client.status(deviceID: "daikin-local")
        }
    }

    @Test func preservesUnknownModeAndFanValues() async throws {
        let state = Data(#"{"port1":{"power":0,"mode":91,"temperature":20,"fan":42}}"#.utf8)
        let response = try daikinHTTPResponse(state, key: key)
        let transport = DaikinLocalTransport(address: "192.0.2.40", exchange: { _, _, _, _ in response })
        let client = try DaikinClient(address: "192.0.2.40", key: String(decoding: key, as: UTF8.self), transport: transport)
        let status = try await client.status(deviceID: "daikin-local")
        #expect(status.mode == "DAIKIN_MODE_91")
        #expect(status.fanSpeed == "DAIKIN_FAN_42")
    }

    @Test func hidesUnsupportedFeatures() async throws {
        let client = try DaikinClient(address: "192.0.2.40", key: String(decoding: key, as: UTF8.self), transport: DaikinLocalTransport(address: "192.0.2.40", exchange: { _, _, _, _ in Data() }))
        let capabilities = try await client.capabilities(deviceID: "daikin-local")
        #expect(capabilities.supportsEco && capabilities.supportsSwing)
        #expect(!capabilities.supportsSleep)
        await #expect(throws: DaikinClientError.unsupportedCommand) {
            try await client.send(.sleep(hours: 1), deviceID: "daikin-local")
        }
    }
}

// MARK: - Store

final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var isOpen = false

    func markRequested() { lock.withLock { requested = true } }
    func open() { lock.withLock { isOpen = true } }
    var isOpenNow: Bool { lock.withLock { isOpen } }
    func waitUntilRequested() async {
        while !lock.withLock({ requested }) { try? await Task.sleep(for: .milliseconds(5)) }
    }
    func waitUntilOpen() async {
        while !lock.withLock({ isOpen }) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 0)
}

private struct OfflineACProvider: ACProvider {
    func devices() async throws -> [ACDevice] { throw DaikinTransportError.timeout }
    func capabilities(deviceID: String) async throws -> ACCapabilities { .fallback }
    func status(deviceID: String) async throws -> ACStatus { throw DaikinTransportError.timeout }
    func send(_ command: ACCommand, deviceID: String) async throws { throw DaikinTransportError.timeout }
}

private struct StaticACProvider: ACProvider {
    func devices() async throws -> [ACDevice] { [ACDevice(id: "fake", provider: .daikin, displayName: "Fake")] }
    func capabilities(deviceID: String) async throws -> ACCapabilities { .fallback }
    func status(deviceID: String) async throws -> ACStatus { ACStatus(isOn: false) }
    func send(_ command: ACCommand, deviceID: String) async throws {}
}

@MainActor
@Suite struct StoreTests {
    private func makeStore(
        state: String, clock: Clock, recorder: RecordedRequests,
        settings: InMemorySettings = InMemorySettings(token: "tok"), deviceIDs: [String] = ["d1"]
    ) -> ACStore {
        let list = deviceIDs.map { #"{"deviceId":"\#($0)","deviceInfo":{"deviceType":"DEVICE_AIR_CONDITIONER","alias":"AC \#($0)"}}"# }
        let devices = #"{"response":[\#(list.joined(separator: ","))]}"#
        let transport: ThinQClient.Transport = { request in
            recorder.append(request)
            let path = request.url!.path
            let body = path.hasSuffix("/devices") ? devices
                : path.hasSuffix("/state") ? #"{"response":\#(state)}"#
                : #"{"response":{}}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return ACStore(
            settings: settings,
            makeClient: { ThinQClient(token: $0, clientID: $1, transport: transport) },
            now: { clock.now }
        )
    }

    @Test func requiresDaikinSetupWhenConfigurationIsMissing() async {
        let settings = InMemorySettings()
        settings.providerKind = .daikin
        let store = ACStore(settings: settings)
        await store.refresh()
        #expect(store.connection == .needsSetup)
    }

    @Test func reportsOfflineWhenDaikinAddressIsUnreachable() async {
        let settings = InMemorySettings(token: "lg-token")
        settings.providerKind = .daikin
        settings.daikinAddress = "192.0.2.40"
        settings.daikinKey = "YELLOW SUBMARINE"
        let recorder = RecordedRequests()
        let store = ACStore(
            settings: settings,
            makeClient: { _, _ in ThinQClient(token: "unused", clientID: "test", transport: stubTransport(body: #"{"response":{}}"#, recorder: recorder)) },
            makeProvider: { _ in OfflineACProvider() }
        )
        await store.refresh()
        if case .offline = store.connection {} else { Issue.record("Expected the selected Daikin to be offline") }
        #expect(!store.deviceCapabilities.supportsSleep)
        #expect(recorder.all.isEmpty)
    }

    @Test func switchesProvidersWithoutReplacingLGSettings() async {
        let settings = InMemorySettings(token: "lg-token", deviceID: "lg-device")
        settings.daikinAddress = "192.0.2.40"
        settings.daikinKey = "synthetic-daikin-key"
        let store = ACStore(settings: settings, makeProvider: { _ in StaticACProvider() })
        await store.selectProvider(.daikin)
        #expect(settings.token == "lg-token")
        #expect(settings.daikinKey == "synthetic-daikin-key")
        await store.selectProvider(.thinQ)
        #expect(settings.token == "lg-token")
        #expect(settings.deviceID == "lg-device")
    }

    @Test func listsEveryAirConditionerAndStartsWithTheFirst() async throws {
        let settings = InMemorySettings(token: "tok")
        let store = makeStore(state: offState, clock: Clock(), recorder: RecordedRequests(), settings: settings, deviceIDs: ["d1", "d2"])
        await store.refresh()
        #expect(store.devices.map(\.id) == ["d1", "d2"])
        #expect(store.device?.id == "d1")
        #expect(settings.deviceID == "d1")
    }

    @Test func rememberedUnitIsPickedOverTheFirst() async throws {
        let settings = InMemorySettings(token: "tok", deviceID: "d2")
        let store = makeStore(state: offState, clock: Clock(), recorder: RecordedRequests(), settings: settings, deviceIDs: ["d1", "d2"])
        await store.refresh()
        #expect(store.device?.id == "d2")
    }

    @Test func selectingAnotherUnitReadsItsStateAndSendsToIt() async throws {
        let settings = InMemorySettings(token: "tok")
        let recorder = RecordedRequests()
        let store = makeStore(state: offState, clock: Clock(), recorder: recorder, settings: settings, deviceIDs: ["d1", "d2"])
        await store.refresh()
        store.perform(.power(true))

        await store.selectDevice(id: "d2")
        #expect(store.device?.id == "d2")
        #expect(settings.deviceID == "d2")
        #expect(store.connection == .connected)
        #expect(store.status?.isOn == false)
        #expect(recorder.all.contains { $0.url?.path == "/devices/d2/state" })
        #expect(recorder.all.contains { $0.url?.path == "/devices/d2/profile" })

        store.perform(.targetTemperature(20))
        for _ in 0..<50 where store.isSending {
            try await Task.sleep(for: .milliseconds(10))
        }
        let controls = recorder.all.filter { $0.url?.path.hasSuffix("/control") == true }
        #expect(controls.contains { $0.url?.path == "/devices/d2/control" })
        #expect(!controls.contains { $0.url?.path == "/devices/d2/control" && (try? json($0.httpBody)) == ACCommand.power(true).payload })
    }

    @Test func readInFlightForThePreviousUnitIsDiscardedWhenSwitching() async throws {
        let gate = Gate()
        let switchWait = Gate()
        let recorder = RecordedRequests()
        let onState = #"{"operation":{"airConOperationMode":"POWER_ON"},"airConJobMode":{"currentJobMode":"COOL"},"temperature":{"currentTemperature":26,"targetTemperature":18,"unit":"C"}}"#
        let otherState = #"{"operation":{"airConOperationMode":"POWER_OFF"},"airConJobMode":{"currentJobMode":"COOL"},"temperature":{"currentTemperature":26,"targetTemperature":25,"unit":"C"}}"#
        let list = ["d1", "d2"].map { #"{"deviceId":"\#($0)","deviceInfo":{"deviceType":"DEVICE_AIR_CONDITIONER","alias":"AC \#($0)"}}"# }
        let transport: ThinQClient.Transport = { request in
            recorder.append(request)
            let path = request.url!.path
            let body: String
            if path.hasSuffix("/devices") {
                body = #"{"response":[\#(list.joined(separator: ","))]}"#
            } else if path == "/devices/d1/state" {
                gate.markRequested()
                await gate.waitUntilOpen()
                body = #"{"response":\#(onState)}"#
            } else if path == "/devices/d2/state" {
                body = #"{"response":\#(otherState)}"#
            } else {
                body = #"{"response":{}}"#
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let settings = InMemorySettings(token: "tok")
        let store = ACStore(
            settings: settings,
            makeClient: { ThinQClient(token: $0, clientID: $1, transport: transport) },
            now: { Date(timeIntervalSinceReferenceDate: 0) },
            sleep: { _ in
                switchWait.markRequested()
                await Task.yield()
            }
        )

        let firstRead = Task { await store.refresh() }
        await gate.waitUntilRequested()
        #expect(store.device?.id == "d1")

        let switching = Task { await store.selectDevice(id: "d2") }
        await switchWait.waitUntilRequested()
        gate.open()
        await firstRead.value
        await switching.value

        #expect(store.device?.id == "d2")
        #expect(settings.deviceID == "d2")
        #expect(store.connection == .connected)
        #expect(store.status?.isOn == false)
        #expect(store.status?.targetTemperature == 25)
        #expect(recorder.all.contains { $0.url?.path == "/devices/d2/profile" })
    }

    @Test func selectingTheCurrentOrAnUnknownUnitDoesNothing() async throws {
        let recorder = RecordedRequests()
        let store = makeStore(state: offState, clock: Clock(), recorder: recorder, deviceIDs: ["d1", "d2"])
        await store.refresh()
        let before = recorder.all.count
        await store.selectDevice(id: "d1")
        await store.selectDevice(id: "nope")
        #expect(recorder.all.count == before)
        #expect(store.device?.id == "d1")
    }

    @Test func signingOutForgetsTheUnits() async throws {
        let settings = InMemorySettings(token: "tok")
        let store = makeStore(state: offState, clock: Clock(), recorder: RecordedRequests(), settings: settings, deviceIDs: ["d1", "d2"])
        await store.refresh()
        #expect(store.devices.count == 2)

        store.signOut()
        #expect(store.devices.isEmpty)
        #expect(store.device == nil)
        #expect(settings.deviceID == nil)
        #expect(store.connection == .needsSetup)
    }

    @Test func switchingUnitsWhileAReadWaitsToRetryKeepsTheNewUnit() async throws {
        let gate = Gate()
        let offState = self.offState
        let list = ["d1", "d2"].map { #"{"deviceId":"\#($0)","deviceInfo":{"deviceType":"DEVICE_AIR_CONDITIONER","alias":"AC \#($0)"}}"# }
        let firstTry = Gate()
        let transport: ThinQClient.Transport = { request in
            let path = request.url!.path
            func reply(_ body: String) -> (Data, URLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if path.hasSuffix("/devices") { return reply(#"{"response":[\#(list.joined(separator: ","))]}"#) }
            if path == "/devices/d1/state" {
                if !firstTry.isOpenNow { firstTry.open(); throw URLError(.timedOut) }
                return reply(#"{"response":\#(offState)}"#)
            }
            if path == "/devices/d2/state" {
                return reply(#"{"response":{"operation":{"airConOperationMode":"POWER_ON"},"airConJobMode":{"currentJobMode":"COOL"},"temperature":{"currentTemperature":26,"targetTemperature":22,"unit":"C"}}}"#)
            }
            return reply(#"{"response":{}}"#)
        }
        let settings = InMemorySettings(token: "tok")
        let store = ACStore(
            settings: settings,
            makeClient: { ThinQClient(token: $0, clientID: $1, transport: transport) },
            sleep: { duration in
                if duration == .milliseconds(500) {
                    gate.markRequested()
                    await gate.waitUntilOpen()
                } else {
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
        )

        let firstRead = Task { await store.refresh() }
        await gate.waitUntilRequested()
        #expect(store.device?.id == "d1")

        let switching = Task { await store.selectDevice(id: "d2") }
        try await Task.sleep(for: .milliseconds(20))
        gate.open()
        await firstRead.value
        await switching.value

        #expect(store.device?.id == "d2")
        #expect(settings.deviceID == "d2")
        #expect(store.connection == .connected)
        #expect(store.status?.isOn == true)
        #expect(store.status?.targetTemperature == 22)
    }

    private let offState = #"{"operation":{"airConOperationMode":"POWER_OFF"},"airConJobMode":{"currentJobMode":"COOL"},"temperature":{"currentTemperature":26,"targetTemperature":18,"unit":"C"}}"#

    @Test func temperatureLimitsArePersisted() {
        let settings = InMemorySettings(token: "tok")
        let store = ACStore(settings: settings)
        #expect(store.capabilities.maxTemperature == 25)
        store.temperatureLimits.maximum = 27
        #expect(settings.temperatureLimits.maximum == 27)
        #expect(store.capabilities.maxTemperature == 27)
    }

    @Test func needsSetupWithoutToken() {
        let store = ACStore(settings: InMemorySettings())
        #expect(store.connection == .needsSetup)
    }

    @Test func optimisticOverrideSurvivesStaleServerStateUntilExpiry() async throws {
        let clock = Clock()
        let store = makeStore(state: offState, clock: clock, recorder: RecordedRequests())
        await store.refresh()
        #expect(store.connection == .connected)
        #expect(store.status?.isOn == false)

        store.perform(.power(true))
        #expect(store.status?.isOn == true)
        for _ in 0..<50 where store.isSending {
            try await Task.sleep(for: .milliseconds(10))
        }

        // The cloud still reports "off" a moment later: the UI keeps showing the change.
        clock.now += 2
        await store.refresh()
        #expect(store.status?.isOn == true)

        // Never confirmed: after the lifetime it falls back to the server state.
        clock.now += ACStore.overrideLifetime
        await store.refresh()
        #expect(store.status?.isOn == false)
    }

    @Test func confirmedOverrideIsDropped() async throws {
        let clock = Clock()
        let store = makeStore(state: offState, clock: clock, recorder: RecordedRequests())
        await store.refresh()
        store.perform(.targetTemperature(18))  // Same as the server: nothing to do.
        #expect(store.isSending == false)
    }

    @Test func sendsCommandToDevice() async throws {
        let recorder = RecordedRequests()
        let store = makeStore(state: offState, clock: Clock(), recorder: recorder)
        await store.refresh()
        store.perform(.power(true))
        for _ in 0..<50 where store.isSending {
            try await Task.sleep(for: .milliseconds(10))
        }
        let control = try #require(recorder.all.first { $0.url?.path.hasSuffix("/control") == true })
        #expect(control.url?.path == "/devices/d1/control")
        #expect(try json(control.httpBody) == ACCommand.power(true).payload)
    }
}

@Suite struct UpdateTests {
    @Test(arguments: [
        ("1.0.2", "1.0.1", true),
        ("v1.0.2", "1.0.1", true),
        ("1.1", "1.0.9", true),
        ("2.0.0", "1.9.9", true),
        ("1.0.10", "1.0.9", true),
        ("1.0.1", "1.0.1", false),
        ("1.0", "1.0.0", false),
        ("1.0.0", "1.0.1", false),
        ("nightly", "1.0.1", false),
    ])
    func comparesVersions(candidate: String, current: String, expected: Bool) {
        #expect(UpdateChecker.isNewer(candidate, than: current) == expected)
    }

    private func checker(current: String, status: Int = 200, tag: String = "v1.2.0") -> UpdateChecker {
        let body = #"{"tag_name":"\#(tag)","html_url":"https://github.com/gbvillarinho/celsius/releases/tag/\#(tag)"}"#
        return UpdateChecker(currentVersion: current, transport: stubTransport(status: status, body: body))
    }

    @Test func reportsANewerRelease() async throws {
        let update = try #require(try await checker(current: "1.0.2").availableUpdate())
        #expect(update.version == "1.2.0")
        #expect(update.url.absoluteString.hasSuffix("/v1.2.0"))
    }

    @Test func reportsNothingWhenUpToDate() async throws {
        #expect(try await checker(current: "1.2.0").availableUpdate() == nil)
        #expect(try await checker(current: "1.3.0").availableUpdate() == nil)
    }

    @Test func failsOnAnErrorResponse() async {
        await #expect(throws: ThinQError.self) { try await checker(current: "1.0.0", status: 403).availableUpdate() }
    }

    @MainActor @Test func storeKeepsTheUpdateAndChecksOncePerDay() async {
        let clock = Clock()
        let calls = RecordedRequests()
        let body = #"{"tag_name":"v1.2.0","html_url":"https://github.com/gbvillarinho/celsius/releases/tag/v1.2.0"}"#
        let transport: UpdateChecker.Transport = { request in
            calls.append(request)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let store = ACStore(
            settings: InMemorySettings(token: "tok"),
            now: { clock.now },
            updateChecker: UpdateChecker(currentVersion: "1.0.0", transport: transport)
        )
        await store.checkForUpdate()
        #expect(store.availableUpdate?.version == "1.2.0")
        await store.checkForUpdate()
        #expect(calls.all.count == 1)

        clock.now.addTimeInterval(ACStore.updateCheckInterval + 1)
        await store.checkForUpdate()
        #expect(calls.all.count == 2)
    }
}

/// A fake LG cloud that can fail on demand: each path suffix has a list of failures handed out in order.
final class FlakyCloud: @unchecked Sendable {
    enum Failure {
        case network
        case rateLimited
        /// The unit gets the command but the response never arrives.
        case timeoutAfterApplying(state: String)
    }

    private let lock = NSLock()
    private var state: String
    private var failures: [String: [Failure]] = [:]
    private var requests: [String] = []
    /// What the state becomes once a command succeeds, like the unit changing a setting on its own.
    var stateAfterControl: String? {
        get { lock.withLock { _stateAfterControl } }
        set { lock.withLock { _stateAfterControl = newValue } }
    }
    private var _stateAfterControl: String?

    init(state: String) { self.state = state }

    func fail(_ suffix: String, with list: [Failure]) { lock.withLock { failures[suffix, default: []] += list } }
    func count(_ suffix: String) -> Int { lock.withLock { requests.filter { $0.hasSuffix(suffix) }.count } }

    var transport: ThinQClient.Transport {
        { [self] request in try handle(request) }
    }

    private func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        let path = request.url!.path
        let failure: Failure? = lock.withLock {
            requests.append(path)
            guard let key = failures.keys.first(where: { path.hasSuffix($0) }), !(failures[key]?.isEmpty ?? true) else { return nil }
            return failures[key]!.removeFirst()
        }
        func reply(_ status: Int, _ body: String) -> (Data, URLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        switch failure {
        case .network:
            throw URLError(.timedOut)
        case .rateLimited:
            return reply(429, #"{"error":{"code":"1306","message":"Too many requests"}}"#)
        case .timeoutAfterApplying(let newState):
            lock.withLock { state = newState }
            throw URLError(.timedOut)
        case nil:
            if path.hasSuffix("/control") {
                lock.withLock { if let next = _stateAfterControl { state = next } }
            }
            let current = lock.withLock { state }
            if path.hasSuffix("/devices") {
                return reply(200, #"{"response":[{"deviceId":"d1","deviceInfo":{"deviceType":"DEVICE_AIR_CONDITIONER","alias":"AC"}}]}"#)
            }
            return reply(200, path.hasSuffix("/state") ? #"{"response":\#(current)}"# : #"{"response":{}}"#)
        }
    }
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Duration] = []
    var all: [Duration] { lock.withLock { storage } }
    func add(_ duration: Duration) { lock.withLock { storage.append(duration) } }
}

@MainActor
@Suite struct ResilienceTests {
    private let offState = #"{"operation":{"airConOperationMode":"POWER_OFF"},"airConJobMode":{"currentJobMode":"COOL"},"temperature":{"currentTemperature":26,"targetTemperature":18,"unit":"C"}}"#
    private let onState = #"{"operation":{"airConOperationMode":"POWER_ON"},"airConJobMode":{"currentJobMode":"COOL"},"temperature":{"currentTemperature":26,"targetTemperature":18,"unit":"C"}}"#

    private func makeStore(_ cloud: FlakyCloud, sleeps: SleepLog) -> ACStore {
        ACStore(
            settings: InMemorySettings(token: "tok"),
            makeClient: { ThinQClient(token: $0, clientID: $1, transport: cloud.transport) },
            sleep: { sleeps.add($0) }
        )
    }

    private func waitForSends(_ store: ACStore) async throws {
        for _ in 0..<100 where store.isSending {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aReadThatFailsOnceIsRetriedQuietly() async {
        let cloud = FlakyCloud(state: offState)
        cloud.fail("/state", with: [.network])
        let store = makeStore(cloud, sleeps: SleepLog())
        await store.refresh()
        #expect(store.connection == .connected)
        #expect(store.isReconnecting == false)
        #expect(store.status != nil)
        #expect(cloud.count("/state") == 2)
    }

    @Test func offlineOnlyAfterSeveralFailedRefreshes() async {
        let cloud = FlakyCloud(state: offState)
        let store = makeStore(cloud, sleeps: SleepLog())
        await store.refresh()
        #expect(store.connection == .connected)

        // Each refresh makes three attempts: the first try plus two retries.
        cloud.fail("/state", with: Array(repeating: .network, count: 9))
        await store.refresh()
        #expect(store.connection == .connected)
        #expect(store.isReconnecting)
        await store.refresh()
        #expect(store.connection == .connected)
        await store.refresh()
        guard case .offline = store.connection else { Issue.record("expected offline, got \(store.connection)"); return }
        #expect(store.isReconnecting == false)

        await store.refresh()
        #expect(store.connection == .connected)
        #expect(store.isReconnecting == false)
    }

    @Test func offlineRightAwayWhenThereIsNoStateYet() async {
        let cloud = FlakyCloud(state: offState)
        cloud.fail("/devices", with: Array(repeating: .network, count: 3))
        let store = makeStore(cloud, sleeps: SleepLog())
        await store.refresh()
        guard case .offline = store.connection else { Issue.record("expected offline, got \(store.connection)"); return }
    }

    @Test func aFailedCommandIsRetriedAndTheChangeStaysVisible() async throws {
        let cloud = FlakyCloud(state: offState)
        let store = makeStore(cloud, sleeps: SleepLog())
        await store.refresh()
        cloud.fail("/control", with: [.network])
        store.perform(.power(true))
        #expect(store.status?.isOn == true)
        try await waitForSends(store)
        #expect(store.status?.isOn == true)
        #expect(store.transientMessage == nil)
        // The timeout was ambiguous, so the store checked the state first (still off) and then sent again.
        #expect(cloud.count("/control") == 2)
    }

    @Test func aRateLimitedCommandWaitsLongerAndIsNotLost() async throws {
        let cloud = FlakyCloud(state: offState)
        let sleeps = SleepLog()
        let store = makeStore(cloud, sleeps: sleeps)
        await store.refresh()
        cloud.fail("/control", with: [.rateLimited])
        store.perform(.power(true))
        try await waitForSends(store)
        #expect(cloud.count("/control") == 2)
        #expect(sleeps.all.contains(ACStore.rateLimitRetryDelay))
        #expect(store.transientMessage == nil)
    }

    @Test func aCommandTheUnitAlreadyAppliedIsNotSentTwice() async throws {
        let cloud = FlakyCloud(state: offState)
        let store = makeStore(cloud, sleeps: SleepLog())
        await store.refresh()
        cloud.fail("/control", with: [.timeoutAfterApplying(state: onState)])
        store.perform(.power(true))
        try await waitForSends(store)
        #expect(cloud.count("/control") == 1)
        #expect(store.transientMessage == nil)
    }

    @Test func aCommandThatKeepsFailingIsDroppedWithAMessage() async throws {
        let cloud = FlakyCloud(state: offState)
        let store = makeStore(cloud, sleeps: SleepLog())
        await store.refresh()
        cloud.fail("/control", with: [.rateLimited, .rateLimited])
        store.perform(.power(true))
        try await waitForSends(store)
        #expect(cloud.count("/control") == 2)
        #expect(store.status?.isOn == false)
        #expect(store.transientMessage != nil)
    }

    @Test func burstsOfDifferentCommandsAreSpacedOut() async throws {
        let cloud = FlakyCloud(state: offState)
        let sleeps = SleepLog()
        let store = makeStore(cloud, sleeps: sleeps)
        await store.refresh()
        store.perform(.power(true))
        store.perform(.eco(true))
        store.perform(.swing(true))
        try await waitForSends(store)
        #expect(cloud.count("/control") == 3)
        #expect(sleeps.all.filter { $0 == ACStore.minimumSendGap }.count == 2)
    }

    @Test func ecoReadsTheStateAgainUntilTheTargetMoves() async throws {
        let cloud = FlakyCloud(state: offState)
        cloud.stateAfterControl = offState.replacingOccurrences(of: #""targetTemperature":18"#, with: #""targetTemperature":22"#)
        let store = makeStore(cloud, sleeps: SleepLog())
        await store.refresh()
        #expect(store.status?.targetTemperature == 18)
        store.perform(.eco(true))
        try await waitForSends(store)
        for _ in 0..<100 where store.serverStatus?.targetTemperature != 22 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.status?.targetTemperature == 22)
        try await Task.sleep(for: .milliseconds(100))
        // The first read after the command already shows the new target, so it stops there.
        #expect(cloud.count("/state") == 2)
    }

    @Test func ecoKeepsReadingWhenTheTargetStaysTheSame() async throws {
        let cloud = FlakyCloud(state: offState)
        let store = makeStore(cloud, sleeps: SleepLog())
        await store.refresh()
        store.perform(.eco(true))
        try await waitForSends(store)
        for _ in 0..<100 where cloud.count("/state") < 4 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cloud.count("/state") == 4)
    }
}
