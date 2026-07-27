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
    @Test("The v1 envelope persists durable message identity, order, and attempt state")
    func envelopeRoundTrip() throws {
        let outbox = MessageOutbox(
            workspaces: [
                "workspace-1": [
                    "session-1": [
                        outboxBubble(
                            precedingBubbleID: UUID(0),
                            precedingTurnID: "turn-0"
                        ),
                    ],
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
        #expect(String(decoding: data, as: UTF8.self).contains("createdAt"))
        #expect(!String(decoding: data, as: UTF8.self).contains("diagnostic"))
    }

    @Test("A v1 bubble saved before causal anchors were added still decodes")
    func legacyBubbleWithoutPrecedingTurnID() throws {
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    MessageOutbox(
                        workspaces: [
                            "workspace-1": [
                                "session-1": [
                                    outboxBubble(precedingTurnID: "turn-1"),
                                ],
                            ],
                        ]
                    )
                )
            ) as? [String: Any]
        )
        var workspaces = try #require(object["workspaces"] as? [String: Any])
        var sessions = try #require(workspaces["workspace-1"] as? [String: Any])
        var bubbles = try #require(sessions["session-1"] as? [[String: Any]])
        bubbles[0]["precedingTurnID"] = nil
        sessions["session-1"] = bubbles
        workspaces["workspace-1"] = sessions
        object["workspaces"] = workspaces

        let decoded = try JSONDecoder().decode(
            MessageOutbox.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded["workspace-1", "session-1"].first?.precedingTurnID == nil)
    }

    @Test("Retry requires every attempt to be rejected or unknown")
    func retryEligibility() {
        var bubble = outboxBubble()
        bubble.attempts = [
            .init(attemptID: UUID(2), state: .rejected),
            .init(attemptID: UUID(3), state: .unknown),
        ]
        #expect(bubble.canRetry)

        bubble.attempts.append(
            .init(attemptID: UUID(4), state: .accepted(messageID: "message-1"))
        )
        #expect(!bubble.canRetry)

        bubble.attempts = [
            .init(attemptID: UUID(5), state: .unknown),
            .init(attemptID: UUID(6), state: .sending),
        ]
        #expect(!bubble.canRetry)
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
    attemptID: UUID = UUID(2),
    precedingBubbleID: UUID? = nil,
    precedingTurnID: String? = nil
) -> MessageOutbox.Bubble {
    MessageOutbox.Bubble(
        bubbleID: bubbleID,
        content: "Run the tests.",
        createdAt: Date(timeIntervalSince1970: 1_783_558_800),
        isFastModeEnabled: true,
        model: .gpt_5_6_terra,
        precedingBubbleID: precedingBubbleID,
        precedingTurnID: precedingTurnID,
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
        .inMemory(fileSystem: fileSystem) {
            scheduler.schedule($0.perform)
        } asyncAfter: {
            scheduler.schedule(
                after: scheduler.now.advanced(by: .init($0)),
                $1.perform
            )
        }
    }
}
