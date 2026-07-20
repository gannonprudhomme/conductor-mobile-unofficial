//
//  VoiceInput.swift
//  ConductorVoiceInput
//
//  Created by Gannon Prudomme on 7/20/26.
//

import ComposableArchitecture
import ConductorMobileData
import Foundation

@Reducer
public struct VoiceInput: Sendable {
    @ObservableState
    public struct State: Equatable {
        public let id: String
        public var levels: [Float] = []
        public var phase = VoiceInputPhase.idle

        public init(id: String) {
            self.id = id
        }
    }

    public enum Action {
        case cancel
        case delegate(Delegate)
        case microphoneButtonTapped
        case recordingLevelUpdated(Float)
        case recordingStarted(id: String, result: Result<Void, any Error>)
        case transcriptionResponse(id: String, result: Result<String, any Error>)

        @CasePathable
        public enum Delegate {
            case failed(id: String, error: any Error)
            case transcriptionFinished(id: String, transcript: String)
        }
    }

    @Dependency(\.speechTranscriptionClient) var speechTranscriptionClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .microphoneButtonTapped:
                switch state.phase {
                case .idle:
                    state.phase = .startingRecording
                    state.levels.removeAll()
                    return .run { [id = state.id] send in
                        do {
                            try await speechTranscriptionClient.startRecording()
                            await send(.recordingStarted(id: id, result: .success(())))
                        } catch is CancellationError {
                            return
                        } catch {
                            await send(.recordingStarted(id: id, result: .failure(error)))
                        }
                    }
                    .cancellable(id: CancelID.recording, cancelInFlight: true)

                case .recording:
                    state.phase = .transcribing
                    state.levels.removeAll()
                    return .merge(
                        .cancel(id: CancelID.levels),
                        .run { [id = state.id] send in
                            do {
                                let transcript = try await speechTranscriptionClient
                                    .stopRecordingAndTranscribe()
                                await send(
                                    .transcriptionResponse(
                                        id: id,
                                        result: .success(transcript)
                                    )
                                )
                            } catch is CancellationError {
                                return
                            } catch {
                                await send(
                                    .transcriptionResponse(
                                        id: id,
                                        result: .failure(error)
                                    )
                                )
                            }
                        }
                        .cancellable(id: CancelID.recording, cancelInFlight: true)
                    )

                case .startingRecording, .transcribing:
                    return .none
                }

            case .cancel:
                state.phase = .idle
                state.levels.removeAll()
                return .merge(
                    .cancel(id: CancelID.recording),
                    .cancel(id: CancelID.levels),
                    .run { _ in
                        await speechTranscriptionClient.cancelRecording()
                    }
                )

            case let .recordingLevelUpdated(level):
                guard state.phase == .recording else {
                    return .none
                }
                state.levels.append(min(max(level, 0), 1))
                if state.levels.count > 48 {
                    state.levels.removeFirst(state.levels.count - 48)
                }
                return .none

            case let .recordingStarted(id, result):
                guard id == state.id, state.phase == .startingRecording else {
                    return .none
                }
                switch result {
                case .success:
                    state.phase = .recording
                    return .run { send in
                        for await level in speechTranscriptionClient.recordingLevels() {
                            await send(.recordingLevelUpdated(level))
                        }
                    }
                    .cancellable(id: CancelID.levels, cancelInFlight: true)

                case let .failure(error):
                    state.phase = .idle
                    state.levels.removeAll()
                    return .send(.delegate(.failed(id: id, error: error)))
                }

            case let .transcriptionResponse(id, result):
                guard id == state.id, state.phase == .transcribing else {
                    return .none
                }
                state.phase = .idle
                state.levels.removeAll()
                switch result {
                case let .success(transcript):
                    guard !transcript.isEmpty else {
                        return .none
                    }
                    return .send(
                        .delegate(
                            .transcriptionFinished(id: id, transcript: transcript)
                        )
                    )

                case let .failure(error):
                    return .send(.delegate(.failed(id: id, error: error)))
                }

            case .delegate:
                return .none
            }
        }
    }

    private enum CancelID: Hashable {
        case levels
        case recording
    }
}

public enum VoiceInputPhase: Equatable, Sendable {
    case idle
    case startingRecording
    case recording
    case transcribing
}
