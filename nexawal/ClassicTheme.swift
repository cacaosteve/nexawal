//
//  ClassicTheme.swift
//  nexawal
//
//  Neon terminal palette (used when Classic UI setting is OFF).
//  Classic UI setting ON uses the standard non-neon system look instead.
//

import SwiftUI

struct ClassicPalette {
    let background: Color
    let panel: Color
    let border: Color
    let accent: Color
    let primaryText: Color
    let secondaryText: Color
    let success: Color
    let danger: Color
    let progress: Color
    let cta: Color
    let ctaText: Color

    static func resolve(colorScheme: ColorScheme) -> ClassicPalette {
        switch colorScheme {
        case .light:
            return ClassicPalette(
                background: Color(red: 0.949, green: 0.957, blue: 0.949), // #F2F4F2
                panel: Color(red: 1.0, green: 1.0, blue: 1.0),
                border: Color(red: 0.039, green: 0.478, blue: 0.184), // #0A7A2F
                accent: Color(red: 0.039, green: 0.478, blue: 0.184),
                primaryText: Color(red: 0.05, green: 0.18, blue: 0.08),
                secondaryText: Color(red: 0.25, green: 0.40, blue: 0.28),
                success: Color(red: 0.039, green: 0.478, blue: 0.184),
                danger: Color(red: 0.70, green: 0.12, blue: 0.12),
                progress: Color(red: 0.039, green: 0.478, blue: 0.184),
                cta: Color(red: 0.039, green: 0.478, blue: 0.184),
                ctaText: Color.white
            )
        default:
            return ClassicPalette(
                background: Color(red: 0.0, green: 0.0, blue: 0.0),
                panel: Color(red: 0.039, green: 0.059, blue: 0.039), // #0A0F0A
                border: Color(red: 0.0, green: 0.902, blue: 0.463), // #00E676
                accent: Color(red: 0.224, green: 1.0, blue: 0.078), // #39FF14
                primaryText: Color(red: 0.224, green: 1.0, blue: 0.078),
                secondaryText: Color(red: 0.35, green: 0.75, blue: 0.40),
                success: Color(red: 0.224, green: 1.0, blue: 0.078),
                danger: Color(red: 1.0, green: 0.35, blue: 0.35),
                progress: Color(red: 0.0, green: 0.902, blue: 0.463),
                cta: Color(red: 0.224, green: 1.0, blue: 0.078), // #39FF14 neon green (not cyan)
                ctaText: Color(red: 0.0, green: 0.102, blue: 0.071) // #001A12
            )
        }
    }
}

private struct ClassicUIEnabledKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct ClassicPaletteKey: EnvironmentKey {
    static let defaultValue: ClassicPalette? = nil
}

extension EnvironmentValues {
    var classicUI: Bool {
        get { self[ClassicUIEnabledKey.self] }
        set { self[ClassicUIEnabledKey.self] = newValue }
    }

    var classicPalette: ClassicPalette? {
        get { self[ClassicPaletteKey.self] }
        set { self[ClassicPaletteKey.self] = newValue }
    }
}

extension View {
    func classicTheme(enabled: Bool, colorScheme: ColorScheme) -> some View {
        environment(\.classicUI, enabled)
            .environment(\.classicPalette, enabled ? ClassicPalette.resolve(colorScheme: colorScheme) : nil)
    }

