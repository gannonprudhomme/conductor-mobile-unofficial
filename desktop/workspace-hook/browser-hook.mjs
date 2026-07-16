// Pretty AI-slop'y. But gets the job done

// Run SSE commands through Conductor's services, then let the server confirm them through SQLite.
// Global keys preserve newest-run ownership and command ordering across cache-busted loads.
const loaderGenerationKey = "__conductorMobileWorkspaceUIHookLoaderRun";
const controllerKey = "__conductorMobileWorkspaceUIHookController";
const commandQueueKey = "__conductorMobileWorkspaceUIHookCommandQueue";
const expectedOrigin = "tauri://localhost";
const shellPathPattern = /^\/assets\/shell-[^/]+\.js$/;
const renderAppPathPattern = /^\/assets\/renderApp-[^/]+\.js$/;
// Only renderApp's static shell import identifies the chunk containing the services we need.
const directShellImportPattern =
  /(?:^|[;\n\r])\s*import(?=\s|["'{*])(?:\s*["'](\.\/shell-[^/"']+\.js)["']|[^;\n\r]*?\bfrom\s*["'](\.\/shell-[^/"']+\.js)["'])/g;
export async function prepareWorkspaceUIHook(generation) {
  const moduleURL = new URL(import.meta.url);

  // Private service access is allowed only in Conductor's exact top-level document.
  if (globalThis.window !== globalThis.window.top) {
    throw new Error("The Workspace UI Hook must run in Conductor's top frame.");
  }
  if (globalThis.location.origin !== expectedOrigin) {
    throw new Error("Unexpected Conductor origin: " + globalThis.location.origin);
  }

  const shellURL = await findShellURL();
  const shell = await import(shellURL);
  const workspaceService = uniqueService(
    shell,
    ["getWorkspaces", "setWorkspacePinned", "setWorkspaceManualStatus"],
    "WorkspaceService",
  );
  const sessionService = uniqueService(
    shell,
    ["getSessionsForWorkspace", "setUnread", "markWorkspaceAsRead"],
    "SessionService",
  );

  const hookBaseURL = new URL("./", moduleURL);
  // Keep one queue across loader runs so a replacement cannot overtake a pending setter.
  const commandQueue = globalThis[commandQueueKey] ?? { tail: Promise.resolve() };
  const controller = createController({
    commandQueue,
    eventsURL: new URL("events", hookBaseURL),
    sessionService,
    workspaceService,
  });
  // Check the generation last so a stale import can finish without replacing the current hook.
  if (
    typeof generation !== "string"
    || generation.length === 0
    || globalThis[loaderGenerationKey] !== generation
  ) return undefined;

  const previousController = globalThis[controllerKey];
  previousController?.retire?.();
  globalThis[commandQueueKey] = commandQueue;
  globalThis[controllerKey] = controller;
  controller.open();
  return controller;
}

async function findShellURL() {
  // Module preloads recover early assets that have fallen out of Resource Timing's buffer.
  const resourceURLs = globalThis.performance
    .getEntriesByType("resource")
    .map((entry) => entry.name);
  const modulePreloadURLs = Array.from(
    globalThis.document.querySelectorAll('link[rel="modulepreload"][href]'),
    (link) => link.href,
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
  const importedPaths = Array.from(
    source.matchAll(directShellImportPattern),
    (match) => match[1] ?? match[2],
  );
  if (importedPaths.length !== 1) {
    throw new Error("Could not resolve one unambiguous shell import from renderApp.");
  }
  const importedShellURLs = matchingAssetURLs(importedPaths, shellPathPattern, renderAppURL);
  if (importedShellURLs.length !== 1) {
    throw new Error("Could not resolve one unambiguous shell import from renderApp.");
  }
  return importedShellURLs[0];
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

function createController({ commandQueue, eventsURL, sessionService, workspaceService }) {
  let eventSource;
  let isRetired = false;

  // EventSource reconnects itself; SQLite observation replaces a browser result channel.
  const controller = {
    open() {
      if (isRetired || eventSource) return;

      eventSource = new EventSource(eventsURL);
      eventSource.onopen = () => {
        if (!isRetired) console.info("Conductor Mobile Workspace UI Hook connected.");
      };
      eventSource.onmessage = (event) => {
        if (isRetired) return;

        let command;
        try {
          command = parseCommand(event.data);
        } catch (error) {
          console.error(
            "Conductor Mobile received an invalid workspace command.",
            error,
          );
          return;
        }

        commandQueue.tail = commandQueue.tail
          .then(() => executeCommand({ sessionService, workspaceService }, command))
          .catch((error) => {
            console.error(
              "Conductor Mobile workspace mutation failed.",
              error,
            );
          });
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

// TODO: No clue why this is necessary
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
        // Repeat this idempotent call because Conductor may suppress the first unread write.
        await sessionService.setUnread(activeSession.id, true);
        await sessionService.setUnread(activeSession.id, true);
        return;
      }
  }
}
