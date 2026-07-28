//
//  WorkspaceRow.swift
//  ConductorWorkspaces
//
//  Created by Gannon Prudomme on 7/13/26.
//

import ConductorDesign
import ConductorMobileData
import LucideIcons
import SharedConductorData
import SwiftUI

enum WorkspaceRowAction {
    case archive
    case open
    case setStatus(Workspace.Status)
    case togglePinned
    case toggleUnread
}

struct WorkspaceRow: View {
    private let item: WorkspaceWithRepository
    private let title: String
    private let phaseSeed: String
    private let accessibilityIdentifier: String
    private let isCloudHosted: Bool
    private let isUnread: Bool
    private let isWorking: Bool
    private let pullRequestStatus: MobileWorkspaceState.PullRequestStatus?
    private let repository: Repository?
    private let showsRepositoryIcon: Bool
    private let statusText: String?
    private let action: (@MainActor (WorkspaceRowAction) -> Void)?

    @ScaledMetric(relativeTo: .body) private var iconSize = 20

    init(
        item: WorkspaceWithRepository,
        showsRepositoryIcon: Bool,
        action: (@MainActor (WorkspaceRowAction) -> Void)?
    ) {
        self.item = item
        self.title = item.workspace.displayName
        self.phaseSeed = item.workspace.id
        self.accessibilityIdentifier = "workspaces.workspace.\(item.workspace.id)"
        self.isCloudHosted = item.workspace.isCloudHosted
        self.isUnread = (item.workspace.unread ?? 0) > 0
        self.isWorking = item.isWorking
        self.pullRequestStatus = item.pullRequestStatus
        self.repository = item.repository
        self.showsRepositoryIcon = showsRepositoryIcon
        self.statusText = item.cloudStatusText
        self.action = action
    }

    var body: some View {
        if let action {
            Button {
                action(.open)
            } label: {
                rowLabel
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityIdentifier)
            .contextMenu {
                if isCloudHosted {
                    Button {
                        action(.open)
                    } label: {
                        Label("Open", systemImage: "arrow.right")
                    }
                } else {
                    contextMenu
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !isCloudHosted {
                    Button {
                        action(.toggleUnread)
                    } label: {
                        Label(
                            isUnread ? "Mark as read" : "Mark as unread",
                            systemImage: isUnread ? "envelope.open" : "envelope"
                        )
                    }
                    .tint(.theme(.planBorder))
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if !isCloudHosted {
                    Button(role: .destructive) {
                        action(.archive)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                }
            }
        } else {
            rowLabel
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var rowLabel: some View {
        Label {
            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)

                if isCloudHosted {
                    CloudWorkspaceIcon(size: 16)
                        .accessibilityLabel("Cloud workspace")
                }

                if let statusText {
                    Text(statusText)
                        .font(.theme(.extraExtraSmall))
                        .foregroundStyle(.theme(.textSecondary))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.theme(isUnread ? .textPrimary : .textSecondary))
            .fontWeight(isUnread ? .semibold : .regular)
        } icon: {
            if showsRepositoryIcon {
                RepositoryIcon(repository: repository, size: 20, relativeTo: .body)
                    .foregroundStyle(.theme(.textSecondary))
            }

            if isWorking {
                ProgressView()
                    .progressViewStyle(.conductor(phaseSeed: phaseSeed))
                    .tint(.theme(.textSecondary))
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityLabel("Working")
            } else if let pullRequestStatus {
                PullRequestStatusIcon(
                    status: pullRequestStatus,
                    size: 20,
                    relativeTo: .body
                )
                .accessibilityLabel(pullRequestStatus.accessibilityLabel)
            } else {
                LucideIcon(Lucide.gitBranch, size: 20, relativeTo: .body)
                    .foregroundStyle(.theme(.textSecondary))
            }
        }
        .labelStyle(.conductorStandard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.theme(.textPrimary))
        .font(.theme(.body))
        .contentShape(.rect)
    }

    @ViewBuilder private var contextMenu: some View {
        Button {
            action?(.open)
        } label: {
            Label("Open", systemImage: "arrow.right")
        }

        Button {
            // The section animation makes this menu action visually jump, so update it instantly.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                action?(.toggleUnread)
            }
        } label: {
            Label {
                Text(isUnread ? "Mark as read" : "Mark as unread")
            } icon: {
                ColoredMenuImage(isUnread ? Lucide.mailOpen : Lucide.mail)
            }
        }

        Button {
            action?(.togglePinned)
        } label: {
            Label {
                Text(isPinned ? "Unpin" : "Pin")
            } icon: {
                ColoredMenuImage(isPinned ? Lucide.pinOff : Lucide.pin)
            }
        }

        Menu {
            Picker(
                "Status",
                selection: Binding( // no Binding initializer for sqlite-backed data, so must send an action
                    get: { item.workspace.status },
                    set: { action?(.setStatus($0)) }
                )
            ) {
                ForEach(statuses) { status in
                    Label {
                        Text(status.title)
                    } icon: {
                        LinearStatusIcon(
                            status: status,
                            size: iconSize,
                            preservesColor: true
                        )
                    }
                    .tag(status)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            Label {
                Text("Set status")
            } icon: {
                LinearStatusIcon(
                    status: item.workspace.status,
                    size: iconSize,
                    preservesColor: true
                )
            }

            Text(item.workspace.status.title)
        }

        Section {
            Button(role: .destructive) {
                action?(.archive)
            } label: {
                Label {
                    Text("Archive")
                } icon: {
                    ColoredMenuImage(Lucide.archive, color: .theme(.destructive))
                }
            }
        }
    }

    private var statuses: [Workspace.Status] {
        [.backlog, .inProgress, .inReview, .done, .canceled]
    }

    private var isPinned: Bool {
        item.workspace.pinnedAt != nil
    }

}

private extension MobileWorkspaceState.PullRequestStatus {
    var accessibilityLabel: String {
        switch self {
        case .draft:
            "Draft pull request"

        case .failingChecks:
            "Pull request checks failing"

        case .readyToMerge:
            "Pull request ready to merge"

        case .mergeConflict:
            "Pull request has merge conflicts"

        case .merged:
            "Pull request merged"
        }
    }
}

private extension WorkspaceWithRepository {
    var cloudStatusText: String? {
        guard cloudMetadata != nil, let state = workspace.state?.rawValue else {
            return nil
        }
        return switch state {
        case "ready": nil
        case "initializing": "Initializing"
        case "sleeping": "Sleeping"
        case "archived": "Archived"
        case "deleted": "Deleted"
        case "updating": "Updating"
        default: state
        }
    }
}

#Preview("Workspace row states") {
    let repository = Repository.preview(id: "repository", name: "Conductor")

    List {
        WorkspaceRow(
            item: WorkspaceWithRepository(
                workspace: .preview(
                    id: "read",
                    branch: "Read workspace",
                    derivedStatus: Workspace.Status.backlog.rawValue
                ),
                repository: repository
            ),
            showsRepositoryIcon: true,
            action: { _ in }
        )

        WorkspaceRow(
            item: WorkspaceWithRepository(
                workspace: .preview(
                    id: "unread-pinned",
                    branch: "Unread pinned workspace",
                    derivedStatus: Workspace.Status.inReview.rawValue,
                    pinnedAt: "2026-07-11T00:00:00Z",
                    unread: 1
                ),
                repository: repository,
                mobileState: MobileWorkspaceState(
                    workspaceID: "unread-pinned",
                    isWorking: true
                )
            ),
            showsRepositoryIcon: true,
            action: { _ in }
        )
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