    /// Apply neon Form chrome when classicUI (neon mode) is active.
    @ViewBuilder
    func neonFormChrome(classicUI: Bool, palette: ClassicPalette?) -> some View {
        if classicUI, let palette {
            self
                .scrollContentBackground(.hidden)
                .background(palette.background.ignoresSafeArea())
                .tint(palette.accent)
                .accentColor(palette.accent)
                .foregroundStyle(palette.primaryText)
                .listRowSeparatorTint(palette.border.opacity(0.45))
                .toolbarBackground(palette.background, for: .navigationBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func neonCTAStyle(classicUI: Bool, palette: ClassicPalette?) -> some View {
        if classicUI, let palette {
            self
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding()
                .background(palette.cta)
                .foregroundColor(palette.ctaText)
                .clipShape(Capsule())
        } else {
            self
        }
    }

    @ViewBuilder
    func neonSecondaryButtonStyle(classicUI: Bool, palette: ClassicPalette?) -> some View {
        if classicUI, let palette {
            self
                .font(.system(.body, design: .monospaced).weight(.medium))
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(red: 0.07, green: 0.09, blue: 0.07))
                .foregroundColor(palette.accent)
                .overlay(Capsule().stroke(palette.border, lineWidth: 1))
                .clipShape(Capsule())
        } else {
            self
        }
    }
}

struct NeonSectionHeader: View {
    let title: String
    @Environment(\.classicUI) private var classicUI
    @Environment(\.classicPalette) private var classicPalette

    var body: some View {
        Text(classicUI ? title.uppercased() : title)
            .font(classicUI ? .system(.caption, design: .monospaced).weight(.semibold) : .caption)
            .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
    }
}

/// Form Toggle whose label color is not overridden by system list styling.
/// Neon mode uses a custom switch (matches Android); Classic UI uses the system control.
struct NeonToggle: View {
    let title: String
    @Binding var isOn: Bool
    var disabled: Bool = false
    @Environment(\.classicUI) private var classicUI
    @Environment(\.classicPalette) private var classicPalette

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(classicUI ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(classicPalette?.primaryText ?? .primary)
        }
        .toggleStyle(NeonSwitchToggleStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// Custom switch chrome aligned with Android `nexaSwitchColors`:
/// on = neon track + dark thumb; off = separator track + muted-green thumb.
struct NeonSwitchToggleStyle: ToggleStyle {
    @Environment(\.classicUI) private var classicUI
    @Environment(\.classicPalette) private var classicPalette

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            if classicUI, let palette = classicPalette {
                NeonThemeSwitch(isOn: configuration.isOn, palette: palette) {
                    configuration.isOn.toggle()
                }
            } else {
                Toggle("", isOn: configuration.$isOn)
                    .labelsHidden()
                    .tint(.accentColor)
            }
        }
    }
}

private struct NeonThemeSwitch: View {
    let isOn: Bool
    let palette: ClassicPalette
    let action: () -> Void

    var body: some View {
        // Match Material3 switch proportions (~52×32).
        let width: CGFloat = 52
        let height: CGFloat = 32
        let thumb: CGFloat = 24

        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? palette.accent : palette.panel)
                    .overlay(
                        Capsule()
                            .stroke(
                                isOn ? palette.border : palette.secondaryText.opacity(0.45),
                                lineWidth: 1.5
                            )
                    )
                    .frame(width: width, height: height)

                Circle()
                    .fill(isOn ? palette.ctaText : palette.secondaryText)
                    .overlay(
                        Circle()
                            .stroke(palette.border.opacity(isOn ? 0.2 : 0.35), lineWidth: 0.5)
                    )
                    .frame(width: thumb, height: thumb)
                    .padding(4)
                    .shadow(
                        color: isOn ? palette.accent.opacity(0.55) : .clear,
                        radius: isOn ? 5 : 0,
                        y: 0
                    )
            }
            .animation(.easeInOut(duration: 0.18), value: isOn)
        }
        .buttonStyle(.plain)
        .frame(width: width, height: max(height, 44), alignment: .center) // HIG-friendly hit target
        .accessibilityLabel("Toggle")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

struct NeonFormLabel: View {
    let text: String
    @Environment(\.classicUI) private var classicUI
    @Environment(\.classicPalette) private var classicPalette

    var body: some View {
        Text(text)
            .font(classicUI ? .system(.body, design: .monospaced) : .body)
            .foregroundStyle(classicPalette?.primaryText ?? .primary)
    }
}

/// Disclosure with a neon-colored chevron (Form DisclosureGroup keeps a white system triangle).
struct NeonDisclosureGroup<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    @Environment(\.classicUI) private var classicUI
    @Environment(\.classicPalette) private var classicPalette

    var body: some View {
        if classicUI, let palette = classicPalette {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(title)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(palette.primaryText)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.accent)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    content()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        } else {
            DisclosureGroup(title, isExpanded: $isExpanded) {
                content()
            }
        }
    }
}
