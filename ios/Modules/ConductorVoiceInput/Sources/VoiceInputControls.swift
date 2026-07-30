//
//  VoiceInputControls.swift
//  ConductorVoiceInput
//
//  Created by Gannon Prudomme on 7/20/26.
//

import ComposableArchitecture
import ConductorDesign
import ConductorMobileData
import LucideIcons
import SwiftUI

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
                        .fill(Color.theme(.textPrimary))
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
        Color.theme(.foreground).opacity(0.05)
    }

    private var foregroundColor: Color {
        .theme(.textPrimary)
    }
}

public struct VoiceInputTakeover: View {
    private let accessibilityIdentifier: String
    private let contentHeight: CGFloat
    private let levels: [Float]
    private let onStopTapped: @MainActor () -> Void
    private let phase: VoiceInputPhase

    public init(
        phase: VoiceInputPhase,
        levels: [Float],
        contentHeight: CGFloat = 40,
        accessibilityIdentifier: String,
        onStopTapped: @escaping @MainActor () -> Void
    ) {
        self.phase = phase
        self.levels = levels
        self.contentHeight = contentHeight
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onStopTapped = onStopTapped
    }

    public var body: some View {
        switch phase {
        case .recording:
            HStack(spacing: 12) {
                RecordingWaveform(
                    levels: levels,
                    height: contentHeight
                )
                    .frame(maxWidth: .infinity)

                VoiceInputButton(
                    phase: phase,
                    isEnabled: true,
                    accessibilityIdentifier: accessibilityIdentifier,
                    idleAccessibilityLabel: "Record audio",
                    action: onStopTapped
                )
            }

        case .transcribing:
            VoiceInputStatus(
                title: "Transcribing…",
                height: contentHeight
            )

        case .idle, .startingRecording:
            EmptyView()
        }
    }
}

private struct RecordingWaveform: View {
    let levels: [Float]
    let height: CGFloat

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
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone audio level")
    }
}

private struct VoiceInputStatus: View {
    let title: String
    let height: CGFloat

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
        .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
    }
}

#Preview("Voice input phases") {
    VStack(spacing: 20) {
        VoiceInputButton(
            phase: .idle,
            isEnabled: true,
            accessibilityIdentifier: "preview.voiceInput",
            idleAccessibilityLabel: "Record prompt",
            action: {}
        )

        VoiceInputButton(
            phase: .startingRecording,
            isEnabled: false,
            accessibilityIdentifier: "preview.voiceInput",
            idleAccessibilityLabel: "Record prompt",
            action: {}
        )

        VoiceInputTakeover(
            phase: .recording,
            levels: [0.1, 0.35, 0.8, 0.45, 1, 0.6, 0.2],
            accessibilityIdentifier: "preview.voiceInput",
            onStopTapped: {}
        )

        VoiceInputStatus(
            title: "Transcribing…",
            height: 40
        )
    }
    .padding()
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}

#Preview("Interactive mock") {
    VoiceInputPreview()
        .preferredColorScheme(.dark)
}

@Reducer
private struct VoiceInputPreviewFeature {
    @ObservableState
    struct State: Equatable {
        var transcript = "Tap the microphone to test the mocked recorder."
        var voiceInput = VoiceInput.State(id: "preview")
    }

    enum Action {
        case voiceInput(VoiceInput.Action)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.voiceInput, action: \.voiceInput) {
            VoiceInput()
        }
        Reduce { state, action in
            switch action {
            case let .voiceInput(
                .delegate(.transcriptionFinished(_, transcript))
            ):
                state.transcript = transcript
                return .none

            case .voiceInput:
                return .none
            }
        }
    }
}

@MainActor
private struct VoiceInputPreview: View {
    let store: StoreOf<VoiceInputPreviewFeature>

    init() {
        store = Store(initialState: VoiceInputPreviewFeature.State()) {
            VoiceInputPreviewFeature()
        } withDependencies: {
            $0.speechTranscriptionClient = .previewValue
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(store.transcript)
                .font(.theme(.body))
                .foregroundStyle(.theme(.textPrimary))
                .frame(maxWidth: .infinity, alignment: .leading)

            if !store.voiceInput.phase.shouldShowTakeover {
                VoiceInputButton(
                    phase: store.voiceInput.phase,
                    isEnabled: store.voiceInput.phase == .idle,
                    accessibilityIdentifier: "preview.voiceInput",
                    idleAccessibilityLabel: "Record prompt",
                    action: {
                        store.send(.voiceInput(.microphoneButtonTapped))
                    }
                )
            } else {
                VoiceInputTakeover(
                    phase: store.voiceInput.phase,
                    levels: store.voiceInput.levels,
                    accessibilityIdentifier: "preview.voiceInput",
                    onStopTapped: {
                        store.send(.voiceInput(.microphoneButtonTapped))
                    }
                )
            }
        }
        .padding()
        .background(.theme(.background))
    }
}
