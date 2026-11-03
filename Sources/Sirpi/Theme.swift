import SwiftUI
import AppKit

/// Design tokens from the Sirpi design canvas: graphite viewport, one lime accent, capsule controls,
/// 18 pt panels, 10 pt cells, 5 pt swatches.
enum Theme {
    static let viewport = Color(hex: "1D1F22")
    static let accent = Color(hex: "C8F25A")
    static let onAccent = Color(hex: "15170E")
    static let warning = Color(hex: "F5B544")
    static let destructive = Color(hex: "F49B8E")
    static let cell = Color.white.opacity(0.05)
    static let hairline = Color.white.opacity(0.08)
    /// Right-hand inspector panel, matching the sidebar's graphite.
    static let inspector = Color(hex: "26282C")
    /// Solid sidebar tone, for footers that must hide rows scrolling beneath them.
    static let sidebar = Color(hex: "232528")
}

extension Color {
    init(hex: String) {
        let v = UInt64(hex.replacingOccurrences(of: "#", with: "").prefix(6), radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Lime prominent glass button with dark label, used for the one primary action per screen.
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var fullWidth = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label {
                Text(title).fontWeight(.semibold).lineLimit(1)
            } icon: {
                if let systemImage { Image(systemName: systemImage) }
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 6)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 26)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.accent)
        .controlSize(.large)
    }
}

struct Swatch: View {
    let hex: String
    var size: CGFloat = 14
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.36)
            .fill(Color(hex: hex))
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size * 0.36).strokeBorder(.white.opacity(0.22), lineWidth: 1))
    }
}

/// A titled inspector section separated by a hairline, as on the canvas.
struct InspectorSection<Content: View>: View {
    var title: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { Text(title).fontWeight(.semibold) }
                    Spacer()
                    if let trailing { trailing }
                }
            }
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var mono = true
    var body: some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(mono ? .body.monospacedDigit() : .body)
        }
    }
}

/// Floating glass capsule toolbar used over the viewport.
struct ViewportToolbar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 6) { content }
            .buttonStyle(ViewportButtonStyle())
            .padding(.horizontal, 10)
            .frame(height: 42)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
    }
}

/// Even hit targets for the floating viewport toolbars: icon-only buttons are square, labelled ones pad out.
struct ViewportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .frame(minWidth: 30, minHeight: 30)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(configuration.isPressed ? 0.14 : 0)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Resizable panels

/// A thin grab bar that resizes the panel above it by dragging. The height is stored per key so
/// each panel keeps the size the user chose across launches. Double-click resets it.
struct ResizeHandle: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    var defaultHeight: Double
    @State private var start: Double?
    @State private var hover = false

    var body: some View {
        ZStack {
            Color.clear.frame(height: 12)
            Capsule().fill(.white.opacity(hover || start != nil ? 0.38 : 0.16)).frame(width: 36, height: 4)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hover = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil { start = height }
                    height = min(range.upperBound, max(range.lowerBound, (start ?? height) + v.translation.height))
                }
                .onEnded { _ in start = nil }
        )
        .onTapGesture(count: 2) { withAnimation(.snappy) { height = defaultHeight } }
        .accessibilityElement()
        .accessibilityLabel("Resize panel")
        .accessibilityValue("\(Int(height)) points")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: height = min(range.upperBound, height + 40)
            case .decrement: height = max(range.lowerBound, height - 40)
            @unknown default: break
            }
        }
        .help("Drag to resize · double-click to reset")
    }
}

/// Wraps content in a panel whose height the user drags from a handle underneath.
struct ResizablePanel<Content: View>: View {
    @AppStorage private var height: Double
    let range: ClosedRange<Double>
    let defaultHeight: Double
    @ViewBuilder var content: Content

    init(key: String, defaultHeight: Double, range: ClosedRange<Double>, @ViewBuilder content: () -> Content) {
        _height = AppStorage(wrappedValue: defaultHeight, "panelHeight.\(key)")
        self.range = range
        self.defaultHeight = defaultHeight
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content.frame(height: min(range.upperBound, max(range.lowerBound, height)))
            ResizeHandle(height: $height, range: range, defaultHeight: defaultHeight)
        }
    }
}

struct ViewportDivider: View {
    var body: some View { Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 18).padding(.horizontal, 4) }
}
