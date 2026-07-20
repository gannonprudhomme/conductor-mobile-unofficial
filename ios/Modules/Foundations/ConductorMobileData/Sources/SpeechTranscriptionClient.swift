//
//  SpeechTranscriptionClient.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/19/26.
//

import AVFAudio
import Dependencies
import DependenciesMacros
import Foundation
import Speech

@DependencyClient
public struct SpeechTranscriptionClient: Sendable {
    public var cancelRecording: @Sendable () async -> Void = { }
    public var recordingLevels: @Sendable () -> AsyncStream<Float> = {
        AsyncStream { $0.finish() }
    }
    public var startRecording: @Sendable () async throws -> Void
    public var stopRecordingAndTranscribe: @Sendable () async throws -> String
}

extension SpeechTranscriptionClient: DependencyKey {
    public static var previewValue: Self {
        Self(
            cancelRecording: {},
            recordingLevels: {
                AsyncStream { continuation in
                    let levels: [Float] = [0.1, 0.35, 0.8, 0.45, 1, 0.6, 0.2]
                    let task = Task {
                        var index = 0
                        for await _ in ContinuousClock().timer(interval: .milliseconds(80)) {
                            continuation.yield(levels[index])
                            index = (index + 1) % levels.count
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            startRecording: {
                try await Task.sleep(for: .milliseconds(300))
            },
            stopRecordingAndTranscribe: {
                try await Task.sleep(for: .seconds(1))
                return "This transcript came from the preview mock."
            }
        )
    }

    public static var testValue: Self {
        var client = Self()
        client.cancelRecording = { }
        client.recordingLevels = { AsyncStream { $0.finish() } }
        return client
    }

    public static var liveValue: Self {
        let transcriber = LiveSpeechTranscriber()
        return Self(
            cancelRecording: { await transcriber.cancelRecording() },
            recordingLevels: {
                AsyncStream { continuation in
                    let task = Task {
                        for await _ in ContinuousClock().timer(interval: .milliseconds(50)) {
                            continuation.yield(await transcriber.recordingLevel())
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            startRecording: { try await transcriber.startRecording() },
            stopRecordingAndTranscribe: {
                try await transcriber.stopRecordingAndTranscribe()
            }
        )
    }
}

public extension DependencyValues {
    var speechTranscriptionClient: SpeechTranscriptionClient {
        get { self[SpeechTranscriptionClient.self] }
        set { self[SpeechTranscriptionClient.self] = newValue }
    }
}

private actor LiveSpeechTranscriber {
    private var pendingStartID: UUID?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func startRecording() async throws {
        cancelRecording()

        let startID = UUID()
        pendingStartID = startID
        guard await AVAudioApplication.requestRecordPermission() else {
            pendingStartID = nil
            throw SpeechTranscriptionError.microphonePermissionDenied
        }
        try Task.checkCancellation()
        guard pendingStartID == startID else {
            throw CancellationError()
        }

        let url = FileManager.default.temporaryDirectory
            .appending(component: "conductor-voice-\(UUID()).m4a")
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)

            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    AVEncoderBitRateKey: 64_000,
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: 44_100,
                ]
            )
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                throw SpeechTranscriptionError.failedToStartRecording
            }

            pendingStartID = nil
            recordingURL = url
            self.recorder = recorder
        } catch {
            pendingStartID = nil
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func recordingLevel() -> Float {
        guard let recorder else {
            return 0
        }
        recorder.updateMeters()
        return min(max((recorder.averagePower(forChannel: 0) + 50) / 50, 0), 1)
    }

    func stopRecordingAndTranscribe() async throws -> String {
        guard let recorder, let recordingURL else {
            throw SpeechTranscriptionError.noActiveRecording
        }

        self.recorder = nil
        self.recordingURL = nil
        recorder.stop()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        defer {
            try? FileManager.default.removeItem(at: recordingURL)
        }

        return try await transcribeAudio(at: recordingURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancelRecording() {
        pendingStartID = nil
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
    }

    private func transcribeAudio(at url: URL) async throws -> String {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(
                  equivalentTo: .current
              ) else {
            throw SpeechTranscriptionError.localeNotSupported
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let installationRequest = try await AssetInventory
            .assetInstallationRequest(supporting: [transcriber]) {
            try await installationRequest.downloadAndInstall()
        }

        let audioFile = try AVAudioFile(forReading: url)
        async let transcript = collectTranscript(from: transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await transcript.get()
    }

    private func collectTranscript(
        from transcriber: SpeechTranscriber
    ) async -> Result<String, any Error> {
        var transcript = ""
        do {
            for try await result in transcriber.results {
                transcript += String(result.text.characters)
            }
        } catch {
            guard !transcript.isEmpty else {
                return .success("")
            }
            return .failure(error)
        }
        return .success(transcript)
    }
}

private enum SpeechTranscriptionError: LocalizedError {
    case failedToStartRecording
    case localeNotSupported
    case microphonePermissionDenied
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case .failedToStartRecording:
            "The microphone couldn't start recording."

        case .localeNotSupported:
            "On-device transcription isn't available for your current language."

        case .microphonePermissionDenied:
            "Allow microphone access in Settings to dictate messages."

        case .noActiveRecording:
            "There isn't an active recording to transcribe."
        }
    }
}
