// Pretty AI-slop'y. But gets the job done

// Run SSE commands through Conductor's services. SQLite confirms workspace mutations, while
// agent commands report Conductor's acceptance through a correlated per-call callback.
// Global keys preserve the installed controller and command ordering across cache-busted loads.
const controllerKey = "__conductorMobileWorkspaceUIHookController";
const commandQueueKey = "__conductorMobileWorkspaceUIHookCommandQueue";
const expectedOrigin = "tauri://localhost";
const shellPathPattern = /^\/assets\/shell-[^/]+\.js$/;
const rootIndexPathPattern = /^\/assets\/index-[^/]+\.js$/;
const renderAppPathPattern = /^\/assets\/renderApp-[^/]+\.js$/;
class MessageDeliveryUnknownError extends Error {}
// Older builds put the services in a shell chunk; current builds export them from the root index.
const directShellImportPattern =
  /(?:^|[;\n\r])\s*import(?=\s|["'{*])(?:\s*["'](\.\/shell-[^/"']+\.js)["']|[^;\n\r]*?\bfrom\s*["'](\.\/shell-[^/"']+\.js)["'])/g;
export async function prepareWorkspaceUIHook() {
  const moduleURL = new URL(import.meta.url);
  const hookRevision = moduleURL.searchParams.get("revision");
  if (!hookRevision) {
    throw new Error("The Workspace UI Hook revision is missing.");
  }

  // Private service access is allowed only in Conductor's exact top-level document.
  if (globalThis.window !== globalThis.window.top) {
    throw new Error("The Workspace UI Hook must run in Conductor's top frame.");
  }
  if (globalThis.location.origin !== expectedOrigin) {
    throw new Error("Unexpected Conductor origin: " + globalThis.location.origin);
  }

  const {
    agentService,
    gitService,
    messageProcessingController,
    sessionService,
    workspaceService,
  } = await findConductorServices();

  const hookBaseURL = new URL("./", moduleURL);
  const eventsURL = new URL("events", hookBaseURL);
  eventsURL.searchParams.set("revision", hookRevision);
  const commandResultURL = new URL("command-result", hookBaseURL);
  // Keep one mutation queue across loader runs so a replacement cannot overtake a pending setter.
  const commandQueue = globalThis[commandQueueKey] ?? {
    pendingCancellations: new Map(),
    tail: Promise.resolve(),
  };
  commandQueue.pendingCancellations ??= new Map();
  const controller = createController({
    agentService,
    commandQueue,
    eventsURL,
    gitService,
    hookRevision,
    hookURL: new URL("hook.js", hookBaseURL),
    commandResultURL,
    messageProcessingController,
    sessionService,
    workspaceService,
  });
  const previousController = globalThis[controllerKey];
  previousController?.retire?.();
  globalThis[commandQueueKey] = commandQueue;
  globalThis[controllerKey] = controller;
  controller.open();
  return controller;
}

async function findConductorServices() {
  // Module preloads recover early assets that have fallen out of Resource Timing's buffer.
  const resourceURLs = globalThis.performance
    .getEntriesByType("resource")
    .map((entry) => entry.name);
  const modulePreloadURLs = Array.from(
    globalThis.document.querySelectorAll('link[rel="modulepreload"][href]'),
    (link) => link.href,
  );
  const moduleScriptURLs = Array.from(
    globalThis.document.querySelectorAll('script[type="module"][src]'),
    (script) => script.src,
  );
  const renderAppURLs = matchingAssetURLs(
    [...resourceURLs, ...modulePreloadURLs],
    renderAppPathPattern,
    globalThis.location.href,
  );
  // Traverse the unique renderApp module instead of guessing among unrelated shell chunks.
  if (renderAppURLs.length !== 1) {
    throw new Error("Could not resolve one unambiguous Conductor renderApp module.");
  }

  const renderAppURL = renderAppURLs[0];
  const response = await globalThis.fetch(renderAppURL, { cache: "no-store" });
  if (!response.ok) {
    throw new Error("Could not load Conductor's renderApp module.");
  }
  const source = await response.text();
  const importedShellPaths = Array.from(
    source.matchAll(directShellImportPattern),
    (match) => match[1] ?? match[2],
  );
  const serviceModuleURLs = [
    ...matchingAssetURLs(importedShellPaths, shellPathPattern, renderAppURL),
    ...matchingAssetURLs(moduleScriptURLs, rootIndexPathPattern, globalThis.location.href),
  ];
  if (serviceModuleURLs.length === 0) {
    throw new Error("Could not resolve one unambiguous Conductor service module.");
  }

  if (serviceModuleURLs.length === 1) {
    return resolveConductorServices(await import(serviceModuleURLs[0]));
  }

  const candidates = [];
  for (const serviceModuleURL of serviceModuleURLs) {
    try {
      const serviceModule = await import(serviceModuleURL);
      candidates.push(resolveConductorServices(serviceModule));
    } catch {
      // Ignore referenced modules that do not contain Conductor's required services.
    }
  }
  if (candidates.length !== 1) {
    throw new Error("Could not resolve one unambiguous Conductor service module.");
  }
  return candidates[0];
}

function resolveConductorServices(serviceModule) {
  const workspaceService = uniqueService(
    serviceModule,
    [
      "archiveWorkspace",
      "createWorkspaceWithSetup",
      "getWorkspaces",
      "markUserSetBranchName",
      "setWorkspacePinned",
      "setWorkspaceManualStatus",
    ],
    "WorkspaceService",
  );
  const gitService = uniqueService(
    serviceModule,
    [
      "refreshLocalBranch",
      "refreshWorkspaceChanges",
      "renameBranch",
    ],
    "GitService",
  );
  const agentService = uniqueService(
    serviceModule,
    ["processNextMessage", "sendQueuedMessageImmediately"],
    "AgentService",
  );
  const sessionService = uniqueService(
    serviceModule,
    [
      "createSession",
      "deleteQueuedMessage",
      "editQueuedMessage",
      "getSessionsForWorkspace",
      "hideSession",
      "markWorkspaceAsRead",
      "pauseQueue",
      "reorderQueuedMessages",
      "resumeQueue",
      "setSessionAgentAndModel",
      "setUnread",
      "updateSessionClaudeEffortLevel",
      "updateSessionCodexThinkingLevel",
      "unhideSession",
      "updateSessionFastMode",
      "updateSessionModel",
      "updateSessionTitle",
    ],
    "SessionService",
  );
  const messageProcessingController = uniqueService(
    serviceModule,
    ["enqueueMessage", "sendMessageImmediately", "sendToAgent", "cancelSession"],
    "MessageProcessingController",
  );
  return {
    agentService,
    gitService,
    messageProcessingController,
    sessionService,
    workspaceService,
  };
}

// Normalize and deduplicate only exact Conductor asset URLs before fetching or importing them.
function matchingAssetURLs(values, pathPattern, baseURL) {
  const urls = new Set();
  for (const value of values) {
    if (typeof value !== "string" || value.length === 0) continue;

    try {
      const url = new URL(value, baseURL);
      if (
        url.protocol !== "tauri:"
        || url.host !== "localhost"
        || !pathPattern.test(url.pathname)
      ) continue;

      url.hash = "";
      urls.add(url.href);
    } catch {
      // Ignore malformed page resource entries.
    }
  }
  return [...urls];
}

function uniqueService(module, methods, name) {
  // Minified exports have unstable names, so identify services by stable method sets.
  const services = new Set();
  for (const value of Object.values(module)) {
    if (methods.every((method) => typeof value?.[method] === "function")) {
      services.add(value);
    }
  }
  if (services.size !== 1) {
    throw new Error(`Could not resolve one unambiguous ${name}.`);
  }
  return services.values().next().value;
}

function createController({
  agentService,
  commandQueue,
  commandResultURL,
  eventsURL,
  gitService,
  hookRevision,
  hookURL,
  messageProcessingController,
  sessionService,
  workspaceService,
}) {
  let eventSource;
  let isRetired = false;
  let refreshPromise;

  // EventSource reconnects itself; agent commands use a correlated browser result.
  const controller = {
    open() {
      if (isRetired || eventSource) return;

      eventSource = new EventSource(eventsURL);
      eventSource.onopen = () => {
        if (!isRetired) console.info("CONDUCTOR MOBILE: CONNECTED");
      };
      eventSource.onerror = () => {
        if (isRetired || refreshPromise) return;

        refreshPromise = refreshHook({ hookRevision, hookURL })
          .catch((error) => {
            console.error("Conductor Mobile could not refresh the Workspace UI Hook.", error);
          })
          .finally(() => {
            refreshPromise = undefined;
          });
      };
      eventSource.onmessage = (event) => {
        if (isRetired) return;

        let command;
        try {
          command = parseCommand(event.data);
        } catch (error) {
          console.error(
            "Conductor Mobile received an invalid UI command.",
            error,
          );
          return;
        }

        const execute = () => executeAndReportCommand({
          agentService,
          commandResultURL,
          gitService,
          messageProcessingController,
          pendingCancellations: commandQueue.pendingCancellations,
          sessionService,
          workspaceService,
        }, command);
        const reportError = (error) => {
          console.error("Conductor Mobile UI command failed.", error);
        };
        if (
          command.field === "hidden"
          || (
            command.field === "sendMessage"
            && command.value?.mode === "sent"
          )
        ) {
          execute().catch(reportError);
          return;
        }
        commandQueue.tail = commandQueue.tail.then(execute).catch(reportError);
      };
    },
    retire() {
      if (isRetired) return;

      isRetired = true;
      eventSource?.close();
    },
  };
  return controller;
}

async function refreshHook({ hookRevision, hookURL }) {
  const response = await fetch(hookURL, { cache: "no-store" });
  if (!response.ok) throw new Error("Could not check the Workspace UI Hook revision.");

  const latestRevision = response.headers.get("ETag");
  if (!latestRevision) throw new Error("The Workspace UI Hook revision is missing.");
  if (latestRevision === hookRevision) return;

  const latestHookURL = new URL(hookURL);
  latestHookURL.searchParams.set("revision", latestRevision);
  const module = await import(latestHookURL.href);
  await module.prepareWorkspaceUIHook();
}

function parseCommand(data) {
  const value = JSON.parse(data);
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("The command is invalid.");
  }

  // Swift constructs these trusted SSE commands after validating the requested queue order.
  if ("orderedIds" in value) {
    return {
      field: "queueOrder",
      requestId: value.requestId,
      value: {
        sessionId: value.sessionId,
        orderedIds: value.orderedIds,
      },
    };
  }

  if (
    Object.keys(value).length === 3
    && typeof value.requestId === "string"
    && value.requestId.length > 0
    && typeof value.sessionId === "string"
    && value.sessionId.length > 0
    && typeof value.queuePaused === "boolean"
  ) {
    return {
      field: "queuePaused",
      requestId: value.requestId,
      sessionId: value.sessionId,
      value: value.queuePaused,
    };
  }
  if (value && typeof value === "object" && "queuePaused" in value) {
    throw new Error("The command is invalid.");
  }

  const edit = value?.queuedMessageEdit;
  if (
    Object.keys(value).length === 3
    && typeof value.requestId === "string"
    && value.requestId.length > 0
    && typeof value.sessionId === "string"
    && value.sessionId.length > 0
    && edit
    && typeof edit === "object"
    && !Array.isArray(edit)
    && Object.keys(edit).length === 3
    && typeof edit.messageId === "string"
    && edit.messageId.length > 0
    && typeof edit.content === "string"
    && edit.content.trim().length > 0
    && typeof edit.resumeQueue === "boolean"
  ) {
    return {
      field: "queuedMessageEdit",
      requestId: value.requestId,
      sessionId: value.sessionId,
      value: edit,
    };
  }
  if (value && typeof value === "object" && "queuedMessageEdit" in value) {
    throw new Error("The command is invalid.");
  }

  const [field, ...extraFields] = Object.keys(value)
    .filter((candidate) => !["requestId", "sessionId", "workspaceId"].includes(candidate));
  if (!field || extraFields.length > 0) {
    throw new Error("The command is invalid.");
  }

  return {
    field,
    requestId: value.requestId,
    sessionId: value.sessionId,
    value: value[field],
    workspaceId: value.workspaceId,
  };
}

