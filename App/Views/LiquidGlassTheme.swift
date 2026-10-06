import SwiftUI

struct SlskBackdrop: View {
    @Environment(\.slskAccent) private var accent
    @Environment(\.slskBackdropColor) private var backdropColor
    @Environment(\.slskBackdropIntensity) private var intensity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            if intensity > 0 && !reduceTransparency && contrast != .increased {
                LinearGradient(
                    colors: [accent.opacity(0.16 * intensity), .clear, backdropColor.opacity(0.10 * intensity)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SlskGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.slskUseGlass) private var useGlass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if !useGlass || reduceTransparency || contrast == .increased {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

private struct SlskGlassButton: ViewModifier {
    let prominent: Bool
    @Environment(\.slskUseGlass) private var useGlass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), useGlass, !reduceTransparency, contrast != .increased {
            if prominent {
                content.buttonStyle(.glassProminent).controlSize(.large)
            } else {
                content.buttonStyle(.glass).controlSize(.large)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).controlSize(.large)
        }
    }
}

extension View {
    func slskScreen() -> some View {
        scrollContentBackground(.hidden).background { SlskBackdrop() }
    }

    func slskGlassSurface(cornerRadius: CGFloat = 24) -> some View {
        modifier(SlskGlassSurface(cornerRadius: cornerRadius))
    }

    func slskGlassButton(prominent: Bool = false) -> some View {
        modifier(SlskGlassButton(prominent: prominent))
    }
}
