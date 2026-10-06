import SwiftUI
import UIKit

enum SlskThemeColors {
    static let accentKey = "appearance.accentColor"
    static let backdropKey = "appearance.backdropColor"
    static let chatKey = "appearance.chatColor"

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

enum SlskColorMode: String, CaseIterable {
    case system, light, dark
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum SlskFontStyle: String, CaseIterable {
    case standard, rounded, serif, monospaced
    var title: String { rawValue.capitalized }
    var design: Font.Design {
        switch self {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

enum SlskRowDensity: String, CaseIterable {
    case compact, standard, relaxed
    var title: String { rawValue.capitalized }
    var padding: CGFloat {
        switch self {
        case .compact: 0
        case .standard: 2
        case .relaxed: 6
        }
    }
    var spacing: CGFloat {
        switch self {
        case .compact: 2
        case .standard: 4
        case .relaxed: 8
        }
    }
}

private struct SlskDensityKey: EnvironmentKey {
    static let defaultValue = SlskRowDensity.standard
}

private struct SlskGlassKey: EnvironmentKey {
    static let defaultValue = true
}

private struct SlskBackdropIntensityKey: EnvironmentKey {
    static let defaultValue = 1.0
}

struct SlskColorPreset: Identifiable {
    let name: String
    let accent: String
    let backdrop: String
    var id: String { name }
    static let all: [SlskColorPreset] = [
        .init(name: "Original", accent: "", backdrop: ""),
        .init(name: "Ocean", accent: "0077B6", backdrop: "00B4D8"),
        .init(name: "Lilac", accent: "8250C4", backdrop: "B66CDE"),
        .init(name: "Rose", accent: "C43D78", backdrop: "E28B65"),
        .init(name: "Forest", accent: "287D56", backdrop: "8CAF50"),
        .init(name: "Sunset", accent: "CF542C", backdrop: "9855B5")
    ]
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

    var slskRowDensity: SlskRowDensity {
        get { self[SlskDensityKey.self] }
        set { self[SlskDensityKey.self] = newValue }
    }

    var slskUseGlass: Bool {
        get { self[SlskGlassKey.self] }
        set { self[SlskGlassKey.self] = newValue }
    }

    var slskBackdropIntensity: Double {
        get { self[SlskBackdropIntensityKey.self] }
        set { self[SlskBackdropIntensityKey.self] = newValue }
    }
}

struct SlskTheme: ViewModifier {
    @AppStorage(SlskThemeColors.accentKey) private var accentHex = ""
    @AppStorage(SlskThemeColors.backdropKey) private var backdropHex = ""
    @AppStorage("appearance.colorMode") private var colorMode = "system"
    @AppStorage("appearance.fontStyle") private var fontStyle = "standard"
    @AppStorage("appearance.rowDensity") private var rowDensity = "standard"
    @AppStorage("appearance.useGlass") private var useGlass = true
    @AppStorage("appearance.backdropIntensity") private var intensity = 1.0

    func body(content: Content) -> some View {
        let accent = SlskThemeColors.color(from: accentHex, fallback: .orange)
        let backdrop = SlskThemeColors.color(from: backdropHex, fallback: .teal)
        let density = SlskRowDensity(rawValue: rowDensity) ?? .standard
        content
            .tint(accent)
            .preferredColorScheme((SlskColorMode(rawValue: colorMode) ?? .system).scheme)
            .modifier(SlskFontDesign(style: SlskFontStyle(rawValue: fontStyle) ?? .standard))
            .environment(\.slskAccent, accent)
            .environment(\.slskBackdropColor, backdrop)
            .environment(\.slskRowDensity, density)
            .environment(\.slskUseGlass, useGlass)
            .environment(\.slskBackdropIntensity, min(max(intensity, 0), 2))
            .environment(\.defaultMinListRowHeight, density == .relaxed ? 52 : 44)
    }
}

private struct SlskFontDesign: ViewModifier {
    let style: SlskFontStyle

    func body(content: Content) -> some View {
        if #available(iOS 16.1, *) {
            content.fontDesign(style.design)
        } else {
            content
        }
    }
}

struct ThemeSettingsSection: View {
    var body: some View {
        Section("Appearance") {
            NavigationLink {
                AppearanceSettingsView()
            } label: {
                Label("Customize appearance", systemImage: "paintpalette")
            }
        }
    }
}

struct AppearanceSettingsView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(SlskThemeColors.accentKey) private var accentHex = ""
    @AppStorage(SlskThemeColors.backdropKey) private var backdropHex = ""
    @AppStorage(SlskThemeColors.chatKey) private var chatHex = ""
    @AppStorage("appearance.colorMode") private var colorMode = "system"
    @AppStorage("appearance.fontStyle") private var fontStyle = "standard"
    @AppStorage("appearance.rowDensity") private var rowDensity = "standard"
    @AppStorage("appearance.useGlass") private var useGlass = true
    @AppStorage("appearance.backdropIntensity") private var intensity = 1.0
    @AppStorage("appearance.chatCornerRadius") private var chatCornerRadius = 14.0
    @AppStorage("appearance.showChatTimestamps") private var showTimestamps = true
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Preview") {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Your Slsk", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(.tint)
                    Text("Search, share, and make it yours.")
                        .font(.subheadline)
                    HStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 4) {
                            if showTimestamps {
                                Text("12:34").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text("This is your chat bubble").font(.subheadline)
                        }
                        .padding(10)
                        .background(!reduceTransparency && contrast != .increased
                                    ? SlskThemeColors.color(from: chatHex, fallback: accent).opacity(0.25)
                                    : Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: bubbleRadius))
                    }
                    Button("Glass control preview") {}
                        .slskGlassButton(prominent: true)
                        .allowsHitTesting(false)
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(SlskColorPreset.all) { preset in
                    Button {
                        accentHex = preset.accent
                        backdropHex = preset.backdrop
                        chatHex = ""
                    } label: {
                        HStack {
                            Circle()
                                .fill(SlskThemeColors.color(from: preset.accent, fallback: .orange))
                                .frame(width: 20, height: 20)
                            Circle()
                                .fill(SlskThemeColors.color(from: preset.backdrop, fallback: .teal))
                                .frame(width: 20, height: 20)
                            Text(preset.name).foregroundStyle(.primary)
                            Spacer()
                            if accentHex == preset.accent && backdropHex == preset.backdrop && chatHex.isEmpty {
                                Image(systemName: "checkmark").accessibilityLabel("Selected")
                            }
                        }
                    }
                }
            } header: {
                Text("Color presets")
            } footer: {
                Text("Presets change only colors. Fine-tune them with the pickers below.")
            }

