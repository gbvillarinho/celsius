import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
    case needsSetup
    case loading
    case connected
    case offline(String)
    case unauthorized
    case deviceError
}

/// Source of truth for the UI: the last state read from the selected provider, overlaid with optimistic changes.
///
/// The cloud can take a few seconds to reflect a command, so each change is kept as an override until
/// the server confirms it or it expires. Commands are sent one at a time; a newer command for the same
/// field replaces one that hasn't been sent yet.
@MainActor
@Observable
public final class ACStore {
    public private(set) var serverStatus: ACStatus?
    /// What the device's profile says it supports.
    public private(set) var deviceCapabilities: ACCapabilities = .fallback
    public private(set) var connection: ConnectionState = .loading
    public private(set) var device: ACDevice?
    public private(set) var devices: [ACDevice] = []
    public private(set) var providerKind: ACProviderKind
    public private(set) var hasToken: Bool
    public private(set) var isSending = false
    /// A short-lived error to show in the footer, e.g. a rejected command.
    public private(set) var transientMessage: String?
    /// True while a few requests in a row have failed but the last known state is still being shown.
    public private(set) var isReconnecting = false
    /// A newer release than the running app, if the last check found one.
    public private(set) var availableUpdate: AppUpdate?
    private var overrides: [ACField: Override] = [:]

    /// The user's temperature range, saved as soon as it changes.
    public var temperatureLimits: TemperatureLimits {
        didSet { settings.temperatureLimits = temperatureLimits }
    }

    /// Polls faster while the popover is open.
    public var isPopoverVisible = false {
        didSet {
            guard oldValue != isPopoverVisible, isActive else { return }
            startPolling(immediately: isPopoverVisible)
        }
    }

    public static let overrideLifetime: TimeInterval = 8
    public static let visibleInterval: Duration = .seconds(20)
    public static let backgroundInterval: Duration = .seconds(300)
    /// How long the −/+ buttons wait for the value to settle before sending it.
    static let stepDebounce: Duration = .milliseconds(700)
    /// When to read the state back after a command, to confirm it (or recover from a failure).
    static let refreshAfterSend: Duration = .seconds(3)
    static let refreshAfterFailure: Duration = .seconds(1)
    /// Eco changes the unit's target temperature on its own, and the cloud is slow to report it, so the
    /// state is read a few more times, stopping as soon as the target moves.
    static let ecoFollowUpDelays: [Duration] = [.seconds(3), .seconds(3), .seconds(4)]
    static let messageDuration: Duration = .seconds(4)
    /// How often a unit switch checks whether the read for the previous unit has finished.
    static let switchPollInterval: Duration = .milliseconds(50)
    /// Waits before each retry of a read that failed in a way that may pass on its own.
    static let readRetryDelays: [Duration] = [.milliseconds(500), .milliseconds(1500)]
    /// Consecutive failed refreshes before the UI says the connection is lost.
    static let failuresBeforeOffline = 3
    /// Wait before sending a failed command once more, and the longer wait after a rate limit.
    static let commandRetryDelay: Duration = .seconds(1)
    static let rateLimitRetryDelay: Duration = .seconds(2)
    /// Pause between two commands in a burst, so LG's rate limit isn't hit.
    static let minimumSendGap: Duration = .milliseconds(400)
    /// How long to wait before asking GitHub for a new release again.
    static let updateCheckInterval: TimeInterval = 24 * 60 * 60

    @ObservationIgnored private let settings: SettingsStorage
    @ObservationIgnored private let makeClient: (String, String) -> ThinQClient
    @ObservationIgnored private let makeProvider: ACProviderFactory?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private let updateChecker: UpdateChecker?
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var failureStreak = 0
    @ObservationIgnored private var lastUpdateCheck: Date?
    @ObservationIgnored private var capabilitiesLoaded = false
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var queue: [ACCommand] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshSoonTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    struct Override {
        var command: ACCommand
        var expires: Date
    }

