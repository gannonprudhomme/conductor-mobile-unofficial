//
//  MessageOutboxTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/19/26.
//

@testable import ConductorMobileData
import Combine
import CombineSchedulers
import CustomDump
import Dependencies
import Foundation
@_spi(Internals) import Sharing
import Testing

@Suite(.serialized)
struct MessageOutboxTests {
    @Test("The v1 envelope persists only durable message identity and attempt state")
    func envelopeRoundTrip() throws {
        let outbox = MessageOutbox(
            workspaces: [
                "workspace-1": [
                    "session-1": [outboxBubble()],
                ],
            ]
        )

        let data = try JSONEncoder().encode(outbox)
        expectNoDifference(try JSONDecoder().decode(MessageOutbox.self, from: data), outbox)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["version"] as? Int == 1)
        #expect(Set(object.keys) == ["version", "workspaces"])
        #expect(!String(decoding: data, as: UTF8.self).contains("timestamp"))
        #expect(!String(decoding: data, as: UTF8.self).contains("diagnostic"))
    }

    @Test("Corrupt and unsupported envelopes fail without changing their bytes", arguments: [
        Data("not-json".utf8),
        Data(#"{"version":2,"workspaces":{}}"#.utf8),
    ])
    func corruptEnvelope(originalData: Data) throws {
        let fileSystem = LockIsolated([messageOutboxURL: originalData])
        withDependencies {
            $0.defaultFileStorage = .inMemory(fileSystem: fileSystem)
        } operation: {
            @Shared(.messageOutbox) var outbox
            #expect($outbox.loadError != nil)
            #expect(outbox == MessageOutbox())
            expectNoDifference(fileSystem.value[messageOutboxURL], originalData)
        }
    }

    @Test("Missing and empty storage save a valid v1 envelope", arguments: [
        Optional<Data>.none,
        Data(),
    ])
    func emptyStorage(originalData: Data?) async throws {
        let fileSystem = LockIsolated(
            originalData.map { [messageOutboxURL: $0] } ?? [:]
        )
        try await withDependencies {
            $0.defaultFileStorage = .inMemory(fileSystem: fileSystem)
        } operation: {
            @Shared(.messageOutbox) var outbox
            #expect($outbox.loadError == nil)

            try await $outbox.save()

            let saved = try JSONDecoder().decode(
                MessageOutbox.self,
                from: try #require(fileSystem.value[messageOutboxURL])
            )
            expectNoDifference(saved, MessageOutbox())
        }
    }

    @Test("Explicit save flushes a mutation that is still debounced")
    func explicitSave() async throws {
        let fileSystem = LockIsolated<[URL: Data]>([:])
        let scheduler = DispatchQueue.test
        try await withDependencies {
            $0.defaultFileStorage = .inMemory(
                fileSystem: fileSystem,
                scheduler: scheduler
            )
        } operation: {
            @Shared(.messageOutbox) var outbox
            $outbox.withLock {
                $0["workspace-1", "session-1"] = [outboxBubble()]
            }
            $outbox.withLock {
                $0["workspace-1", "session-1"][0].attempts.append(
                    .init(attemptID: UUID(3), state: .unknown)
                )
            }

            let beforeSave = try JSONDecoder().decode(
                MessageOutbox.self,
                from: try #require(fileSystem.value[messageOutboxURL])
            )
            #expect(beforeSave["workspace-1", "session-1"][0].attempts.count == 1)

            try await $outbox.save()

            let saved = try JSONDecoder().decode(
                MessageOutbox.self,
                from: try #require(fileSystem.value[messageOutboxURL])
            )
            #expect(saved["workspace-1", "session-1"][0].attempts.count == 2)
        }
    }

    @Test("Mutations for different sessions share one file without clobbering")
    func concurrentSessions() async throws {
        let fileSystem = LockIsolated<[URL: Data]>([:])
        try await withDependencies {
            $0.defaultFileStorage = .inMemory(fileSystem: fileSystem)
        } operation: {
            @Shared(.messageOutbox) var outbox
            $outbox.withLock {
                $0["workspace-1", "session-1"] = [outboxBubble(bubbleID: UUID(1))]
            }
            $outbox.withLock {
                $0["workspace-1", "session-2"] = [
                    outboxBubble(bubbleID: UUID(4), attemptID: UUID(5)),
                ]
            }
            try await $outbox.save()

            let saved = try JSONDecoder().decode(
                MessageOutbox.self,
                from: try #require(fileSystem.value[messageOutboxURL])
            )
            #expect(saved["workspace-1", "session-1"].count == 1)
            #expect(saved["workspace-1", "session-2"].count == 1)
        }
    }
}

private let messageOutboxURL = URL.applicationSupportDirectory
    .appending(component: "message-outbox.json")

private func outboxBubble(
    bubbleID: UUID = UUID(1),
    attemptID: UUID = UUID(2)
) -> MessageOutbox.Bubble {
    MessageOutbox.Bubble(
        bubbleID: bubbleID,
        content: "Run the tests.",
        model: .gpt_5_6_terra,
        attempts: [
            .init(attemptID: attemptID, state: .sending),
        ]
    )
}

private extension FileStorage {
    static func inMemory<S: Scheduler & Sendable>(
        fileSystem: LockIsolated<[URL: Data]>,
        scheduler: S
    ) -> Self where S.SchedulerTimeType == DispatchQueue.SchedulerTimeType {
        .inMemory(
            fileSystem: fileSystem,
            async: { scheduler.schedule($0.perform) },
            asyncAfter: {
                scheduler.schedule(
                    after: scheduler.now.advanced(by: .init($0)),
                    $1.perform
                )
            }
        )
    }
}