            Section("Colors") {
                ColorPicker("Accent color",
                            selection: SlskThemeColors.selection($accentHex, fallback: .orange),
                            supportsOpacity: false)
                ColorPicker("Backdrop color",
                            selection: SlskThemeColors.selection($backdropHex, fallback: .teal),
                            supportsOpacity: false)
                ColorPicker("Outgoing chat color",
                            selection: SlskThemeColors.selection($chatHex, fallback: accent),
                            supportsOpacity: false)
                Button("Match chat color to accent") { chatHex = "" }
                    .disabled(chatHex.isEmpty)
            }

            Section("Style") {
                Picker("Appearance", selection: $colorMode) {
                    ForEach(SlskColorMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Picker("Font style", selection: $fontStyle) {
                    ForEach(SlskFontStyle.allCases, id: \.rawValue) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                Picker("Row spacing", selection: $rowDensity) {
                    ForEach(SlskRowDensity.allCases, id: \.rawValue) { density in
                        Text(density.title).tag(density.rawValue)
                    }
                }
                Toggle("Glass controls", isOn: $useGlass)
                VStack(alignment: .leading) {
                    Text("Backdrop intensity: \(Int(intensity * 100))%")
                    Slider(value: $intensity, in: 0...2, step: 0.05) {
                        Text("Backdrop intensity")
                    }
                }
            }

            Section("Chat") {
                Toggle("Show timestamps", isOn: $showTimestamps)
                VStack(alignment: .leading) {
                    Text("Bubble roundness: \(Int(chatCornerRadius))")
                    Slider(value: $chatCornerRadius, in: 0...28, step: 1) {
                        Text("Bubble roundness")
                    }
                }
            }

            Section {
                Button("Reset all appearance settings", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Changes preview live and are saved automatically. Dynamic Type, status colors, and accessibility contrast/transparency settings remain respected. Glass is applied to controls, not file rows or messages.")
            }
        }
        .slskScreen()
        .navigationTitle("Appearance")
        .confirmationDialog("Reset appearance to the original theme?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset appearance", role: .destructive) { resetAppearance() }
        }
    }

    private var accent: Color { SlskThemeColors.color(from: accentHex, fallback: .orange) }
    private var bubbleRadius: CGFloat { CGFloat(min(max(chatCornerRadius, 0), 28)) }

    private func resetAppearance() {
        accentHex = ""
        backdropHex = ""
        chatHex = ""
        colorMode = "system"
        fontStyle = "standard"
        rowDensity = "standard"
        useGlass = true
        intensity = 1
        chatCornerRadius = 14
        showTimestamps = true
    }
}
