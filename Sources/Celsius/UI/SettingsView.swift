import AppKit
import CelsiusCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var store: ACStore
    var canGoBack: Bool
    var onBack: () -> Void

    @State private var token = ""
    @State private var daikinAddress = ""
    @State private var daikinKey = ""
    @State private var daikinName = ""
    @State private var isConnecting = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private static let tokenPortal = URL(string: "https://connect-pat.lgthinq.com")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if canGoBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
            }

            providerPicker

            if store.providerKind == .thinQ {
                section("LG ThinQ") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let device = store.device, store.hasToken {
                            HStack(spacing: 10) {
                                Image(systemName: "air.conditioner.horizontal")
                                    .font(.system(size: 16))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(device.deviceInfo.modelName ?? "")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.secondaryText)
                                }
                                Spacer()
                                FooterStatus(store: store)
                            }
                            if store.devices.count > 1 {
                                devicePicker
                            }
                        } else {
                            Text("Paste a Personal Access Token from your LG account to connect to your air conditioner.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 8) {
                            SecureField(store.hasToken ? "Replace token" : "thinqpat_…", text: $token)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
                                .onSubmit(connect)
                            Button(action: pasteToken) {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .help("Paste the token from the clipboard")
                            .accessibilityLabel("Paste token")
                            .disabled(isConnecting)
                            Button(action: connect) {
                                if isConnecting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Connect")
                                }
                            }
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                        }

                        if case .unauthorized = store.connection {
                            Label("LG rejected this token. Create a new one and paste it here.", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.warning)
                        }

                        Link(destination: Self.tokenPortal) {
                            Label("Create a token at connect-pat.lgthinq.com", systemImage: "arrow.up.right.square")
                                .font(.system(size: 12))
                        }
                            .foregroundStyle(Theme.accent)
                    }
                }
            } else {
                section("Daikin local connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connect directly to your Daikin on the same Wi-Fi network. Celsius stores the integration key in Keychain and does not use Daikin cloud access.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if store.hasToken {
                            TextField("Device name", text: $daikinName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .onSubmit { store.setDaikinName(daikinName) }
                                .onChange(of: daikinName) { _, value in store.setDaikinName(value) }
                        }
                        TextField("Device IP address", text: $daikinAddress)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        SecureField("Integration key", text: $daikinKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        if store.hasToken {
                            Label("Integration key saved in Keychain", systemImage: "checkmark.shield")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Button(action: connectDaikin) {
                            if isConnecting { ProgressView().controlSize(.small) }
                            else { Text("Connect Daikin") }
                        }
                        .disabled(daikinAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (daikinKey.isEmpty && !store.hasToken) || isConnecting)
                        if case let .offline(message) = store.connection {
                            Label(message, systemImage: "wifi.slash")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.warning)
                        }
                    }
                }
                .onAppear {
                    daikinAddress = store.configuredDaikinAddress ?? daikinAddress
                    daikinName = store.configuredDaikinName ?? ""
                }
            }

            if store.hasToken {
                section("Temperature") {
                    temperatureLimits
                }
            }

            if let firmwareVersion = store.status?.firmwareVersion {
                section("Device information") {
                    HStack {
                        Text("Firmware")
                        Spacer()
                        Text(firmwareVersion)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .font(.system(size: 12))
                }
            }

            section("General") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 13))
                        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                    if let loginError {
                        Text(loginError)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                    }
                    versionRow
                }
            }

            HStack {
                if store.hasToken {
                    Button(store.providerKind == .daikin ? "Disconnect" : "Sign out") {
                        store.signOut()
                    }
                }
                Spacer()
                Button("Quit Celsius") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .font(.system(size: 12))
        }
    }

    private var providerPicker: some View {
        Picker("Provider", selection: Binding(
            get: { store.providerKind },
            set: { kind in Task<Void, Never> { await store.selectProvider(kind) } }
        )) {
            Text("LG ThinQ").tag(ACProviderKind.thinQ)
            Text("Daikin").tag(ACProviderKind.daikin)
        }
        .pickerStyle(.segmented)
    }

    /// A pop-up to choose which air conditioner the app controls.
    private var devicePicker: some View {
        HStack {
            Text("Unit")
                .font(.system(size: 13))
            Spacer()
            PopUpButton(
                options: store.devices.map { (Labels.deviceName($0, among: store.devices), $0.id) },
                selection: Binding(
                    get: { store.device?.id ?? "" },
                    set: { id in Task<Void, Never> { await store.selectDevice(id: id) } }
                )
            )
            .frame(width: Self.unitPopUpWidth)
            .accessibilityLabel("Unit")
        }
    }

    private static let unitPopUpWidth: CGFloat = 140

    /// Minimum and maximum steppers bounded by what the device accepts, plus half degrees when it has them.
    private var temperatureLimits: some View {
        let device = store.deviceCapabilities
        let limits = store.temperatureLimits
        return VStack(alignment: .leading, spacing: 8) {
            limitRow("Minimum", value: $store.temperatureLimits.minimum, in: device.minTemperature, limits.maximum - 1)
            limitRow("Maximum", value: $store.temperatureLimits.maximum, in: limits.minimum + 1, device.maxTemperature)
            if device.temperatureStep < 1 {
                Toggle("Half degrees", isOn: $store.temperatureLimits.halfDegrees)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .font(.system(size: 13))
    }

    /// Saved limits can fall outside a different device's range, so the bounds never invert.
    private func limitRow(_ title: String, value: Binding<Double>, in lower: Double, _ upper: Double) -> some View {
        let range = lower...max(lower, upper)
        return HStack {
            Text(title)
            Spacer()
            Text("\(Labels.temperature(value.wrappedValue))°C")
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
            Stepper(title, value: value, in: range, step: 1)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.secondaryText)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }

    /// The running version, with a link to the new release when there is one.
    private var versionRow: some View {
        HStack(spacing: 8) {
            Text("Version \(Self.currentVersion)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            if let update = store.availableUpdate {
                Link(destination: update.url) {
                    Label("Update to \(update.version)", systemImage: "arrow.down.circle")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.accent)
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private func connectDaikin() {
        guard !isConnecting else { return }
        isConnecting = true
        Task {
            await store.connectDaikin(address: daikinAddress, key: daikinKey)
            daikinKey = ""
            isConnecting = false
        }
    }

    private func pasteToken() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        token = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connect() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isConnecting else { return }
        isConnecting = true
        Task {
            await store.connect(token: value)
            isConnecting = false
            if store.connection == .connected || store.connection == .deviceError {
                token = ""
                if canGoBack { onBack() }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