    public init(
        settings: SettingsStorage,
        makeClient: @escaping (String, String) -> ThinQClient = { ThinQClient(token: $0, clientID: $1) },
        makeProvider: ACProviderFactory? = nil,
        now: @escaping () -> Date = Date.init,
        updateChecker: UpdateChecker? = nil,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.updateChecker = updateChecker
        self.sleep = sleep
        self.settings = settings
        self.makeClient = makeClient
        self.makeProvider = makeProvider
        self.now = now
        self.isPreview = false
        self.temperatureLimits = settings.temperatureLimits
        self.deviceCapabilities = settings.providerKind == .daikin ? DaikinClient.localCapabilities : .fallback
        self.providerKind = settings.providerKind
        self.hasToken = Self.isConfigured(settings, provider: settings.providerKind)
        if !hasToken { connection = .needsSetup }
    }

    /// A store with fixed data that never touches the network, for snapshots.
    public init(
        previewStatus: ACStatus?, capabilities: ACCapabilities, connection: ConnectionState = .connected,
        availableUpdate: AppUpdate? = nil, isReconnecting: Bool = false, devices: [ACDevice]? = nil
    ) {
        // Limits that keep the given capabilities as they are.
        let limits = TemperatureLimits(
            minimum: capabilities.minTemperature, maximum: capabilities.maxTemperature,
            halfDegrees: capabilities.temperatureStep < 1
        )
        self.settings = InMemorySettings(token: "preview", temperatureLimits: limits)
        self.temperatureLimits = limits
        self.providerKind = .thinQ
        self.hasToken = true
        self.makeClient = { ThinQClient(token: $0, clientID: $1) }
        self.makeProvider = nil
        self.now = Date.init
        self.isPreview = true
        self.updateChecker = nil
        self.sleep = { _ in }
        self.availableUpdate = availableUpdate
        self.isReconnecting = isReconnecting
        self.serverStatus = previewStatus
        self.deviceCapabilities = capabilities
        self.connection = connection
        let preview = ACDevice(
            id: "preview", provider: .thinQ, modelName: "RAC_056905_WW", displayName: "Ar-condicionado"
        )
        self.devices = devices ?? [preview]
        self.device = self.devices.first ?? preview
    }

    // MARK: State

    /// What the UI shows: server state plus pending changes.
    public var status: ACStatus? {
        guard var status = serverStatus else { return nil }
        let date = now()
        for field in ACField.allCases {
            if let override = overrides[field], override.expires > date {
                status = status.applying(override.command)
            }
        }
        return status
    }

    /// What the UI offers: the device's capabilities within the user's temperature limits.
    public var capabilities: ACCapabilities { deviceCapabilities.limited(to: temperatureLimits) }

    public var configuredDaikinAddress: String? { settings.daikinAddress }
    public var configuredDaikinName: String? { settings.daikinName }

    public func setDaikinName(_ name: String) {
        guard providerKind == .daikin else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.daikinName = trimmed.isEmpty ? nil : trimmed
        if let device {
            let renamed = ACDevice(id: device.id, provider: device.provider, modelName: device.modelName,
                                   displayName: settings.daikinName ?? "Daikin air conditioner")
            self.device = renamed
            devices = [renamed]
        }
    }

    private static func isConfigured(_ settings: SettingsStorage, provider: ACProviderKind) -> Bool {
        switch provider {
        case .thinQ: return !(settings.token?.isEmpty ?? true)
        case .daikin:
            let keyLength = settings.daikinKey.map { Data($0.utf8).count } ?? 0
            return settings.daikinAddress.map(AppSettings.isValidDaikinAddress) == true && [16, 24, 32].contains(keyLength)
        }
    }

    private func refreshConfigurationState() {
        providerKind = settings.providerKind
        hasToken = Self.isConfigured(settings, provider: settings.providerKind)
    }

    // MARK: Lifecycle

    public func start() {
        isActive = true
        startPolling(immediately: true)
        Task { await checkForUpdate() }
    }