async function executeAndReportCommand(services, command) {
  let result;
  try {
    result = await executeCommand(services, command);
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    await reportCommandResult(
      services.commandResultURL,
      command,
      command.field === "sendMessage"
        ? {
            result: {
              type: error instanceof MessageDeliveryUnknownError ? "unknown" : "rejected",
              reason,
            },
          }
        : { error: reason },
    );
    throw error;
  }
  await reportCommandResult(
    services.commandResultURL,
    command,
    command.field === "sendMessage" ? { result } : {},
  );
}

async function reportCommandResult(commandResultURL, command, result) {
  if (!command.requestId) return;

  const body = JSON.stringify({ requestId: command.requestId, ...result });
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    let response;
    try {
      response = await fetch(commandResultURL, {
        body,
        headers: { "Content-Type": "application/json" },
        method: "POST",
      });
    } catch (error) {
      lastError = error;
    }
    if (response?.ok || response?.status === 404) return;
    if (response) {
      lastError = new Error(`Could not report the command result (${response.status}).`);
      if (response.status < 500) throw lastError;
    }
    if (attempt < 3) await delay(attempt * 50);
  }
  throw lastError;
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function executeCommand(
  {
    agentService,
    gitService,
    messageProcessingController,
    pendingCancellations,
    sessionService,
    workspaceService,
  },
  command,
) {
  switch (command.field) {
    case "archive":
      if (command.value !== true) {
        throw new Error("The archive command is invalid.");
      }
      await workspaceService.archiveWorkspace({ workspaceId: command.workspaceId });
      return;
    case "branch":
      if (typeof command.value !== "string" || command.value.trim().length === 0) {
        throw new Error("The branch command is invalid.");
      }
      await gitService.renameBranch({
        workspaceId: command.workspaceId,
        branchName: command.value,
        autoRenameWorkspace: false,
      });
      await workspaceService.markUserSetBranchName(command.workspaceId);
      return;
    case "createSession":
      await sessionService.createSession({ workspaceId: command.workspaceId });
      return;
    case "fastMode":
      await sessionService.updateSessionFastMode({
        sessionId: command.sessionId,
        fastMode: command.value,
      });
      return;
    case "createWorkspace":
      await new Promise((resolve, reject) => {
        workspaceService.createWorkspaceWithSetup({
          ...command.value,
          onCreation: resolve,
        }).catch(reject);
      });
      return;
    case "hidden":
      const sessionInput = {
        sessionId: command.sessionId,
        workspaceId: command.workspaceId,
      };
      if (!command.value) {
        try {
          await pendingCancellations.get(command.sessionId);
        } catch {
          // A failed close leaves the session visible, but a later restore may still unhide it.
        }
        await sessionService.unhideSession(sessionInput);
        return;
      }
      const previousCancellation = pendingCancellations.get(command.sessionId);
      const cancellation = (async () => {
        try {
          await previousCancellation;
        } catch {
          // A newer close can retry after an earlier cancellation failed.
        }
        await messageProcessingController.cancelSession(command.sessionId, {
          compressLogsAfterStop: true,
        });
        await sessionService.hideSession(sessionInput);
      })();
      pendingCancellations.set(command.sessionId, cancellation);
      try {
        await cancellation;
      } finally {
        if (pendingCancellations.get(command.sessionId) === cancellation) {
          pendingCancellations.delete(command.sessionId);
        }
      }
      return;
    case "model":
      await sessionService.updateSessionModel(command.sessionId, command.value);
      return;
    case "agentAndModel":
      await sessionService.setSessionAgentAndModel(
        command.sessionId,
        command.value.agentType,
        command.value.model,
      );
      return;
    case "sendMessage":
      {
        if (typeof command.value.attemptId !== "string" || !command.value.attemptId) {
          throw new Error("The message attempt ID is invalid.");
        }
        const session = (await sessionService.getSessionsForWorkspace({
          workspaceId: command.workspaceId,
          hidden: false,
        })).find((candidate) => candidate?.id === command.sessionId);
        if (!session) throw new Error("Session not found.");
        const messageSession = await withReasoningEffort(
          sessionService,
          session,
          command.value.reasoningEffort,
        );

        switch (command.value.mode) {
          case "sent":
            let messageId;
            const receiver = scopedMessageReceiver(
              messageProcessingController,
              async (messageSession, message, turnId, options) => {
                if (typeof message?.id !== "string" || !message.id) {
                  throw new Error("Conductor created an invalid message ID.");
                }
                if (messageId !== undefined) {
                  throw new MessageDeliveryUnknownError(
                    "Conductor dispatched more than one message for one mobile attempt.",
                  );
                }
                messageId = message.id;
                await messageProcessingController.sendToAgent(
                  messageSession,
                  message,
                  turnId,
                  options,
                );
              },
            );
            try {
              await messageProcessingController.sendMessageImmediately.call(
                receiver,
                {
                  session: messageSession,
                  message: command.value.content,
                  workspaceId: command.workspaceId,
                  includeAttachments: false,
                },
              );
            } catch (error) {
              throw new MessageDeliveryUnknownError(
                "Conductor started sending the message, but delivery could not be confirmed.",
                { cause: error },
              );
            }
            if (typeof messageId !== "string" || !messageId) {
              throw new MessageDeliveryUnknownError(
                "Conductor accepted the send command, but created no observable message receipt.",
              );
            }
            return {
              type: "accepted",
              messageId,
            };
          case "queued":
            try {
              await messageProcessingController.enqueueMessage({
                session: messageSession,
                message: command.value.content,
                workspaceId: command.workspaceId,
                includeAttachments: false,
                sendMode: command.value.mode,
                turnId: command.value.attemptId,
              });
            } catch (error) {
              throw new MessageDeliveryUnknownError(
                "Conductor started queueing the message, but delivery could not be confirmed.",
                { cause: error },
              );
            }
            return { type: "accepted" };
          default:
            throw new Error(`Unsupported message mode: ${command.value.mode}`);
        }
      }
    case "stopSession":
      await messageProcessingController.cancelSession(command.sessionId);
      return;
    case "queueOrder":
      await sessionService.reorderQueuedMessages(command.value);
      return;
    case "deleteQueuedMessage":
      if (typeof command.value !== "string" || command.value.length === 0) {
        throw new Error("The queued-message delete command is invalid.");
      }
      await sessionService.deleteQueuedMessage({
        messageId: command.value,
        sessionId: command.sessionId,
      });
      await agentService.processNextMessage(command.sessionId);
      return;
    case "queuePaused":
      await sessionService[command.value ? "pauseQueue" : "resumeQueue"]({
        sessionId: command.sessionId,
      });
      if (!command.value) {
        await agentService.processNextMessage(command.sessionId);
      }
      return;
    case "queuedMessageEdit":
      await sessionService.editQueuedMessage({
        sessionId: command.sessionId,
        messageId: command.value.messageId,
        content: command.value.content,
      });
      if (command.value.resumeQueue) {
        await sessionService.resumeQueue({ sessionId: command.sessionId });
        await agentService.processNextMessage(command.sessionId);
      }
      return;
    case "steerQueuedMessage":
      if (typeof command.value !== "string" || command.value.length === 0) {
        throw new Error("The queued-message steer command is invalid.");
      }
      if (!await agentService.sendQueuedMessageImmediately({
        messageId: command.value,
        sessionId: command.sessionId,
      })) {
        throw new Error("The queued message is no longer available.");
      }
      return;
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
    case "title":
      await sessionService.updateSessionTitle({
        sessionId: command.sessionId,
        workspaceId: command.workspaceId,
        title: command.value,
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
        // Repeat this idempotent call because Conductor may suppress the first unread write.
        await sessionService.setUnread(activeSession.id, true);
        await sessionService.setUnread(activeSession.id, true);
        return;
      }
    default:
      throw new Error(`Unsupported workspace command: ${command.field}`);
  }
}

function scopedMessageReceiver(messageProcessingController, sendToAgent) {
  // The installed Conductor build delegates immediate sends through `this.sendToAgent`.
  // Reject before dispatch if that implementation shape changes instead of guessing at
  // whether a substituted receiver is safe.
  const source = Function.prototype.toString.call(
    messageProcessingController.sendMessageImmediately,
  );
  const sourceWithoutSupportedReceiverAccess = source.replaceAll(
    "this.sendToAgent",
    "",
  );
  if (
    sourceWithoutSupportedReceiverAccess === source
    || /\bthis\b/.test(sourceWithoutSupportedReceiverAccess)
  ) {
    throw new Error(
      "This Conductor version has an unsupported immediate-message implementation.",
    );
  }

  const receiver = Object.create(messageProcessingController);
  Object.defineProperty(receiver, "sendToAgent", {
    configurable: false,
    enumerable: false,
    value: sendToAgent,
    writable: false,
  });
  return receiver;
}

async function withReasoningEffort(sessionService, session, reasoningEffort) {
  if (reasoningEffort === undefined || reasoningEffort === null) return session;
  if (typeof reasoningEffort !== "string" || reasoningEffort.length === 0) {
    throw new Error("The reasoning effort is invalid.");
  }

  switch (session.agentType) {
    case "claude":
      if (session.claudeEffortLevel !== reasoningEffort) {
        await sessionService.updateSessionClaudeEffortLevel({
          sessionId: session.id,
          claudeEffortLevel: reasoningEffort,
        });
      }
      return { ...session, claudeEffortLevel: reasoningEffort };
    case "codex":
      if (session.codexThinkingLevel !== reasoningEffort) {
        await sessionService.updateSessionCodexThinkingLevel(
          session.id,
          reasoningEffort,
        );
      }
      return { ...session, codexThinkingLevel: reasoningEffort };
    default:
      throw new Error(`Unsupported session agent: ${session.agentType}`);
  }
}
