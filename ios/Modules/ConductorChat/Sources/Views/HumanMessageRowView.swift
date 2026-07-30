//
//  HumanMessageRowView.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/10/26.
//

import ConductorDesign
import LucideIcons
import SwiftUI
import UIKit

struct HumanMessageRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let content: String
    private let deliveryDetail: String?
    private let status: DisplayedChatRow.OptimisticMessage.Status?

    init(row: Turn.Row.HumanMessageRow) {
        self.content = row.content
        self.deliveryDetail = nil
        self.status = nil
    }

    init(optimisticMessage: DisplayedChatRow.OptimisticMessage) {
        self.content = optimisticMessage.content
        self.deliveryDetail = optimisticMessage.deliveryDetail
        self.status = optimisticMessage.status
    }

    var body: some View {
        HStack(spacing: 8) {
            if let status, status != .acceptedAwaitingObservation {
                DeliveryAccessory(detail: deliveryDetail, status: status)
            }

            messageBubble
        }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in
            if dynamicTypeSize.isAccessibilitySize {
                width
            } else {
                width * 0.75
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityValue(
            [status?.accessibilityDescription, deliveryDetail]
                .compactMap { $0 }
                .joined(separator: ": ")
        )
    }

    private var messageBubble: some View {
        ParsedContentView(content: content)
            .padding()
            .background(
                Color.theme(.highlight),
                in: .rect(cornerRadius: 26)
            )
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

    private struct DeliveryAccessory: View {
        @State private var isShowingDetail = false

        let detail: String?
        let status: DisplayedChatRow.OptimisticMessage.Status

        var body: some View {
            switch status {
            case .sending:
                ProgressView()
                    .progressViewStyle(.network)
                    .tint(.theme(.textSecondary))
                    .controlSize(.mini)
                    .accessibilityLabel("Sending")
            case .rejected:
                deliveryDetailButton(
                    icon: Lucide.x,
                    color: .destructive
                )
            case .unconfirmed:
                deliveryDetailButton(
                    icon: Lucide.circleQuestionMark,
                    color: .textSecondary
                )
            case .acceptedAwaitingObservation:
                EmptyView()
            }
        }

        private func deliveryDetailButton(
            icon: UIImage,
            color: ThemeColorStyle
        ) -> some View {
            Button {
                isShowingDetail = true
            } label: {
                LucideIcon(icon, style: .small)
                    .foregroundStyle(.theme(color))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                status.accessibilityDescription ?? "Message delivery failed"
            )
            .accessibilityHint("Shows delivery details")
            .alert(
                status.title ?? "Message delivery",
                isPresented: $isShowingDetail
            ) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(detail ?? status.accessibilityDescription ?? "Delivery could not be confirmed.")
            }
        }
    }

    /// The visible label, encoded attachment path, and full source range of a stored marker.
    struct FileReference {
        let range: Range<String.Index>
        let label: String
        let encodedPath: String
        let kind: Kind

        enum Kind {
            case file
            case skill
        }
    }

    /// Finds stored attachment markers and Markdown links to a skill's `SKILL.md`.
    static func fileReferences(in content: String) -> [FileReference] {
        let attachmentReferences = content.matches(
            of: /@⟦([^⟧]+)⟧\(([^)\n]+)\)/
        ).map { match in
            // Review-comment labels can end in a diff-style line suffix, such as
            // `Chat.swift +10-12` or `Chat.swift -10`; neither suffix is part of the filename.
            let label = match.1.replacing(/\s+[+-]\d+(?:-\d+)?$/, with: "")
            return FileReference(
                range: match.range,
                label: String(label),
                encodedPath: String(match.2),
                kind: .file
            )
        }

        let skillReferences = content.matches(
            of: #/\[([^\]\n]+)\]\((/[^)\n]*/SKILL\.md)\)/#
        ).map { match in
            FileReference(
                range: match.range,
                label: String(match.1),
                encodedPath: String(match.2),
                kind: .skill
            )
        }

        return (attachmentReferences + skillReferences).sorted {
            $0.range.lowerBound < $1.range.lowerBound
        }
    }

    /// Replaces stored file-reference markup with the same labels exposed visually.
    static func displayedContent(_ content: String) -> String {
        let references = fileReferences(in: content)
        var result = ""
        var start = content.startIndex

        for reference in references {
            result += content[start..<reference.range.lowerBound]
            result += reference.label
            start = reference.range.upperBound
        }

        result += content[start...]
        return result
    }

    /// Renders the shared SwiftUI file tag as a TextKit attachment so the surrounding message
    /// retains native paragraph wrapping and selection.
    @MainActor
    private struct ParsedContentView: UIViewRepresentable {
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        let content: String

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context: Context) -> UITextView {
            let textView = UITextView(usingTextLayoutManager: true)
            textView.adjustsFontForContentSizeCategory = true
            textView.backgroundColor = .clear
            textView.dataDetectorTypes = []
            textView.isEditable = false
            textView.isOpaque = false
            textView.isScrollEnabled = false
            textView.isSelectable = true
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainerInset = .zero
            textView.setContentCompressionResistancePriority(.required, for: .vertical)
            textView.setContentHuggingPriority(.required, for: .vertical)
            render(content, in: textView, coordinator: context.coordinator)
            return textView
        }

        func updateUIView(_ textView: UITextView, context: Context) {
            guard context.coordinator.content != content
                    || context.coordinator.dynamicTypeSize != dynamicTypeSize else {
                return
            }

            render(content, in: textView, coordinator: context.coordinator)
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView textView: UITextView,
            context: Context
        ) -> CGSize? {
            guard let maximumWidth = proposal.width, maximumWidth > 0 else {
                return nil
            }

            let unwrappedBounds = textView.attributedText.boundingRect(
                with: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesFontLeading, .usesLineFragmentOrigin],
                context: nil
            )
            let width = min(maximumWidth, max(1, ceil(unwrappedBounds.width)))
            let fittingSize = textView.sizeThatFits(
                CGSize(
                    width: width,
                    height: CGFloat.greatestFiniteMagnitude
                )
            )
            return CGSize(width: width, height: ceil(fittingSize.height))
        }

        private func render(
            _ content: String,
            in textView: UITextView,
            coordinator: Coordinator
        ) {
            let bodyFont = Self.bodyFont(compatibleWith: textView.traitCollection)
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: bodyFont,
                .foregroundColor: UIColor(Color.theme(.highlightForeground)),
            ]
            let attributedContent = NSMutableAttributedString()
            let references = HumanMessageRowView.fileReferences(in: content)
            var start = content.startIndex

            for reference in references {
                attributedContent.append(
                    NSAttributedString(
                        string: String(content[start..<reference.range.lowerBound]),
                        attributes: textAttributes
                    )
                )

                let attachment = FileTagTextAttachment(
                    fileName: reference.label,
                    kind: reference.kind,
                    bodyFont: bodyFont,
                    dynamicTypeSize: dynamicTypeSize,
                    traitCollection: textView.traitCollection
                )
                let attachmentString = NSMutableAttributedString(attachment: attachment)
                attachmentString.addAttributes(
                    textAttributes,
                    range: NSRange(location: 0, length: attachmentString.length)
                )
                attributedContent.append(attachmentString)
                start = reference.range.upperBound
            }

            attributedContent.append(
                NSAttributedString(
                    string: String(content[start...]),
                    attributes: textAttributes
                )
            )

            textView.attributedText = attributedContent
            textView.accessibilityLabel = HumanMessageRowView.displayedContent(content)
            textView.invalidateIntrinsicContentSize()
            coordinator.content = content
            coordinator.dynamicTypeSize = dynamicTypeSize
        }

        private static func bodyFont(
            compatibleWith traitCollection: UITraitCollection
        ) -> UIFont {
            let font = UIFont(
                name: ThemeFontStyle.body.fontName,
                size: ThemeFontStyle.body.size
            ) ?? UIFont.systemFont(ofSize: ThemeFontStyle.body.size)
            return UIFontMetrics(forTextStyle: .body).scaledFont(
                for: font,
                compatibleWith: traitCollection
            )
        }

        final class Coordinator {
            var content: String?
            var dynamicTypeSize: DynamicTypeSize?
        }
    }

    @MainActor
    private final class FileTagTextAttachment: NSTextAttachment {
        init(
            fileName: String,
            kind: FileReference.Kind,
            bodyFont: UIFont,
            dynamicTypeSize: DynamicTypeSize,
            traitCollection: UITraitCollection
        ) {
            super.init(data: nil, ofType: nil)

            let colorScheme: ColorScheme = traitCollection.userInterfaceStyle == .light
                ? .light
                : .dark
            let tagKind: FileTagView.Kind = switch kind {
            case .file:
                .file
            case .skill:
                .skill
            }
            let renderer = ImageRenderer(
                content: FileTagView(
                    fileName: fileName,
                    kind: tagKind
                )
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
            )
            renderer.proposedSize = ProposedViewSize(width: 280, height: nil)
            renderer.scale = max(1, traitCollection.displayScale)
            image = renderer.uiImage

            let size = image?.size ?? CGSize(width: 1, height: bodyFont.lineHeight)
            bounds = CGRect(
                x: 0,
                y: (bodyFont.capHeight - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
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

            HumanMessageRowView(
                row: Turn.Row.HumanMessageRow(
                    id: "file-inline",
                    content: "review this plan: @⟦pasted_text_2026-07-28_21-32-25.txt⟧(.context%2Fattachments%2FN3E1EI%2Fpasted_text.txt)"
                )
            )

            HumanMessageRowView(
                row: Turn.Row.HumanMessageRow(
                    id: "file-leading",
                    content: "@⟦Screen Recording 2026-07-29 at 10.33.11 AM.mov⟧(.context%2Fattachments%2Fvideo.mov)\n\nAdd another version of the progress view, which goes around the border."
                )
            )

            HumanMessageRowView(
                row: Turn.Row.HumanMessageRow(
                    id: "review-comment",
                    content: "@⟦WorkspaceChat.swift +1048⟧(.context%2Fattachments%2Fcomments%2Freview.md) is this still true?"
                )
            )

            HumanMessageRowView(
                row: Turn.Row.HumanMessageRow(
                    id: "skill-reference",
                    content: "[update-with-main](/Users/gannonprudomme/.agents/skills/update-with-main/SKILL.md)"
                )
            )

            HumanMessageRowView(
                optimisticMessage: .init(
                    id: UUID(),
                    content: "Sending",
                    deliveryDetail: nil,
                    status: .sending
                )
            )

            HumanMessageRowView(
                optimisticMessage: .init(
                    id: UUID(),
                    content: "Syncing",
                    deliveryDetail: nil,
                    status: .acceptedAwaitingObservation
                )
            )

            HumanMessageRowView(
                optimisticMessage: .init(
                    id: UUID(),
                    content: "Rejected",
                    deliveryDetail: "The message was rejected.",
                    status: .rejected
                )
            )

            HumanMessageRowView(
                optimisticMessage: .init(
                    id: UUID(),
                    content: "Unknown",
                    deliveryDetail: "Check Conductor before trying again.",
                    status: .unconfirmed
                )
            )
        }
        .padding()
    }
    .scrollContentBackground(.hidden)
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