    /// Looks for a newer release, at most once a day. A failure is silent: it's not worth bothering the user.
    func checkForUpdate() async {
        guard let updateChecker, !isPreview else { return }
        let date = now()
        if let last = lastUpdateCheck, date.timeIntervalSince(last) < Self.updateCheckInterval { return }
        do {
            availableUpdate = try await updateChecker.availableUpdate()
            lastUpdateCheck = date
        } catch {
            // Leave lastUpdateCheck unset so a network failure is retried on the next start.
        }
    }

    /// Stops polling, e.g. while the Mac sleeps.
    public func suspend() {
        isActive = false
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling(immediately: Bool) {
        guard !isPreview else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var first = immediately
            while !Task.isCancelled {
                guard let self else { return }
                if first {
                    await self.refresh()
                } else {
                    first = true
                }
                let interval = self.isPopoverVisible ? Self.visibleInterval : Self.backgroundInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    // MARK: Setup

    /// Saves a new token and connects to the first air conditioner on the account.
    public func connect(token: String) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.providerKind = .thinQ
        settings.deviceID = nil
        settings.token = token
        refreshConfigurationState()
        guard settings.token == token else {
            connection = .needsSetup
            showMessage("Couldn't save the token in the keychain")
            return
        }
        connection = .loading
        while isRefreshing { await sleep(Self.switchPollInterval) }
        forgetDevice()
        await refresh()
        if isActive { startPolling(immediately: false) }
    }

    /// Makes another air conditioner on the account the active one and reads its state.
    ///
    /// Everything tied to the previous unit is dropped on purpose: commands still waiting to be sent and
    /// optimistic overrides would otherwise be applied to (or shown for) the wrong device.
    public func selectDevice(id: String) async {
        guard id != device?.id, let chosen = devices.first(where: { $0.id == id }) else { return }
        debounceTask?.cancel()
        refreshSoonTask?.cancel()
        queue = []
        overrides = [:]
        serverStatus = nil
        deviceCapabilities = .fallback
        capabilitiesLoaded = false
        device = chosen
        if chosen.provider == .thinQ { settings.deviceID = chosen.id }
        connection = .loading
        while isRefreshing { await sleep(Self.switchPollInterval) }
        await refresh()
        if isActive { startPolling(immediately: false) }
    }

    public func selectProvider(_ kind: ACProviderKind) async {
        guard providerKind != kind else { return }
        settings.providerKind = kind
        refreshConfigurationState()
        debounceTask?.cancel()
        refreshSoonTask?.cancel()
        queue = []
        overrides = [:]
        connection = .loading
        while isRefreshing { await sleep(Self.switchPollInterval) }
        forgetDevice()
        await refresh()
        if isActive { startPolling(immediately: false) }
    }

    public func connectDaikin(address: String, key: String) async {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = key.isEmpty ? (settings.daikinKey ?? "") : key
        guard AppSettings.isValidDaikinAddress(address), [16, 24, 32].contains(Data(effectiveKey.utf8).count) else {
            connection = .needsSetup
            showMessage("Enter a valid local IP address and an integration key of 16, 24 or 32 bytes")
            return
        }
        settings.daikinAddress = address
        settings.daikinKey = effectiveKey
        guard settings.daikinKey == effectiveKey else {
            connection = .needsSetup
            showMessage("Couldn't save the integration key in the Keychain")
            return
        }
        settings.providerKind = .daikin
        refreshConfigurationState()
        connection = .loading
        while isRefreshing { await sleep(Self.switchPollInterval) }
        forgetDevice()
        await refresh()
        if isActive { startPolling(immediately: false) }
    }

    public func signOut() {
        if settings.providerKind == .thinQ {
            settings.token = nil
            settings.deviceID = nil
        } else {
            settings.daikinKey = nil
            settings.daikinAddress = nil
            settings.daikinName = nil
        }
        refreshConfigurationState()
        forgetDevice()
        queue = []
        connection = .needsSetup
    }

    private func forgetDevice() {
        deviceCapabilities = providerKind == .daikin ? DaikinClient.localCapabilities : .fallback
        device = nil
        devices = []
        serverStatus = nil
        overrides = [:]
        capabilitiesLoaded = false
    }

    // MARK: Refresh

    public func refresh() async {
        guard !isPreview, !isRefreshing else { return }
        guard hasToken else {
            connection = .needsSetup
            return
        }
        let client: any ACProvider
        do { client = try provider() } catch {
            connection = .needsSetup
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        if serverStatus == nil { connection = .loading }

        do {
            let status = try await retryingTransient {
                let deviceID = try await resolveDevice(client)
                var capabilities: ACCapabilities?
                if !capabilitiesLoaded {
                    capabilities = try await client.capabilities(deviceID: deviceID)
                }
                let status = try await client.status(deviceID: deviceID)
                guard device?.id == deviceID else { throw CancellationError() }
                if let capabilities {
                    deviceCapabilities = capabilities
                    capabilitiesLoaded = true
                }
                return status
            }
            serverStatus = status
            pruneOverrides()
            noteSuccess()
            connection = status.hasError ? .deviceError : .connected
        } catch {
            handle(error)
        }
    }

    /// Runs a read, trying again after a short wait when it fails in a way that may pass on its own.
    private func retryingTransient<T>(_ operation: () async throws -> T) async throws -> T {
        var delays = Self.readRetryDelays[...]
        while true {
            do {
                return try await operation()
            } catch let error as ThinQError where error.isTransient && !delays.isEmpty {
                await sleep(delays.removeFirst())
                if Task.isCancelled { throw CancellationError() }
            }
        }
    }

    private func noteSuccess() {
        failureStreak = 0
        isReconnecting = false
    }

    private func provider() throws -> any ACProvider {
        if let makeProvider { return try makeProvider(settings) }
        switch settings.providerKind {
        case .thinQ:
            guard let token = settings.token, !token.isEmpty else { throw DaikinClientError.invalidState }
            return makeClient(token, settings.clientID)
        case .daikin:
            guard let address = settings.daikinAddress, AppSettings.isValidDaikinAddress(address),
                  let key = settings.daikinKey, !key.isEmpty else { throw DaikinClientError.invalidKey }
            return try DaikinClient(address: address, key: key, displayName: settings.daikinName)
        }
    }

    private func resolveDevice(_ client: any ACProvider) async throws -> String {
        if let device, device.provider == settings.providerKind, device.id == settings.deviceID { return device.id }
        let devices = try await client.devices().filter(\.isAirConditioner)
        let preferred = settings.providerKind == .thinQ ? devices.first(where: { $0.id == settings.deviceID }) : nil
        guard let chosen = preferred ?? devices.first else {
            throw ThinQError.api(code: "", message: "No air conditioner found on this LG account")
        }
        self.devices = devices
        device = chosen
        if chosen.provider == .thinQ { settings.deviceID = chosen.id }
        capabilitiesLoaded = false
        return chosen.id
    }

    /// Drops overrides the server has confirmed or that have expired.
    private func pruneOverrides() {
        guard let serverStatus else { return }
        let date = now()
        overrides = overrides.filter { _, override in
            override.expires > date && serverStatus.applying(override.command) != serverStatus
        }
    }

    private func scheduleRefresh(after delay: Duration) {
        guard !isPreview else { return }
        refreshSoonTask?.cancel()
        refreshSoonTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Reads the state after each delay, stopping early once the target temperature differs from `target`.
    private func scheduleRefreshes(after delays: [Duration], untilTargetChangesFrom target: Double?) {
        guard !isPreview else { return }
        refreshSoonTask?.cancel()
        refreshSoonTask = Task { [weak self] in
            for delay in delays {
                guard let self else { return }
                await self.sleep(delay)
                guard !Task.isCancelled else { return }
                await self.refresh()
                if let target, let now = self.serverStatus?.targetTemperature, now != target { return }
            }
        }
    }

    // MARK: Commands

    public func perform(_ command: ACCommand) {
        guard let current = status else { return }
        // Re-sending the current value is wasteful and, for power, rejected by the API.
        if current.applying(command) == current, !queue.contains(where: { $0.field == command.field }) {
            return
        }
        if command.field == .target { debounceTask?.cancel() }
        overrides[command.field] = Override(command: command, expires: now().addingTimeInterval(Self.overrideLifetime))
        enqueue(command)
    }

    /// Updates the target right away and sends it once the value settles (used by the −/+ buttons).
    public func setTargetTemperature(_ value: Double, debounced: Bool) {
        let command = ACCommand.targetTemperature(capabilities.snap(value))
        guard debounced else {
            perform(command)
            return
        }
        overrides[.target] = Override(command: command, expires: now().addingTimeInterval(Self.overrideLifetime + 1))
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stepDebounce)
            guard !Task.isCancelled, let self else { return }
            self.overrides[.target]?.expires = self.now().addingTimeInterval(Self.overrideLifetime)
            self.enqueue(command)
        }
    }

    private func enqueue(_ command: ACCommand) {
        if let index = queue.firstIndex(where: { $0.field == command.field }) {
            queue[index] = command
        } else {
            queue.append(command)
        }
        guard worker == nil else { return }
        isSending = true
        worker = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                await self.send(next)
                if !self.queue.isEmpty { await self.sleep(Self.minimumSendGap) }
            }
            self?.worker = nil
            self?.isSending = false
        }
    }

