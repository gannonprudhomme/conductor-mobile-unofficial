function parseCommand(data) {
  // The server validates PATCH input; this check keeps each trusted SSE frame to one mutation.
  const value = JSON.parse(data);
  const [field, ...extraFields] = Object.keys(value)
    .filter((candidate) => candidate !== "workspaceId");
  if (!field || extraFields.length > 0) {
    throw new Error("The command is invalid.");
  }

  return {
    field,
    value: value[field],
    workspaceId: value.workspaceId,
  };
}

async function executeCommand({ sessionService, workspaceService }, command) {
  switch (command.field) {
    case "pinned":
      await workspaceService.setWorkspacePinned({
        workspaceId: command.workspaceId,
        pinned: command.value,
      });
      return;
    case "status":
      await workspaceService.setWorkspaceManualStatus({
        workspaceId: command.workspaceId,
        status: command.value,
      });
      return;
    case "unread":
      if (!command.value) {
        await sessionService.markWorkspaceAsRead(command.workspaceId);
        return;
      } else {
        // Find the active session ID
        const activeSessionID = (await workspaceService.getWorkspaces())
          .find((workspace) => workspace?.id === command.workspaceId)?.activeSessionId;
        const activeSession = (await sessionService.getSessionsForWorkspace({
          workspaceId: command.workspaceId,
          hidden: false,
        })).find((session) => session?.id === activeSessionID);
        if (!activeSession) {
          throw new Error("Workspace has no active visible session to mark unread.");
        }
        await sessionService.setUnread(activeSession.id, true);
        return;
      }
  }
}
