import SwiftUI
import UIKit

enum SlskThemeColors {
    static let accentKey = "appearance.accentColor"
    static let backdropKey = "appearance.backdropColor"

    static func color(from hex: String, fallback: Color) -> Color {
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return fallback }
        return Color(.sRGB, red: Double((rgb >> 16) & 0xff) / 255,
                     green: Double((rgb >> 8) & 0xff) / 255,
                     blue: Double(rgb & 0xff) / 255, opacity: 1)
    }

    static func hex(from color: Color) -> String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              red.isFinite, green.isFinite, blue.isFinite else { return nil }
        let components = [red, green, blue].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", components[0], components[1], components[2])
    }

    static func selection(_ stored: Binding<String>, fallback: Color) -> Binding<Color> {
        Binding(
            get: { color(from: stored.wrappedValue, fallback: fallback) },
            set: { color in
                if let hex = hex(from: color) { stored.wrappedValue = hex }
            }
        )
    }
}

private struct SlskAccentKey: EnvironmentKey {
    static let defaultValue: Color = .orange
}

private struct SlskBackdropKey: EnvironmentKey {
    static let defaultValue: Color = .teal
}

extension EnvironmentValues {
    var slskAccent: Color {
        get { self[SlskAccentKey.self] }
        set { self[SlskAccentKey.self] = newValue }
    }

    var slskBackdropColor: Color {
        get { self[SlskBackdropKey.self] }
        set { self[SlskBackdropKey.self] = newValue }
    }
}

struct SlskTheme: ViewModifier {
    @AppStorage(SlskThemeColors.accentKey) private var accentHex = ""
    @AppStorage(SlskThemeColors.backdropKey) private var backdropHex = ""

    func body(content: Content) -> some View {
        let accent = SlskThemeColors.color(from: accentHex, fallback: .orange)
        let backdrop = SlskThemeColors.color(from: backdropHex, fallback: .teal)
        content
            .tint(accent)
            .environment(\.slskAccent, accent)
            .environment(\.slskBackdropColor, backdrop)
    }
}

struct ThemeSettingsSection: View {
    @AppStorage(SlskThemeColors.accentKey) private var accentHex = ""
    @AppStorage(SlskThemeColors.backdropKey) private var backdropHex = ""

    var body: some View {
        Section {
            ColorPicker("Accent color",
                        selection: SlskThemeColors.selection($accentHex, fallback: .orange),
                        supportsOpacity: false)
            ColorPicker("Backdrop color",
                        selection: SlskThemeColors.selection($backdropHex, fallback: .teal),
                        supportsOpacity: false)
            Button("Reset theme colors") {
                accentHex = ""
                backdropHex = ""
            }
            .disabled(accentHex.isEmpty && backdropHex.isEmpty)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Colors update immediately and are saved automatically. Status colors stay unchanged. Accessibility settings may hide the backdrop gradient.")
        }
    }
}
