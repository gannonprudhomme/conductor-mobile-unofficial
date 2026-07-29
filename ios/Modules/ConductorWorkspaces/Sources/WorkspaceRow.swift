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
    private let item: WorkspaceWithRepository?
    private let title: String
    private let phaseSeed: String
    private let accessibilityIdentifier: String
    private let isCloudHosted: Bool
    private let isUnread: Bool
    private let isWorking: Bool
    private let pullRequestStatus: MobileWorkspaceState.PullRequestStatus?
    private let repository: Repository?
    private let showsRepositoryIcon: Bool
    private let action: (@MainActor (WorkspaceRowAction) -> Void)?
    private let capabilities: WorkspaceCapabilities

    @ScaledMetric(relativeTo: .body) private var iconSize = 20

    init(
        item: WorkspaceWithRepository,
        showsRepositoryIcon: Bool,
        capabilities: WorkspaceCapabilities = .desktop,
        action: (@MainActor (WorkspaceRowAction) -> Void)?
    ) {
        self.item = item
        self.title = item.workspace.displayName
        self.phaseSeed = item.workspace.id
        self.accessibilityIdentifier = "workspace-row.\(item.workspace.id)"
        self.isCloudHosted = item.cloudMetadata != nil
            || item.workspace.hostingServerURL
                == Workspace.conductorCloudHostingServerURL
        self.isUnread = (item.workspace.unread ?? 0) > 0
        self.isWorking = item.isWorking
        self.pullRequestStatus = item.pullRequestStatus
        self.repository = item.repository
        self.showsRepositoryIcon = showsRepositoryIcon
        self.capabilities = capabilities
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
                contextMenu(action: action, capabilities: capabilities)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if capabilities.canMarkUnread {
                    Button {
                        action(.toggleUnread)
                    } label: {
                        Label(
                            isUnread ? "Read" : "Unread",
                            systemImage: isUnread ? "envelope.open" : "envelope"
                        )
                    }
                    .tint(.theme(.planBorder))
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if capabilities.canArchiveWorkspace {
                    Button(role: .destructive) {
                        action(.archive)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .tint(.theme(.destructive))
                }
            }
        } else {
            rowLabel
                .accessibilityIdentifier(accessibilityIdentifier)
                .accessibilityHint("Cloud workspace details are not available in this version.")
        }
    }

    private var rowLabel: some View {
        Label {
            HStack(spacing: 8) {
                Text(title)
                    .lineLimit(1)

                if isCloudHosted {
                    CloudWorkspaceIcon(size: 16)
                        .accessibilityLabel("Cloud workspace")
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

    @ViewBuilder
    private func contextMenu(
        action: @escaping @MainActor (WorkspaceRowAction) -> Void,
        capabilities: WorkspaceCapabilities
    ) -> some View {
        if capabilities.canMarkUnread {
            Button {
                // The section animation makes this menu action visually jump, so update it instantly.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    action(.toggleUnread)
                }
            } label: {
                Label {
                    Text(isUnread ? "Mark as read" : "Mark as unread")
                } icon: {
                    ColoredMenuImage(isUnread ? Lucide.mailOpen : Lucide.mail)
                }
            }
        }

        if capabilities.canPin {
            Button {
                action(.togglePinned)
            } label: {
                Label {
                    Text(isPinned ? "Unpin" : "Pin")
                } icon: {
                    ColoredMenuImage(isPinned ? Lucide.pinOff : Lucide.pin)
                }
            }
        }

        if capabilities.canSetStatus {
            Menu {
                Picker(
                    "Status",
                    selection: Binding(
                        get: { item?.workspace.status ?? .inProgress },
                        set: { action(.setStatus($0)) }
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
                        status: item?.workspace.status ?? .inProgress,
                        size: iconSize,
                        preservesColor: true
                    )
                }

                Text((item?.workspace.status ?? .inProgress).title)
            }
        }

        if capabilities.canArchiveWorkspace {
            Section {
                Button(role: .destructive) {
                    action(.archive)
                } label: {
                    Label {
                        Text("Archive")
                    } icon: {
                        ColoredMenuImage(
                            Lucide.archive,
                            color: .theme(.destructive)
                        )
                    }
                }
            }
        }
    }

    private var statuses: [Workspace.Status] {
        [.backlog, .inProgress, .inReview, .done, .canceled]
    }

    private var isPinned: Bool {
        item?.workspace.pinnedAt != nil
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
