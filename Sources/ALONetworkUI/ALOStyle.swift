import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// ALO's shared visual language. The values come from the approved brand mark
// (blue-to-indigo lettering, a coral terminal on a pearl tile) and the approved
// native conversation window (glass surfaces, continuous corners, 8 pt insets).
// Use these instead of literal sizes, radii and colours in new UI.

/// An sRGB value used to build appearance-aware colours on both platforms.
public struct ALOColorValue: Sendable, Hashable {
    public let red: Double, green: Double, blue: Double, alpha: Double

    public init(hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    public init(white: Double, alpha: Double) {
        red = white; green = white; blue = white; self.alpha = alpha
    }
}

public enum ALOBrand {
    /// Primary brand blue. Use for primary actions and selection.
    public static let blue = adaptive(light: .init(hex: 0x306AFF), dark: .init(hex: 0x6F9BFF))
    /// The deep end of the lettering gradient.
    public static let indigo = adaptive(light: .init(hex: 0x3622CE), dark: .init(hex: 0x9A8CFF))
    /// Coral marks "you" and "live". Never use it for errors alone.
    public static let coral = adaptive(light: .init(hex: 0xFF6976), dark: .init(hex: 0xFF8580))

    /// Blue that stays readable as text on ALO surfaces (at least 4.5:1).
    public static let blueText = adaptive(
        light: .init(hex: 0x1F4FD6), dark: .init(hex: 0x9CBBFF),
        highContrastLight: .init(hex: 0x0B2F9A), highContrastDark: .init(hex: 0xC9D8FF))
    /// Coral that stays readable as text on ALO surfaces (at least 4.5:1).
    public static let coralText = adaptive(
        light: .init(hex: 0xC0304E), dark: .init(hex: 0xFF9EA6),
        highContrastLight: .init(hex: 0x8E1733), highContrastDark: .init(hex: 0xFFC4C9))

    public static let blueSoft = adaptive(
        light: .init(hex: 0x306AFF, alpha: 0.11), dark: .init(hex: 0x6F9BFF, alpha: 0.18),
        highContrastLight: .init(hex: 0x306AFF, alpha: 0.2), highContrastDark: .init(hex: 0x6F9BFF, alpha: 0.3))
    public static let coralSoft = adaptive(
        light: .init(hex: 0xFF6976, alpha: 0.13), dark: .init(hex: 0xFF8580, alpha: 0.18),
        highContrastLight: .init(hex: 0xFF6976, alpha: 0.24), highContrastDark: .init(hex: 0xFF8580, alpha: 0.3))
    public static let neutralSoft = adaptive(
        light: .init(white: 0, alpha: 0.055), dark: .init(white: 1, alpha: 0.08),
        highContrastLight: .init(white: 0, alpha: 0.12), highContrastDark: .init(white: 1, alpha: 0.16))

    /// The brand tile's pearl, blush and lavender, darkened for dark appearance.
    public static let pearl = adaptive(light: .init(hex: 0xFAF7FA), dark: .init(hex: 0x15131C))
    public static let blush = adaptive(light: .init(hex: 0xFCE5E6), dark: .init(hex: 0x2A1821))
    public static let lavender = adaptive(light: .init(hex: 0xDEDFFF), dark: .init(hex: 0x1A1E3A))

    /// Hairline strokes that strengthen with Increase Contrast.
    public static let hairline = adaptive(
        light: .init(white: 0, alpha: 0.09), dark: .init(white: 1, alpha: 0.11),
        highContrastLight: .init(white: 0, alpha: 0.45), highContrastDark: .init(white: 1, alpha: 0.5))
    public static let glassHighlight = adaptive(
        light: .init(white: 1, alpha: 0.55), dark: .init(white: 1, alpha: 0.12))
    /// An opaque card fill used when Reduce Transparency is on.
    public static let opaqueCard = adaptive(light: .init(hex: 0xFFFFFF), dark: .init(hex: 0x211F29))

