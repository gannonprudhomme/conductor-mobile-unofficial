//
//  ToolCallRoleView.swift
//  ConductorModules
//
//  Created by Gannon Prudomme on 7/10/26.
//

import Foundation
import ConductorDesign
import SwiftUI
import LucideIcons

struct ToolCallRowView: View {
    @ScaledMetric(relativeTo: ThemeFontStyle.small.textStyle)
    private var iconSize: CGFloat = ThemeFontStyle.small.size
    
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
                Image(uiImage: lucideIcon)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
            }
        }
        .lineLimit(1)
        .labelStyle(ToolCallLabelStyle())
        .labeledContentStyle(ToolCallLabeledContentStyle())
        .font(.theme(.small))
    }
    
    struct ToolCallLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            // TODO: SHould this be 12 or 8?
            HStack(spacing: 8) {
                configuration.icon
                
                configuration.title
            }
        }
    }
    
    struct ToolCallLabeledContentStyle: LabeledContentStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 8) {
                configuration.label
                
                configuration.content
            }
        }
    }
    
    private var lucideIcon: UIImage {
        switch toolCall {
        case .readFile:
            return Lucide.fileText
        case .writeFile, .editFile:
            return Lucide.filePen
        case .listFiles:
            return Lucide.fileQuestionMark // TODO: Need to get still
        case .bash:
            return Lucide.terminal
        case .webSearch:
            return Lucide.globe // TODO: Need to find
        case .grep:
            return Lucide.search
        case .mcp:
            return Lucide.airplay // TODO: Unsure
        case .unknown:
            return Lucide.fileQuestionMark
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
        case .writeFile(_, let filePath, let content):
            FileTagView(fileName: fileName(from: filePath))
        case .editFile(_, let filePath, let oldString, let newString):
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
        case .unknown(_, let name, let input):
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

private struct FileTagView: View {
    let fileName: String
    
    var body: some View {
        Text(fileName)
            .monospaced()
            .lineLimit(1)
             .padding(EdgeInsets(vertical: 4, horizontal: 8))
//            .padding(EdgeInsets(vertical: 2, horizontal: 6))
            .overlay {
                // RoundedRectangle(cornerRadius: 26)
                 RoundedRectangle(cornerRadius: 12)
//                Capsule()
                    .strokeBorder(
                        Color.theme(.input),
                        lineWidth: 1
                    )
            }
        /*
            .overlay {
                RoundedRectangle(cornerRadius: 26)
                    .border
            }
         */
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
