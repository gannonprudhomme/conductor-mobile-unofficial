//
//  ReasoningEffortControl.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/21/26.
//

import ConductorMobileData
import SharedConductorData
import SwiftUI

public struct ReasoningEffortMenu<SourceLabel: View>: View {
    let availableEfforts: [Session.ReasoningEffort]
    let selectedEffort: Session.ReasoningEffort?
    let isDisabled: Bool
    let onSelect: @MainActor (Session.ReasoningEffort) -> Void
    let label: (Session.ReasoningEffort?) -> SourceLabel

    public init(
        availableEfforts: [Session.ReasoningEffort],
        selectedEffort: Session.ReasoningEffort?,
        isDisabled: Bool = false,
        onSelect: @escaping @MainActor (Session.ReasoningEffort) -> Void,
        @ViewBuilder label: @escaping (Session.ReasoningEffort?) -> SourceLabel
    ) {
        self.availableEfforts = availableEfforts
        self.selectedEffort = selectedEffort
        self.isDisabled = isDisabled
        self.onSelect = onSelect
        self.label = label
    }

    public var body: some View {
        Menu {
            Picker(
                "Reasoning effort",
                selection: Binding(
                    get: { selectedEffort },
                    set: { effort in
                        guard let effort else {
                            return
                        }
                        onSelect(effort)
                    }
                )
            ) {
                ForEach(availableEfforts, id: \.self) { effort in
                    Label {
                        Text(effort.displayName)
                    } icon: {
                        ReasoningEffortIcon(
                            activeBarCount: effort.activeBarCount,
                            usesUltraAppearance: effort.usesUltraAppearance
                        )
                    }
                    .tag(Optional(effort))
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            label(selectedEffort)
        }
        .menuOrder(.fixed)
        .disabled(isDisabled)
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(selectedEffort?.displayName ?? "Unavailable")
    }
}

public struct ReasoningEffortControl: View {
    @State private var displayedEffort: Session.ReasoningEffort?

    let availableEfforts: [Session.ReasoningEffort]
    let selectedEffort: Session.ReasoningEffort?
    let isDisabled: Bool
    let showsName: Bool
    let onSelect: @MainActor (Session.ReasoningEffort) -> Void

    public init(
        availableEfforts: [Session.ReasoningEffort],
        selectedEffort: Session.ReasoningEffort?,
        isDisabled: Bool = false,
        showsName: Bool = true,
        onSelect: @escaping @MainActor (Session.ReasoningEffort) -> Void
    ) {
        self.availableEfforts = availableEfforts
        self.selectedEffort = selectedEffort
        self.isDisabled = isDisabled
        self.showsName = showsName
        self.onSelect = onSelect
        _displayedEffort = State(initialValue: selectedEffort)
    }

    public var body: some View {
        ReasoningEffortMenu(
            availableEfforts: availableEfforts,
            selectedEffort: selectedEffort,
            isDisabled: isDisabled,
            onSelect: onSelect
        ) { _ in
            ZStack(alignment: .leading) {
                // Menu snapshots its source label while dismissing. Keeping each
                // effort in place lets opacity animate without clipping that snapshot.
                ForEach(availableEfforts, id: \.self) { effort in
                    effortLabel(for: effort)
                        .opacity(displayedEffort == effort ? 1 : 0)
                }
            }
        }
        .buttonStyle(.spring)
        .task(id: selectedEffort) {
            guard displayedEffort != selectedEffort else {
                return
            }

            // Let the native menu finish dismissing before its source label changes.
//            do {
//                try await Task.sleep(for: .milliseconds(350))
//            } catch {
//                return
//            }

            withAnimation(.smooth(duration: 0.2)) {
                displayedEffort = selectedEffort
            }
        }
    }

    private func effortLabel(for effort: Session.ReasoningEffort) -> some View {
        Group {
            if showsName {
                effortLabelContent(for: effort)
            } else {
                effortLabelContent(for: effort)
                    .labelStyle(.iconOnly)
            }
        }
        .font(.theme(.small))
        .foregroundStyle(
            .theme(effort.usesUltraAppearance ? .textPrimary : .textSecondary)
        )
        .padding(EdgeInsets(vertical: 6, horizontal: 8))
        .background(
            effort.usesUltraAppearance
                ? AnyShapeStyle(LinearGradient.reasoningUltra)
                : AnyShapeStyle(Color.clear),
            in: .capsule
        )
    }

    private func effortLabelContent(
        for effort: Session.ReasoningEffort
    ) -> some View {
        Label {
            if effort != .none {
                Text(effort.displayName)
            }
        } icon: {
            ReasoningEffortIcon(
                activeBarCount: effort.activeBarCount,
                usesUltraAppearance: effort.usesUltraAppearance
            )
        }
    }
}

extension Session.ReasoningEffort {
    var activeBarCount: Int {
        switch self {
        case .none:
            0
        case .low:
            1
        case .medium:
            2
        case .high:
            3
        case .extraHigh:
            4
        case .max:
            5
        case .ultra, .ultracode:
            6
        default:
            0
        }
    }

    var usesUltraAppearance: Bool {
        self == .ultra || self == .ultracode
    }
}

private struct ReasoningEffortIcon: View {
    @ScaledMetric(relativeTo: .footnote) private var height = 16.0

    let activeBarCount: Int
    let usesUltraAppearance: Bool

    var body: some View {
        Image(
            uiImage: reasoningEffortIconImage(activeBarCount: activeBarCount)
                .withTintColor(
                    UIColor(
                        Color.theme(
                            usesUltraAppearance ? .textPrimary : .textSecondary
                        )
                    ),
                    renderingMode: .alwaysOriginal
                )
        )
        .resizable()
        .frame(
            width: height * reasoningEffortIconAspectRatio,
            height: height
        )
        .accessibilityHidden(true)
    }
}

private let reasoningEffortIconAspectRatio = 22.5 / 16.0

private func reasoningEffortIconImage(activeBarCount: Int) -> UIImage {
    let height = 16.0
    let barWidth = 2.5
    let spacing = 1.5
    let size = CGSize(
        width: barWidth * 6 + spacing * 5,
        height: height
    )

    return UIGraphicsImageRenderer(size: size).image { context in
        UIColor.white.setFill()

        for bar in 1...6 {
            let barHeight = height * CGFloat(bar) / 6
            let rect = CGRect(
                x: CGFloat(bar - 1) * (barWidth + spacing),
                y: height - barHeight,
                width: barWidth,
                height: barHeight
            )
            context.cgContext.setAlpha(bar <= activeBarCount ? 1 : 0.25)
            let path = UIBezierPath(
                roundedRect: rect,
                cornerRadius: barWidth / 2
            )
            path.fill()
        }
    }
}
