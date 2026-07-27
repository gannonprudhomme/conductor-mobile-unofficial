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
    let item: WorkspaceWithRepository
    let showsRepositoryIcon: Bool
    let action: @MainActor (WorkspaceRowAction) -> Void

    @ScaledMetric(relativeTo: .body) private var iconSize = 20

    var body: some View {
        Button {
            action(.open)
        } label: {
            Label {
                Text(item.workspace.displayName)
                    .foregroundStyle(.theme(isUnread ? .textPrimary : .textSecondary))
                    .fontWeight(isUnread ? .semibold : .regular)
                    .lineLimit(1)
            } icon: {
                if showsRepositoryIcon {
                    RepositoryIcon(repository: item.repository, size: 20, relativeTo: .body)
                        .foregroundStyle(.theme(.textSecondary))
                }

                if item.isWorking {
                    ProgressView()
                        .progressViewStyle(.conductor(phaseSeed: item.workspace.id))
                        .tint(.theme(.textSecondary))
                        .frame(width: iconSize, height: iconSize)
                } else if let pullRequestStatus = item.pullRequestStatus {
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
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspaces.workspace.\(item.id)")
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

        Menu {
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
