// Pretty AI-slop'y. But gets the job done

// Run SSE commands through Conductor's services. SQLite confirms workspace mutations, while
// agent commands report Conductor's acceptance through a correlated callback.
// Global keys preserve the installed controller and command ordering across cache-busted loads.
const controllerKey = "__conductorMobileWorkspaceUIHookController";
const commandQueueKey = "__conductorMobileWorkspaceUIHookCommandQueue";
const expectedOrigin = "tauri://localhost";
const shellPathPattern = /^\/assets\/shell-[^/]+\.js$/;
const rootIndexPathPattern = /^\/assets\/index-[^/]+\.js$/;
const renderAppPathPattern = /^\/assets\/renderApp-[^/]+\.js$/;
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
    gitService,
    messageProcessingController,
    sessionService,
    workspaceService,
  } = await findConductorServices();

  const hookBaseURL = new URL("./", moduleURL);
  const eventsURL = new URL("events", hookBaseURL);
  eventsURL.searchParams.set("revision", hookRevision);
  const commandResultURL = new URL("command-result", hookBaseURL);
  // Keep one queue across loader runs so a replacement cannot overtake a pending setter.
  const commandQueue = globalThis[commandQueueKey] ?? { tail: Promise.resolve() };
  const controller = createController({
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
  const sessionService = uniqueService(
    serviceModule,
    [
      "createSession",
      "getSessionsForWorkspace",
      "setSessionAgentAndModel",
      "markWorkspaceAsRead",
      "setUnread",
      "updateSessionClaudeEffortLevel",
      "updateSessionCodexThinkingLevel",
      "updateSessionFastMode",
      "updateSessionModel",
    ],
    "SessionService",
  );
  const messageProcessingController = uniqueService(
    serviceModule,
    ["enqueueMessage", "sendMessageImmediately", "cancelSession"],
    "MessageProcessingController",
  );
  return { gitService, messageProcessingController, sessionService, workspaceService };
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
          commandResultURL,
          gitService,
          messageProcessingController,
          sessionService,
          workspaceService,
        }, command);
        const reportError = (error) => {
          console.error("Conductor Mobile UI command failed.", error);
        };
        if (command.field === "sendMessage") {
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
  // The server builds these commands; this check keeps each trusted SSE frame to one mutation.
  const value = JSON.parse(data);
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
  try {
    await executeCommand(services, command);
  } catch (error) {
    await reportCommandResult(services.commandResultURL, command, {
      error: error instanceof Error ? error.message : String(error),
    });
    throw error;
  }
  await reportCommandResult(services.commandResultURL, command, {});
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
  { gitService, messageProcessingController, sessionService, workspaceService },
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
            await messageProcessingController.sendMessageImmediately({
              session: messageSession,
              message: command.value.content,
              workspaceId: command.workspaceId,
              includeAttachments: false,
            });
            return;
          case "queued":
            await messageProcessingController.enqueueMessage({
              session: messageSession,
              message: command.value.content,
              workspaceId: command.workspaceId,
              includeAttachments: false,
              sendMode: command.value.mode,
            });
            return;
          default:
            throw new Error(`Unsupported message mode: ${command.value.mode}`);
        }
      }
    case "stopSession":
      await messageProcessingController.cancelSession(command.sessionId);
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