    /// The fill for primary buttons. Fixed so white text keeps 4.5:1 in both appearances.
    public static let primaryGradient = LinearGradient(
        colors: [Color(red: 0x30 / 255, green: 0x6A / 255, blue: 1), Color(red: 0x36 / 255, green: 0x22 / 255, blue: 0xCE / 255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let destructiveGradient = LinearGradient(
        colors: [Color(red: 0xD7 / 255, green: 0x3C / 255, blue: 0x64 / 255), Color(red: 0xB0 / 255, green: 0x22 / 255, blue: 0x4A / 255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    public static func adaptive(
        light: ALOColorValue, dark: ALOColorValue,
        highContrastLight: ALOColorValue? = nil, highContrastDark: ALOColorValue? = nil
    ) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let value: ALOColorValue
            switch appearance.bestMatch(from: [
                .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua,
            ]) {
            case .accessibilityHighContrastDarkAqua: value = highContrastDark ?? dark
            case .accessibilityHighContrastAqua: value = highContrastLight ?? light
            case .darkAqua: value = dark
            default: value = light
            }
            return NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let isHigh = traits.accessibilityContrast == .high
            let value: ALOColorValue
            switch (isDark, isHigh) {
            case (true, true): value = highContrastDark ?? dark
            case (false, true): value = highContrastLight ?? light
            case (true, false): value = dark
            case (false, false): value = light
            }
            return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
        })
        #endif
    }
}

/// One type ramp for every ALO surface. Readable text never goes below 11 pt.
public enum ALOFont {
    #if os(macOS)
    public static let display = Font.system(size: 28, weight: .bold, design: .rounded)
    public static let title = Font.system(size: 22, weight: .bold)
    public static let heading = Font.system(size: 17, weight: .semibold)
    public static let body = Font.system(size: 14)
    public static let label = Font.system(size: 14, weight: .semibold)
    public static let caption = Font.system(size: 12)
    public static let section = Font.system(size: 11, weight: .semibold)
    public static let code = Font.system(size: 15, weight: .semibold, design: .monospaced)
    #else
    public static let display = Font.largeTitle.weight(.bold)
    public static let title = Font.title2.weight(.bold)
    public static let heading = Font.headline
    public static let body = Font.body
    public static let label = Font.body.weight(.semibold)
    public static let caption = Font.footnote
    public static let section = Font.caption.weight(.semibold)
    public static let code = Font.system(.body, design: .monospaced).weight(.semibold)
    #endif
}

public enum ALOMetrics {
    public static let cardRadius: CGFloat = 22
    public static let fieldRadius: CGFloat = 11
    public static let rowRadius: CGFloat = 12
    public static let gutter: CGFloat = 24
    public static let stack: CGFloat = 16
    #if os(iOS)
    public static let controlHeight: CGFloat = 44
    #else
    public static let controlHeight: CGFloat = 36
    #endif
}

public enum ALOTint: Sendable {
    case blue, coral, neutral

    public var text: Color {
        switch self {
        case .blue: ALOBrand.blueText
        case .coral: ALOBrand.coralText
        case .neutral: .secondary
        }
    }

    public var soft: Color {
        switch self {
        case .blue: ALOBrand.blueSoft
        case .coral: ALOBrand.coralSoft
        case .neutral: ALOBrand.neutralSoft
        }
    }
}

// MARK: - Surfaces

/// The brand tile as a backdrop: pearl with a coral glow and a blue glow.
public struct ALOBackdrop: View {
    private let subtle: Bool
    public init(subtle: Bool = false) { self.subtle = subtle }

    public var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height)
            ZStack {
                LinearGradient(colors: [ALOBrand.pearl, ALOBrand.blush.opacity(subtle ? 0.45 : 0.8), ALOBrand.lavender.opacity(subtle ? 0.5 : 0.85)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [ALOBrand.coral.opacity(subtle ? 0.10 : 0.22), .clear],
                               center: UnitPoint(x: 0.92, y: 0.08), startRadius: 0, endRadius: side * 0.55)
                RadialGradient(colors: [ALOBrand.blue.opacity(subtle ? 0.08 : 0.18), .clear],
                               center: UnitPoint(x: 0.05, y: 0.95), startRadius: 0, endRadius: side * 0.6)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct ALOCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency { shape.fill(ALOBrand.opaqueCard) }
                else { shape.fill(.regularMaterial) }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(ALOBrand.hairline, lineWidth: 1))
            .overlay {
                RoundedRectangle(cornerRadius: max(0, cornerRadius - 1), style: .continuous)
                    .strokeBorder(ALOBrand.glassHighlight, lineWidth: 1)
                    .padding(1)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}

public extension View {
    /// ALO's glass card: material fill, hairline, top highlight; opaque with Reduce Transparency.
    func aloCard(cornerRadius: CGFloat = ALOMetrics.cardRadius) -> some View {
        modifier(ALOCardModifier(cornerRadius: cornerRadius))
    }

    /// A quiet inset well for lists and grouped content inside a card or sheet.
    func aloWell(cornerRadius: CGFloat = ALOMetrics.rowRadius) -> some View {
        background(ALOBrand.neutralSoft, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// The ALO text field look, matching the sidebar search field.
    func aloField() -> some View {
        textFieldStyle(.plain)
            .font(ALOFont.body)
            .padding(.horizontal, 12)
            .frame(minHeight: ALOMetrics.controlHeight + 2)
            .background(ALOBrand.neutralSoft, in: RoundedRectangle(cornerRadius: ALOMetrics.fieldRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ALOMetrics.fieldRadius, style: .continuous)
                .strokeBorder(ALOBrand.hairline, lineWidth: 1))
    }
}

// MARK: - Controls

public struct ALOPrimaryButtonStyle: ButtonStyle {
    private let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled
    public init(destructive: Bool = false) { self.destructive = destructive }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ALOFont.label)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: ALOMetrics.controlHeight)
            .background(Capsule().fill(destructive ? ALOBrand.destructiveGradient : ALOBrand.primaryGradient))
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
            .shadow(color: (destructive ? Color.red : Color.blue).opacity(isEnabled ? 0.18 : 0), radius: 8, y: 3)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

public struct ALOSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ALOFont.label)
            .foregroundStyle(ALOBrand.blueText)
            .padding(.horizontal, 16)
            .frame(minHeight: ALOMetrics.controlHeight)
            .background(Capsule().fill(configuration.isPressed ? ALOBrand.blueSoft : ALOBrand.neutralSoft))
            .overlay(Capsule().strokeBorder(ALOBrand.hairline, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

public struct ALOQuietButtonStyle: ButtonStyle {
    private let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled
    public init(destructive: Bool = false) { self.destructive = destructive }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ALOFont.label)
            .foregroundStyle(destructive ? ALOBrand.coralText : ALOBrand.blueText)
            .padding(.horizontal, 6)
            .frame(minHeight: ALOMetrics.controlHeight)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

public extension ButtonStyle where Self == ALOPrimaryButtonStyle {
    static var aloPrimary: ALOPrimaryButtonStyle { ALOPrimaryButtonStyle() }
    static var aloDestructive: ALOPrimaryButtonStyle { ALOPrimaryButtonStyle(destructive: true) }
}

public extension ButtonStyle where Self == ALOSecondaryButtonStyle {
    static var aloSecondary: ALOSecondaryButtonStyle { ALOSecondaryButtonStyle() }
}

public extension ButtonStyle where Self == ALOQuietButtonStyle {
    static var aloQuiet: ALOQuietButtonStyle { ALOQuietButtonStyle() }
    static var aloQuietDestructive: ALOQuietButtonStyle { ALOQuietButtonStyle(destructive: true) }
}

/// An SF Symbol in a soft rounded tile, like the brand mark's tile.
public struct ALOIconBadge: View {
    private let systemImage: String
    private let tint: ALOTint
    private let size: CGFloat

    public init(_ systemImage: String, tint: ALOTint = .blue, size: CGFloat = 44) {
        self.systemImage = systemImage; self.tint = tint; self.size = size
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint.text)
            .frame(width: size, height: size)
            .background(tint.soft, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Small uppercase section label.
public struct ALOSectionLabel: View {
    private let title: String
    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title.uppercased())
            .font(ALOFont.section)
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A capsule label such as "Owner" or "You".
public struct ALOTag: View {
    private let title: String
    private let tint: ALOTint
    public init(_ title: String, tint: ALOTint = .neutral) { self.title = title; self.tint = tint }

    public var body: some View {
        Text(title)
            .font(ALOFont.section)
            .foregroundStyle(tint.text)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.soft, in: Capsule())
    }
}

// MARK: - People

/// Short, speakable comparison codes derived from identity fingerprints.
public enum ALOIdentityCode {
    /// The first 64 bits of the fingerprint in four groups, for example `3F9A 21C0 8B7E 0D11`.
    /// Compare the full fingerprint when a live attacker is a concern.
    public static func short(_ fingerprint: String) -> String {
        let body = fingerprint.split(separator: ":").last.map(String.init) ?? fingerprint
        let characters = Array(body.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(16))
        guard !characters.isEmpty else { return "····" }
        return stride(from: 0, to: characters.count, by: 4)
            .map { String(characters[$0..<min($0 + 4, characters.count)]) }
            .joined(separator: " ")
    }

    /// A stable colour index for avatars. Swift's hashValue changes per launch, so use FNV-1a.
    static func colorIndex(_ value: String, count: Int) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Int(hash % UInt32(max(1, count)))
    }
}

/// A round initial avatar. `isCurrentUser` uses coral, ALO's "you" colour.
public struct ALOAvatar: View {
    private let name: String
    private let seed: String
    private let isCurrentUser: Bool
    private let size: CGFloat
    private static let palette: [Color] = [
        ALOBrand.blue, ALOBrand.indigo,
        ALOBrand.adaptive(light: .init(hex: 0x0E8A7B), dark: .init(hex: 0x4FD1BE)),
        ALOBrand.adaptive(light: .init(hex: 0xB86E00), dark: .init(hex: 0xF2B34C)),
        ALOBrand.adaptive(light: .init(hex: 0x8A3FC7), dark: .init(hex: 0xC99BFF)),
    ]

    public init(name: String, seed: String, isCurrentUser: Bool = false, size: CGFloat = 32) {
        self.name = name; self.seed = seed; self.isCurrentUser = isCurrentUser; self.size = size
    }

    public var body: some View {
        let color = isCurrentUser ? ALOBrand.coralText : Self.palette[ALOIdentityCode.colorIndex(seed, count: Self.palette.count)]
        Text(initial)
            .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: Circle())
            .overlay(Circle().strokeBorder(color.opacity(0.25), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }
}

// MARK: - Sheets and states

/// The standard ALO sheet: icon, title and subtitle, scrolling body, action bar.
public struct ALOSheet<Content: View, Actions: View>: View {
    private let systemImage: String
    private let tint: ALOTint
    private let title: String
    private let subtitle: String?
    private let content: Content
    private let actions: Actions

    public init(systemImage: String, tint: ALOTint = .blue, title: String, subtitle: String? = nil,
                @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.systemImage = systemImage; self.tint = tint; self.title = title; self.subtitle = subtitle
        self.content = content(); self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                ALOIconBadge(systemImage, tint: tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(ALOFont.title).accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle).font(ALOFont.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ALOMetrics.gutter).padding(.top, ALOMetrics.gutter).padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ALOMetrics.gutter).padding(.bottom, 18)
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                actions
            }
            .padding(.horizontal, ALOMetrics.gutter).padding(.vertical, 14)
            .background(alignment: .top) { Rectangle().fill(ALOBrand.hairline).frame(height: 1) }
        }
        .background(ALOBackdrop(subtle: true))
    }
}

/// A labelled field block used inside ALO sheets.
public struct ALOFieldGroup<Field: View>: View {
    private let title: String
    private let footnote: String?
    private let field: Field

    public init(_ title: String, footnote: String? = nil, @ViewBuilder field: () -> Field) {
        self.title = title; self.footnote = footnote; self.field = field()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(ALOFont.label)
            field
            if let footnote {
                Text(footnote).font(ALOFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Loading, empty and error states with a clear next step.
public struct ALOStateView<Actions: View>: View {
    public enum Kind: Sendable { case loading, empty, problem }

    private let kind: Kind
    private let systemImage: String
    private let title: String
    private let message: String?
    private let actions: Actions

    public init(_ kind: Kind = .empty, systemImage: String = "sparkles", title: String, message: String? = nil,
                @ViewBuilder actions: () -> Actions) {
        self.kind = kind; self.systemImage = systemImage; self.title = title; self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 14) {
            if kind == .loading {
                ProgressView().controlSize(.large).frame(width: 56, height: 56)
                    .background(ALOBrand.blueSoft, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            } else {
                ALOIconBadge(systemImage, tint: kind == .problem ? .coral : .blue, size: 56)
            }
            VStack(spacing: 6) {
                Text(title).font(ALOFont.heading).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message).font(ALOFont.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 360)
            HStack(spacing: 10) { actions }.padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

public extension ALOStateView where Actions == EmptyView {
    init(_ kind: Kind = .empty, systemImage: String = "sparkles", title: String, message: String? = nil) {
        self.init(kind, systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// The ALO app mark. On Mac this is the running app's icon (ALO or ALO Dev).
public struct ALOBrandMark: View {
    private let size: CGFloat
    public init(size: CGFloat = 52) { self.size = size }

    public var body: some View {
        Group {
            #if os(macOS)
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                fallback
            }
            #else
            fallback
            #endif
        }
        .frame(width: size, height: size)
        .accessibilityLabel("ALO")
    }

    private var fallback: some View {
        Text("alo")
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(ALOBrand.primaryGradient)
            .frame(width: size, height: size)
            .background(ALOBrand.pearl, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(ALOBrand.hairline))
    }
}
