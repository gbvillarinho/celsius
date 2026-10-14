import CelsiusCore
import SwiftUI

enum Theme {
    static let popoverWidth: CGFloat = 320
    static let cardFill = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.07)
    static let cardRadius: CGFloat = 14
    static let secondaryText = Color.white.opacity(0.55)
    static let disabledOpacity = 0.4

    /// The accent color chosen in System Settings (or an ancestor's `.tint`), like native controls use.
    static let accent = Color.accentColor
    static let warning = Color.orange

    /// Accent for the power button, slider, airflow and glow, per job mode. Cooling, the default,
    /// follows the system accent; the other modes keep their own hue so they stay recognizable.
    static func modeColor(_ mode: String?) -> Color {
        switch mode {
        case ACMode.cool: accent
        case ACMode.dry: Color(red: 0.49, green: 0.88, blue: 0.76)
        case ACMode.auto: Color(red: 0.73, green: 0.69, blue: 1.00)
        case ACMode.heat: Color(red: 1.00, green: 0.66, blue: 0.40)
        default: Color(white: 0.92)
        }
    }
}

extension View {
    /// The translucent rounded card used for tiles and settings sections.
    func card(cornerRadius: CGFloat = Theme.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(Theme.cardFill))
            .overlay(shape.strokeBorder(Theme.cardStroke))
    }
}

/// Display names and icons for API values.
enum Labels {
    static func mode(_ mode: String?) -> String {
        switch mode {
        case ACMode.cool: "Cool"
        case ACMode.dry: "Dry"
        case ACMode.fan: "Fan"
        case ACMode.auto: "Auto"
        case ACMode.heat: "Heat"
        case let other?: other.capitalized
        case nil: "—"
        }
    }

    static func modeIcon(_ mode: String?) -> String {
        switch mode {
        case ACMode.cool: "snowflake"
        case ACMode.dry: "drop"
        case ACMode.fan: "fan"
        case ACMode.auto: "a.circle"
        case ACMode.heat: "sun.max"
        default: "snowflake"
        }
    }

    static func fan(_ speed: String?) -> String {
        switch speed {
        case "LOW": "Low"
        case "MID": "Medium"
        case "HIGH": "High"
        case "AUTO": "Auto"
        case let other?: other.capitalized
        case nil: "—"
        }
    }

    /// What the unit is doing, e.g. "Cooling to 18 °C".
    static func activity(_ status: ACStatus?, target: Double?) -> String {
        guard let status else { return "—" }
        guard status.isOn else { return "Off" }
        let goal = "\(temperature(target)) °C"
        return switch status.mode {
        case ACMode.cool: "Cooling to \(goal)"
        case ACMode.heat: "Heating to \(goal)"
        case ACMode.auto: "Auto · \(goal)"
        case ACMode.dry: "Dehumidifying"
        case ACMode.fan: "Fan only"
        default: mode(status.mode)
        }
    }

    /// The unit's name, with the model added when two units share the same name.
    static func deviceName(_ device: ThinQDevice, among devices: [ThinQDevice]) -> String {
        let name = device.displayName
        let twins = devices.filter { $0.displayName == name }
        guard twins.count > 1, let model = device.deviceInfo.modelName else { return name }
        return "\(name) (\(model))"
    }

    static func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
