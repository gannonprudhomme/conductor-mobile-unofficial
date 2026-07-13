//
//  ToolCallRowView.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/10/26.
//

import Foundation
import ConductorDesign
import SwiftUI
import LucideIcons

struct ToolCallRowView: View {
    let toolCall: Turn.Row.AssistantMessage.ToolCall
    
    var body: some View {
        LabeledContent {
            detail
        } label: {
            Label {
                if let title {
                    Text(title)
                }
            } icon: {
                LucideIcon(DisplayedChatRow.TurnSummary.ToolIcon(toolCall).image, style: .small)
            }
        }
        .lineLimit(1)
        .labelStyle(.conductorSmall)
        .labeledContentStyle(ToolCallLabeledContentStyle())
        .font(.theme(.small))
    }

    struct ToolCallLabeledContentStyle: LabeledContentStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 8) {
                configuration.label
                
                configuration.content
            }
        }
    }
    
    private var title: LocalizedStringKey? {
        switch toolCall {
        case .readFile:
            // return "Read \("?") lines"
            return "Read"
        case .writeFile:
            return "Write"
        case .editFile:
            return "Edit"
        case .listFiles:
            return "List files"
        case .bash:
            return "Bash"
        case .webSearch:
            return "Web Search"
        case .grep:
            // Entire thing is monospace?
            return nil
        case .mcp:
            return nil
        case .unknown:
            return "UNKNOWN"
        }
    }
        
    @ViewBuilder
    private var detail: some View {
        switch toolCall {
        case .readFile(_, let filePath):
            FileTagView(fileName: fileName(from: filePath))
        case .writeFile(_, let filePath, _):
            FileTagView(fileName: fileName(from: filePath))
        case .editFile(_, let filePath, _, _):
            FileTagView(fileName: fileName(from: filePath))
        case .listFiles(_, let path):
            somethingText(fileName(from: path ?? "."))
        case .bash(_, let command):
            somethingText(command)
        case .webSearch:
            EmptyView()
        case .grep(_, let pattern, let path):
            // TODO: Also need to show {X matches} w/ a different styling
            Text("grep for '\(pattern)' in \(Text(fileName(from: path)).monospaced())")
        case .mcp(_, let name):
            Text(name)
        case .unknown(_, let name, _):
            Text(name)
        }
    }
    
    func somethingText(_ string: String) -> some View {
        Text(string)
            .monospaced()
            .padding(EdgeInsets(vertical: 4, horizontal: 6))
            .background(
                Color.theme(.muted),
                in: .rect(cornerRadius: 6)
            )
    }
    
    private func fileName(from path: String) -> String {
        URL(filePath: path).lastPathComponent
    }
}

extension DisplayedChatRow.TurnSummary.ToolIcon {
    var image: UIImage {
        switch self {
        case .fileText:
            Lucide.fileText
        case .filePen:
            Lucide.filePen
        case .fileQuestionMark:
            Lucide.fileQuestionMark
        case .terminal:
            Lucide.terminal
        case .globe:
            Lucide.globe
        case .search:
            Lucide.search
        case .airplay:
            Lucide.airplay
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .fileText:
            "file reads"
        case .filePen:
            "file changes"
        case .fileQuestionMark:
            "other file tools"
        case .terminal:
            "terminal commands"
        case .globe:
            "web searches"
        case .search:
            "code searches"
        case .airplay:
            "MCP tools"
        }
    }
}

private struct FileTagView: View {
    let fileName: String
    
    var body: some View {
        Text(fileName)
            .lineLimit(1)
            .font(.theme(.codeSmall))
            .padding(EdgeInsets(vertical: 4, horizontal: 8))
            .foregroundStyle(.theme(.textPrimary))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        Color.theme(.input),
                        lineWidth: 1
                    )
            }
    }
}

struct LinesChangesStats: View {
    let additions: Int
    let deletions: Int?
    
    init(oldString: String, newString: String) {
        let (additions, deletions) = lineDiffCounts(oldString: oldString, newString: newString)
        
        self.init(additions: additions, deletions: deletions)
    }
    
    init(additions: Int, deletions: Int?) {
        self.additions = additions
        self.deletions = deletions
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Text("+\(Text(additions, format: .number))")
                .foregroundStyle(.theme(.gitGreen))
            
            if let deletions {
                Text("-\(Text(deletions, format: .number))")
                    .foregroundStyle(.theme(.gitRed))
            }
        }
        // .font(.theme(.footnote)) /// Same as ``FileTagView``
        .monospaced()
    }
}

private func lineDiffCounts(
    oldString: String,
    newString: String
) -> (additions: Int, deletions: Int) {
    let oldLines = oldString.split(separator: "\n", omittingEmptySubsequences: false)
    let newLines = newString.split(separator: "\n", omittingEmptySubsequences: false)

    return newLines.difference(from: oldLines).reduce(
        into: (additions: 0, deletions: 0)
    ) { counts, change in
        switch change {
        case .insert:
            counts.additions += 1
        case .remove:
            counts.deletions += 1
        }
    }
}

#Preview("Tool Calls") {
    ScrollView {
        VStack(spacing: 16) {
            Group {
                ToolCallRowView(
                    toolCall: .readFile(
                        toolUseID: "tool-read-file",
                        filePath: "ios/Modules/ConductorChat/Sources/Views/AssistantMessageRow.swift"
                    )
                )
                
                ToolCallRowView(
                    toolCall: .writeFile(
                        toolUseID: "tool-write-file",
                        filePath: "ios/Modules/ConductorChat/Tests/AssistantMessageRowTests.swift",
                        content: "import Testing\n@testable import ConductorChat"
                    )
                )
                
                ToolCallRowView(
                    toolCall: .editFile(
                        toolUseID: "tool-edit-file",
                        filePath: "ios/Modules/ConductorChat/Sources/Views/AssistantMessageRow.swift",
                        oldString: "return Lucide.fileQuestionMark",
                        newString: "return Lucide.folderSearch"
                    )
                )
                
                ToolCallRowView(
                    toolCall: .listFiles(
                        toolUseID: "tool-list-files",
                        path: "ios/Modules/ConductorChat/Sources/Views"
                    )
                )
                
                ToolCallRowView(
                    toolCall: .bash(
                        toolUseID: "tool-bash",
                        command: "mise -C ios run test"
                    )
                )
                
                ToolCallRowView(
                    toolCall: .webSearch(toolUseID: "tool-web-search")
                )
                
                ToolCallRowView(
                    toolCall: .grep(
                        toolUseID: "tool-grep",
                        pattern: "#Preview",
                        path: "ios/Modules/ConductorChat"
                    )
                )
                
                ToolCallRowView(
                    toolCall: .mcp(
                        toolUseID: "tool-mcp",
                        name: "mcp__xcodebuild__build_sim"
                    )
                )
                
                ToolCallRowView(
                    toolCall: .unknown(
                        toolUseID: "tool-unknown",
                        name: "TodoWrite",
                        input: ["description": .string("Update the task list")]
                    )
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.theme(.textSecondary))
        .padding()
    }
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
