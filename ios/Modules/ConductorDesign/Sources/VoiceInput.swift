//
//  VoiceInput.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/19/26.
//

import LucideIcons
import SwiftUI

public enum VoiceInputPhase: Equatable, Sendable {
    case idle
    case startingRecording
    case recording
    case transcribing
}

public struct VoiceInputButton: View {
    @ScaledMetric(relativeTo: ThemeFontStyle.body.textStyle)
    private var iconSize = ThemeFontStyle.body.size

    private let accessibilityIdentifier: String
    private let action: @MainActor () -> Void
    private let idleAccessibilityLabel: String
    private let isEnabled: Bool
    private let phase: VoiceInputPhase

    public init(
        phase: VoiceInputPhase,
        isEnabled: Bool,
        accessibilityIdentifier: String,
        idleAccessibilityLabel: String,
        action: @escaping @MainActor () -> Void
    ) {
        self.phase = phase
        self.isEnabled = isEnabled
        self.accessibilityIdentifier = accessibilityIdentifier
        self.idleAccessibilityLabel = idleAccessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label {
                Text(accessibilityLabel)
            } icon: {
                switch phase {
                case .idle:
                    LucideIcon(Lucide.mic, style: .body)

                case .recording:
                    let rectSize = iconSize / 1.5
                    Rectangle()
                        .fill(Color.theme(.destructive))
                        .frame(width: rectSize, height: rectSize)
                        .frame(width: iconSize, height: iconSize)
                        .contentTransition(.opacity)

                case .startingRecording, .transcribing:
                    ProgressView()
                        .progressViewStyle(.network)
                        .tint(foregroundColor)
                }
            }
            .labelStyle(.iconOnly)
            .font(.theme(.body))
            .foregroundStyle(foregroundColor)
            .tint(foregroundColor)
            .padding(8)
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier(accessibilityIdentifier)
        .glassEffect(
            .regular
                .tint(backgroundColor)
                .interactive(isEnabled)
        )
        .animation(.default, value: phase)
        .sensoryFeedback(.selection, trigger: phase)
    }

    private var accessibilityLabel: String {
        switch phase {
        case .idle:
            idleAccessibilityLabel

        case .startingRecording:
            "Starting recording"

        case .recording:
            "Stop recording"

        case .transcribing:
            "Transcribing recording"
        }
    }

    private var backgroundColor: Color {
        switch phase {
        case .recording:
            .theme(.destructiveBackground)

        case .idle, .startingRecording, .transcribing:
            Color.theme(.foreground).opacity(0.05)
        }
    }

    private var foregroundColor: Color {
        switch phase {
        case .recording:
            .theme(.destructive)

        case .idle, .startingRecording, .transcribing:
            .theme(.textPrimary)
        }
    }
}

public struct VoiceInputTakeover: View {
    private let accessibilityIdentifier: String
    private let levels: [Float]
    private let onStopTapped: @MainActor () -> Void
    private let phase: VoiceInputPhase

    public init(
        phase: VoiceInputPhase,
        levels: [Float],
        accessibilityIdentifier: String,
        onStopTapped: @escaping @MainActor () -> Void
    ) {
        self.phase = phase
        self.levels = levels
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onStopTapped = onStopTapped
    }

    public var body: some View {
        switch phase {
        case .recording:
            HStack(spacing: 12) {
                RecordingWaveform(levels: levels)
                    .frame(maxWidth: .infinity)

                VoiceInputButton(
                    phase: phase,
                    isEnabled: true,
                    accessibilityIdentifier: accessibilityIdentifier,
                    idleAccessibilityLabel: "Record audio",
                    action: onStopTapped
                )
            }

        case .startingRecording:
            VoiceInputStatus(title: "Starting recording…")

        case .transcribing:
            VoiceInputStatus(title: "Transcribing…")

        case .idle:
            EmptyView()
        }
    }
}

private struct RecordingWaveform: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let barWidth = 3.0
            let spacing = 3.0
            let barCount = max(Int((size.width + spacing) / (barWidth + spacing)), 1)
            let visibleLevels = Array(levels.suffix(barCount))
            let leadingEmptyBarCount = barCount - visibleLevels.count

            for index in 0..<barCount {
                let levelIndex = index - leadingEmptyBarCount
                let level = levelIndex >= 0
                    ? CGFloat(visibleLevels[levelIndex])
                    : 0
                let barHeight = max(barWidth, level * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + spacing),
                    y: (size.height - barHeight) / 2,
                    width: barWidth,
                    height: barHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(Color.theme(.accent))
                )
            }
        }
        .frame(height: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone audio level")
    }
}

private struct VoiceInputStatus: View {
    let title: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            ProgressView()
                .progressViewStyle(.network)
                .tint(.theme(.textSecondary))
        }
        .labelStyle(.conductorSmall)
        .font(.theme(.small))
        .foregroundStyle(.theme(.textSecondary))
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
    }
}
