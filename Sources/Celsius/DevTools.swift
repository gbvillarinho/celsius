import AppKit
import CelsiusCore
import SwiftUI

/// `Celsius --snapshot <dir>` renders the popover offscreen in a few fixed states, for visual checks
/// without a menu bar or network.
@MainActor
enum DevTools {
    static func renderSnapshots(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let caps = ACCapabilities(
            modes: [ACMode.fan, ACMode.dry, ACMode.auto, ACMode.cool],
            fanSpeeds: ["LOW", "MID", "HIGH", "AUTO"],
            minTemperature: 18, maxTemperature: 30, temperatureStep: 0.5,
            supportsEco: true, supportsSwing: true, supportsSleep: true
        )
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let scenarios: [(String, ACStatus?, ConnectionState)] = [
            ("cool-on", ACStatus(isOn: true, mode: ACMode.cool, currentTemperature: 26, targetTemperature: 23, fanSpeed: "AUTO", swing: false, eco: false), .connected),
            ("off", ACStatus(isOn: false, mode: ACMode.cool, currentTemperature: 26, targetTemperature: 23, fanSpeed: "AUTO", swing: false, eco: false), .connected),
            ("fan-high", ACStatus(isOn: true, mode: ACMode.fan, currentTemperature: 25, targetTemperature: 22, fanSpeed: "HIGH", swing: false, eco: false), .connected),
            ("dry-sleep", ACStatus(isOn: true, mode: ACMode.dry, currentTemperature: 24, targetTemperature: 24, fanSpeed: "LOW", swing: false, eco: false, sleepMinutesLeft: 95), .connected),
            ("auto-swing", ACStatus(isOn: true, mode: ACMode.auto, currentTemperature: 27, targetTemperature: 23.5, fanSpeed: "MID", swing: true, eco: true), .connected),
            ("offline", ACStatus(isOn: true, mode: ACMode.cool, currentTemperature: 26, targetTemperature: 18, fanSpeed: "HIGH", swing: false, eco: false), .offline("The air conditioner is offline")),
            ("setup", nil, .needsSetup),
        ]
        for (name, status, connection) in scenarios {
            let store = ACStore(previewStatus: status, capabilities: caps, connection: connection)
            let popover = PopoverView(store: store, fixedDate: date)
            render(popover, to: directory.appendingPathComponent("\(name).png"))
            renderNative(popover, to: directory.appendingPathComponent("\(name)-native.png"))
        }

        // A newer release available: the dot on the settings row, and the update link in Settings.
        let update = AppUpdate(version: "1.2.0", url: URL(string: "https://github.com/gbvillarinho/celsius/releases/latest")!)
        for (name, connection) in [("update-available", ConnectionState.connected), ("update-available-settings", .needsSetup)] {
            let status = connection == .connected ? scenarios[0].1 : nil
            let store = ACStore(previewStatus: status, capabilities: caps, connection: connection, availableUpdate: update)
            let popover = PopoverView(store: store, fixedDate: date)
            render(popover, to: directory.appendingPathComponent("\(name).png"))
            renderNative(popover, to: directory.appendingPathComponent("\(name)-native.png"))
        }

        let units = [
            ThinQDevice(deviceId: "living", deviceInfo: .init(deviceType: "DEVICE_AIR_CONDITIONER", modelName: "RAC_056905_WW", alias: "Living room")),
            ThinQDevice(deviceId: "bedroom", deviceInfo: .init(deviceType: "DEVICE_AIR_CONDITIONER", modelName: "RAC_056905_WW", alias: "Bedroom")),
        ]
        for (name, connection) in [("two-units", ConnectionState.connected), ("two-units-settings", .needsSetup)] {
            let status = connection == .connected ? scenarios[0].1 : nil
            let store = ACStore(previewStatus: status, capabilities: caps, connection: connection, devices: units)
            let popover = PopoverView(store: store, fixedDate: date)
            render(popover, to: directory.appendingPathComponent("\(name).png"))
            renderNative(popover, to: directory.appendingPathComponent("\(name)-native.png"))
        }

        // Requests are failing, but the last known state is still shown.
        let reconnecting = ACStore(previewStatus: scenarios[0].1, capabilities: caps, isReconnecting: true)
        let reconnectingPopover = PopoverView(store: reconnecting, fixedDate: date)
        render(reconnectingPopover, to: directory.appendingPathComponent("reconnecting.png"))
        renderNative(reconnectingPopover, to: directory.appendingPathComponent("reconnecting-native.png"))

        // Airflow frames over time.
        for (index, offset) in [0.0, 0.3, 0.6, 0.9].enumerated() {
            let unit = ACUnitView(
                isOn: true, mode: ACMode.cool, fanSpeed: "HIGH", swing: true, sleeping: false, target: 23,
                isVisible: true, fixedDate: date.addingTimeInterval(offset)
            )
            .padding(18)
            .frame(width: Theme.popoverWidth)
            render(unit, to: directory.appendingPathComponent("airflow-\(index).png"))
        }
        print("Snapshots written to \(directory.path)")
    }

    /// Waits for the live store to load, then renders the popover with real data
    /// (`CELSIUS_LIVE_SNAPSHOT=<file.png>`).
    static func snapshotLive(store: ACStore, to url: URL) {
        Task {
            for _ in 0..<40 where store.status == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(1))
            render(PopoverView(store: store, fixedDate: Date()), to: url)
            print("Live snapshot written to \(url.path)")
        }
    }

    /// Faithful for SwiftUI drawing (transforms, canvas), but AppKit-backed controls (switches,
    /// pop-up buttons, segmented controls, text fields) come out as placeholders.
    private static func render<V: View>(_ view: V, to url: URL) {
        let root = view
            .background(Color(white: 0.11))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Draws through an offscreen window so native controls render, at the cost of scale/3D
    /// transforms (the unit illustration lands out of place) and an inactive-window look.
    private static func renderNative<V: View>(_ view: V, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(white: 0.11)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
