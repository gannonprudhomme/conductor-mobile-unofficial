//
//  WorkspaceRow.swift
//  ConductorWorkspaces
//
//  Created by Gannon Prudomme on 7/13/26.
//

import ConductorCloud
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
    let item: WorkspaceWithRepository
    let showsRepositoryIcon: Bool
    let action: @MainActor (WorkspaceRowAction) -> Void

    @ScaledMetric(relativeTo: .body) private var iconSize = 20

    var body: some View {
        Button {
            action(.open)
        } label: {
            WorkspaceRowLabel(
                title: item.workspace.displayName,
                phaseSeed: item.workspace.id,
                isCloudHosted: item.workspace.isCloudHosted,
                isUnread: isUnread,
                isWorking: item.isWorking,
                pullRequestStatus: item.pullRequestStatus,
                repository: item.repository,
                showsRepositoryIcon: showsRepositoryIcon
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenu
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
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
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                action(.archive)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    @ViewBuilder private var contextMenu: some View {
        Button {
            // Animation looks bad for htis for some reason, so make it instant / disable animations
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

        Button {
            action(.togglePinned)
        } label: {
            Label {
                Text(isPinned ? "Unpin" : "Pin")
            } icon: {
                ColoredMenuImage(isPinned ? Lucide.pinOff : Lucide.pin)
            }
        }

        Section {
            Picker(
                "Status",
                selection: Binding( // no Binding initializer for sqlite-backed data, so must send an action
                    get: { item.workspace.status },
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
            .pickerStyle(.inline)
        }

        Section {
            Button(role: .destructive) {
                action(.archive)
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

    private var isUnread: Bool {
        (item.workspace.unread ?? 0) > 0
    }
}

struct CloudWorkspaceListRow: View {
    let item: CloudProjectWorkspace
    let repository: Repository?
    let showsRepositoryIcon: Bool
    let status: CloudWorkspaceStatusResponse?
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            WorkspaceRowLabel(
                title: item.workspace.name,
                phaseSeed: item.id,
                isCloudHosted: true,
                isUnread: false,
                isWorking: status?.status == .initializing || status?.status == .updating,
                pullRequestStatus: nil,
                repository: repository,
                showsRepositoryIcon: showsRepositoryIcon
            )
        }
        .buttonStyle(.plain)
    }
}

private struct WorkspaceRowLabel: View {
    let title: String
    let phaseSeed: String
    let isCloudHosted: Bool
    let isUnread: Bool
    let isWorking: Bool
    let pullRequestStatus: MobileWorkspaceState.PullRequestStatus?
    let repository: Repository?
    let showsRepositoryIcon: Bool

    @ScaledMetric(relativeTo: .body) private var iconSize = 20

    var body: some View {
        Label {
            HStack(spacing: 5) {
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
            } else if let pullRequestStatus {
                PullRequestStatusIcon(
                    status: pullRequestStatus,
                    size: 20,
                    relativeTo: .body
                )
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
