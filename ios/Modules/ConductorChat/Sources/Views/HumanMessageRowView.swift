//
//  HumanMessageRowView.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/10/26.
//

import ConductorDesign
import LucideIcons
import SwiftUI

struct HumanMessageRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let content: String
    private let retry: (@MainActor () -> Void)?
    private let status: DisplayedChatRow.OptimisticMessage.Status?

    init(row: Turn.Row.HumanMessageRow) {
        self.content = row.content
        self.retry = nil
        self.status = nil
    }

    init(
        optimisticMessage: DisplayedChatRow.OptimisticMessage,
        retry: @escaping @MainActor () -> Void
    ) {
        self.content = optimisticMessage.content
        self.retry = retry
        self.status = optimisticMessage.status
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            messageBubble

            if let status {
                HStack(spacing: 8) {
                    Text(status.label)
                        .font(.theme(.small))
                        .foregroundStyle(.theme(.textSecondary))

                    if status.canRetry, let retry {
                        Button("Retry message", action: retry)
                            .font(.theme(.small))
                            .foregroundStyle(.theme(.textPrimary))
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityValue(status?.accessibilityValue ?? "")
    }

    private var messageBubble: some View {
        ParsedContentView(content: content)
            .textSelection(.enabled)
            .font(.theme(.body))
            .foregroundStyle(.theme(.highlightForeground))
            .padding()
            .background(
                Color.theme(.highlight),
                in: .rect(cornerRadius: 26)
            )
            .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in
                if dynamicTypeSize.isAccessibilitySize {
                    width
                } else {
                    width * 0.75
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = content
                } label: {
                    Label {
                        Text("Copy")
                            .foregroundStyle(.theme(.textPrimary))
                    } icon: {
                        LucideIcon(Lucide.copy, style: .body)
                            .foregroundStyle(.theme(.textPrimary))
                    }
                }
                .preferredColorScheme(.dark)
            }
    }

    /// Displays stored file-reference markup (`@⟦label⟧(encodedPath)`) as only
    /// its styled label while leaving the rest of the human message unchanged.
    private struct ParsedContentView: View {
        private let content: String
        private let references: [FileReference]

        init(content: String) {
            self.content = content
            self.references = HumanMessageRowView.fileReferences(in: content)
        }

        var body: some View {
            text(references[...], from: content.startIndex)
        }

        /// Recursively combines unchanged message slices and styled labels into
        /// one `Text`, preserving SwiftUI's native wrapping and text selection.
        private func text(
            _ references: ArraySlice<FileReference>,
            from start: String.Index
        ) -> Text {
            guard let reference = references.first else {
                return Text(verbatim: String(content[start...]))
            }

            let prefix = Text(verbatim: String(content[start..<reference.range.lowerBound]))
            let referenceText = Text(verbatim: reference.label)
                .font(.theme(.codeSmall))
                .bold()
                .underline()
            let suffix = text(references.dropFirst(), from: reference.range.upperBound)

            return Text("\(prefix)\(referenceText)\(suffix)")
        }
    }

    /// The visible label and full source range of a stored file-reference marker.
    /// The encoded path is intentionally omitted because this presentation is noninteractive.
    struct FileReference {
        let range: Range<String.Index>
        let label: String
    }

    /// Finds each complete marker so rendering can remove its markup, encoded
    /// path, and diff-like line suffix while retaining the human-readable label.
    static func fileReferences(in content: String) -> [FileReference] {
        content.matches(of: /@⟦([^⟧]+)⟧\(([^)\n]+)\)/).map { match in
            // Review-comment labels can end in a diff-style line suffix, such as
            // `Chat.swift +10-12` or `Chat.swift -10`; neither suffix is part of the filename.
            let label = match.1.replacing(/\s+[+-]\d+(?:-\d+)?$/, with: "")
            return FileReference(range: match.range, label: String(label))
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 8) {
            HumanMessageRowView(
                row: Turn.Row.HumanMessageRow(
                    id: "1234",
                    content: "Content"
                )
            )

            HumanMessageRowView(
                row: Turn.Row.HumanMessageRow(
                    id: "12345",
                    content: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."
                )
            )
        }
        .padding()
    }
    .scrollContentBackground(.hidden)
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
