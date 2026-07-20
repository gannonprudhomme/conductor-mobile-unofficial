//
//  VoiceInputTests.swift
//  ConductorVoiceInputTests
//
//  Created by Gannon Prudomme on 7/20/26.
//

import ComposableArchitecture
import ConductorMobileData
@testable import ConductorVoiceInput
import Testing

@MainActor
struct VoiceInputTests {
    @Test("Recording emits levels and finishes with a transcript")
    func recording() async {
        let (levels, levelContinuation) = AsyncStream<Float>.makeStream()
        let store = TestStore(initialState: VoiceInput.State(id: "test")) {
            VoiceInput()
        } withDependencies: {
            $0.speechTranscriptionClient.recordingLevels = { levels }
            $0.speechTranscriptionClient.startRecording = { }
            $0.speechTranscriptionClient.stopRecordingAndTranscribe = {
                "Run the tests."
            }
        }

        await store.send(.microphoneButtonTapped) {
            $0.phase = .startingRecording
        }
        await store.receive(\.recordingStarted) {
            $0.phase = .recording
        }

        levelContinuation.yield(0.5)
        await store.receive(\.recordingLevelUpdated, 0.5) {
            $0.levels = [0.5]
        }

        await store.send(.microphoneButtonTapped) {
            $0.levels = []
            $0.phase = .transcribing
        }
        await store.receive(\.transcriptionResponse) {
            $0.phase = .idle
        }
        await store.receive(\.delegate.transcriptionFinished)
        levelContinuation.finish()
    }

    @Test("An empty transcript silently returns to idle")
    func emptyTranscript() async {
        let store = TestStore(initialState: VoiceInput.State(id: "test")) {
            VoiceInput()
        } withDependencies: {
            $0.speechTranscriptionClient.startRecording = { }
            $0.speechTranscriptionClient.stopRecordingAndTranscribe = { "" }
        }

        await store.send(.microphoneButtonTapped) {
            $0.phase = .startingRecording
        }
        await store.receive(\.recordingStarted) {
            $0.phase = .recording
        }
        await store.send(.microphoneButtonTapped) {
            $0.phase = .transcribing
        }
        await store.receive(\.transcriptionResponse) {
            $0.phase = .idle
        }
    }

    @Test("Cancellation always stops the shared recorder")
    func cancellation() async {
        let wasCancelled = LockIsolated(false)
        let store = TestStore(initialState: VoiceInput.State(id: "test")) {
            VoiceInput()
        } withDependencies: {
            $0.speechTranscriptionClient.cancelRecording = {
                wasCancelled.setValue(true)
            }
        }

        await store.send(.cancel)
        await store.finish()

        #expect(wasCancelled.value)
    }

    @Test("Responses from another owner are ignored")
    func staleResponse() async {
        var state = VoiceInput.State(id: "current")
        state.phase = .transcribing
        let store = TestStore(initialState: state) {
            VoiceInput()
        }

        await store.send(
            .transcriptionResponse(id: "old", result: .success("Ignore me"))
        )
    }
}
