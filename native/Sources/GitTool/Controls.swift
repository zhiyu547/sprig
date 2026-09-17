// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import SwiftUI

enum ControlTone { case quiet, subtle, primary, accent, selected }

/// Shared desktop chrome: stable bounds, visible hover/press states, native Button semantics.
struct ControlSurface: ViewModifier {
    let tone: ControlTone
    var height: CGFloat = 32
    var horizontalPadding: CGFloat = 10
    var pressed = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    private var foreground: Color {
        switch tone {
        case .primary: return .white
        case .accent: return Palette.mint
        case .selected: return Color(red: 0.70, green: 0.82, blue: 1)
        default: return Color.white.opacity(0.86)
        }
    }
    private var fill: Color {
        let active = isEnabled && hovered
        switch tone {
        case .primary: return Palette.blue.opacity(pressed ? 0.74 : active ? 1 : 0.90)
        case .accent: return Palette.mint.opacity(pressed ? 0.23 : active ? 0.17 : 0.09)
        case .selected: return Palette.blue.opacity(pressed ? 0.30 : active ? 0.25 : 0.19)
        case .subtle: return .white.opacity(pressed ? 0.12 : active ? 0.08 : 0.035)
        case .quiet: return .white.opacity(pressed ? 0.12 : active ? 0.075 : 0)
        }
    }
    private var stroke: Color {
        switch tone {
        case .primary: return .white.opacity(0.12)
        case .accent: return Palette.mint.opacity(hovered ? 0.34 : 0.18)
        case .selected: return Palette.blue.opacity(0.32)
        case .subtle: return .white.opacity(hovered ? 0.16 : 0.09)
        case .quiet: return .white.opacity(hovered ? 0.10 : 0)
        }
    }
    func body(content: Content) -> some View {
        content.font(.system(size: 12, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding).frame(height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

struct SprigButtonStyle: ButtonStyle {
    var tone: ControlTone = .quiet
    var height: CGFloat = 32
    var horizontalPadding: CGFloat = 10
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ControlSurface(tone: tone, height: height, horizontalPadding: horizontalPadding, pressed: configuration.isPressed))
    }
}

struct ToolbarIconButton: View {
    let title: String
    let symbol: String
    var tone: ControlTone = .quiet
    var size: CGFloat = 32
    var tooltip: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical).frame(width: size)
        }.buttonStyle(SprigButtonStyle(tone: tone, height: size, horizontalPadding: 0))
            .accessibilityLabel(title).help(tooltip ?? title)
    }
}

struct DiffModeControl: View {
    @Binding var split: Bool
    var body: some View {
        HStack(spacing: 2) {
            mode("并排", symbol: "rectangle.split.2x1", value: true)
            mode("统一", symbol: "text.alignleft", value: false)
        }.padding(3).background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.border))
            .fixedSize().accessibilityElement(children: .contain).accessibilityLabel("差异视图")
    }
    private func mode(_ title: String, symbol: String, value: Bool) -> some View {
        Button { split = value } label: {
            HStack(spacing: 5) { Image(systemName: symbol).font(.system(size: 11)); Text(title) }
        }.buttonStyle(SprigButtonStyle(tone: split == value ? .selected : .quiet, height: 26, horizontalPadding: 8))
            .accessibilityLabel(title + "差异视图").accessibilityValue(split == value ? "已选中" : "未选中")
            .help(value ? "左右并排对比修改前后的代码" : "在同一列查看全部增删行")
    }
}