    private func send(_ command: ACCommand) async {
        guard !isPreview else { return }
        guard hasToken, let deviceID = device?.id, let client = try? provider() else { return }
        var retried = false
        while true {
            do {
                try await client.send(command, deviceID: deviceID)
                noteSuccess()
                keepOverrideAlive(for: command)
                if command.field == .eco {
                    scheduleRefreshes(after: Self.ecoFollowUpDelays, untilTargetChangesFrom: serverStatus?.targetTemperature)
                } else {
                    scheduleRefresh(after: Self.refreshAfterSend)
                }
                return
            } catch let error as ThinQError where !retried && (error.isTransient || error == .deviceOffline) {
                retried = true
                keepOverrideAlive(for: command)
                await sleep(error == .rateLimited ? Self.rateLimitRetryDelay : Self.commandRetryDelay)
                // A newer value for the same field is already waiting, so this one is stale.
                if queue.contains(where: { $0.field == command.field }) { return }
                // A timeout doesn't say whether the unit got the command; don't send it twice.
                if case .network = error,
                   let current = try? await client.status(deviceID: deviceID),
                   current.applying(command) == current {
                    noteSuccess()
                    scheduleRefresh(after: Self.refreshAfterSend)
                    return
                }
            } catch {
                if overrides[command.field]?.command == command {
                    overrides[command.field] = nil
                }
                handle(error)
                scheduleRefresh(after: Self.refreshAfterFailure)
                return
            }
        }
    }

    private func keepOverrideAlive(for command: ACCommand) {
        if overrides[command.field]?.command == command {
            overrides[command.field]?.expires = now().addingTimeInterval(Self.overrideLifetime)
        }
    }

    private func handle(_ error: any Error) {
        if error is CancellationError { return }
        let error = error as? ThinQError ?? .network(error.localizedDescription)
        switch error {
        case .unauthorized:
            connection = .unauthorized
        case .deviceOffline:
            connection = .offline(error.message)
        case .network, .serverError:
            // One failed request is a hiccup: keep showing the last state until it keeps failing.
            failureStreak += 1
            if serverStatus != nil, failureStreak < Self.failuresBeforeOffline {
                isReconnecting = true
            } else {
                isReconnecting = false
                connection = .offline(error.message)
            }
        case .rateLimited, .rejected, .api, .invalidResponse:
            if serverStatus == nil { connection = .offline(error.message) }
            showMessage(error.message)
        }
    }

    private func showMessage(_ message: String) {
        transientMessage = message
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: Self.messageDuration)
            guard !Task.isCancelled else { return }
            self?.transientMessage = nil
        }
    }
}
