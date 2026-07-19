import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import test from "node:test";

const controllerKey = "__conductorMobileWorkspaceUIHookController";
const commandQueueKey = "__conductorMobileWorkspaceUIHookCommandQueue";
const testGlobals = [
  "window",
  "top",
  "document",
  "location",
  "performance",
  "EventSource",
  "fetch",
  "console",
  controllerKey,
  commandQueueKey,
  "__workspaceHookImport",
  "__workspaceHookImportShell",
];

isolatedTest("loader reports the original connection error", async () => {
  const errors = [];
  const connectionError = new Error("Connection refused.");
  defineGlobal("console", { error: (...arguments_) => errors.push(arguments_) });
  defineGlobal("fetch", async () => new Response("", {
    headers: { ETag: '"revision-1"' },
    status: 200,
  }));
  defineGlobal("__workspaceHookImport", async () => { throw connectionError; });
  const source = await fs.readFile(new URL("./bootstrap-loader.js", import.meta.url), "utf8");
  Function(source
    .replace("import(hookURL.href)", "globalThis.__workspaceHookImport(hookURL.href)"))();

  await waitUntil(() => errors.length === 1);
  assert.deepEqual(errors, [[
    "Conductor Mobile could not connect the Workspace UI Hook.",
    connectionError,
  ]]);
});

isolatedTest("discovery follows renderApp and replaces the installed controller", async () => {
  const environment = installHookGlobals({
    resources: ["/assets/shell-unrelated.js"],
    modulePreloads: [
      "/assets/shell-unrelated.js",
      "/assets/renderApp-main.js",
      "https://example.com/assets/renderApp-malicious.js",
    ],
    shell: emptyWorkspaceShell(),
  });
  const firstController = await prepareHook();
  const firstEventSource = environment.eventSources[0];
  firstEventSource.onopen();
  assert.equal(globalThis[controllerKey], firstController);
  assert.equal(firstEventSource.closeCount, 0);
  assert.deepEqual(environment.infos, [["CONDUCTOR MOBILE: CONNECTED"]]);

  const secondController = await prepareHook();
  const secondEventSource = environment.eventSources[1];
  assert.equal(globalThis[controllerKey], secondController);
  assert.equal(firstEventSource.closeCount, 1);
  assert.deepEqual(environment.fetches, [
    ["tauri://localhost/assets/renderApp-main.js", { cache: "no-store" }],
    ["tauri://localhost/assets/renderApp-main.js", { cache: "no-store" }],
  ]);
  assert.deepEqual(environment.importedShellURLs, [
    "tauri://localhost/assets/shell-main.js",
    "tauri://localhost/assets/shell-main.js",
  ]);
  assert.equal(environment.eventSources.length, 2);
  assert.equal(
    secondEventSource.url,
    "http://127.0.0.1:3769/workspace-ui-hook/events?revision=%22revision-1%22",
  );
});

isolatedTest("a stale hook imports and prepares the latest served revision", async () => {
  const environment = installHookGlobals({ shell: emptyWorkspaceShell() });
  await prepareHook();

  environment.eventSources[0].onerror();
  await waitUntil(() => environment.fetches.length === 2);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(environment.importedHookURLs.length, 0);

  environment.hookRevision = '"revision-2"';

  environment.eventSources[0].onerror();
  await waitUntil(() => environment.importedHookURLs.length === 1);

  assert.equal(
    environment.importedHookURLs[0],
    "http://127.0.0.1:3769/workspace-ui-hook/hook.js?revision=%22revision-2%22",
  );
  assert.equal(environment.preparedHookUpdates, 1);
});

isolatedTest("renderApp requires one narrow direct shell import", async () => {
  const environment = installHookGlobals({
    resources: [
      "/assets/shell-old.js",
      "/assets/shell-other.js",
      "/assets/renderApp-current.js",
      "tauri://localhost/assets/renderApp-current.js#duplicate",
    ],
    renderAppSource: `
        const stringExample = 'import "./shell-string.js"';
        const dynamicImport = import("./shell-dynamic.js");
        runtime.import
        export { workspace } from "./shell-export.js";
        important from "./shell-important.js";
        imported from "./shell-imported.js";
        import.meta.resolve("./shell-meta.js");
        import "/assets/shell-absolute.js";
        import{workspace}from"./shell-current.js";
      `,
    shell: emptyWorkspaceShell(),
  });
  await prepareHook();
  assert.equal(environment.fetches.length, 1);
  assert.deepEqual(environment.importedShellURLs, [
    "tauri://localhost/assets/shell-current.js",
  ]);
  assert.equal(environment.eventSources.length, 1);
});

isolatedTest("renderApp rejects ambiguous direct shell imports", async () => {
  installHookGlobals({
    renderAppSource: 'import { a } from "./shell-one.js";import { b } from "./shell-two.js";',
    shell: emptyWorkspaceShell(),
  });
  await assert.rejects(prepareHook(), /unambiguous shell import/);
});

isolatedTest("hook discovery requires the top frame and exact Conductor asset origin", async () => {
  installHookGlobals({ shell: emptyWorkspaceShell() });

  defineGlobal("window", { top: {} });
  await assert.rejects(prepareHook(), /top frame/);

  defineGlobal("window", globalThis);
  defineGlobal("location", { href: "https://example.com/", origin: "https://example.com" });
  await assert.rejects(prepareHook(), /Unexpected Conductor origin/);

  defineGlobal("location", { href: "tauri://localhost/", origin: "tauri://localhost" });
  defineGlobal("performance", {
    getEntriesByType: () => [{ name: "https://example.com/assets/renderApp-main.js" }],
  });
  await assert.rejects(prepareHook(), /unambiguous Conductor renderApp module/);

  defineGlobal("performance", {
    getEntriesByType: () => [{ name: "tauri://localhost/other/renderApp-main.js" }],
  });
  await assert.rejects(prepareHook(), /unambiguous Conductor renderApp module/);
});

isolatedTest("failed candidates preserve the installed controller", async () => {
  const environment = installHookGlobals({ shell: emptyWorkspaceShell() });
  const installedController = await prepareHook();

  const { messageProcessingController, sessionService, workspaceService } = emptyWorkspaceShell();
  environment.shell = {
    messageProcessingController,
    sessionService,
    workspaceService,
    workspaceAlias: emptyWorkspaceShell().workspaceService,
  };
  await assert.rejects(prepareHook(), /unambiguous WorkspaceService/);
  assert.equal(globalThis[controllerKey], installedController);
  assert.equal(environment.eventSources.length, 1);
  assert.equal(environment.eventSources[0].closeCount, 0);
});

isolatedTest("missing or duplicate Git, session, and message controllers preserve the installed hook", async () => {
  const environment = installHookGlobals({ shell: emptyWorkspaceShell() });
  const installedController = await prepareHook();
  const shell = emptyWorkspaceShell();

  environment.shell = {
    messageProcessingController: shell.messageProcessingController,
    sessionService: shell.sessionService,
    workspaceService: shell.workspaceService,
  };
  await assert.rejects(prepareHook(), /unambiguous GitService/);

  environment.shell = {
    ...shell,
    gitAlias: emptyWorkspaceShell().gitService,
  };
  await assert.rejects(prepareHook(), /unambiguous GitService/);

  environment.shell = {
    gitService: shell.gitService,
    messageProcessingController: shell.messageProcessingController,
    workspaceService: shell.workspaceService,
  };
  await assert.rejects(prepareHook(), /unambiguous SessionService/);

  environment.shell = {
    ...shell,
    sessionAlias: emptyWorkspaceShell().sessionService,
  };
  await assert.rejects(prepareHook(), /unambiguous SessionService/);

  environment.shell = {
    gitService: shell.gitService,
    sessionService: shell.sessionService,
    workspaceService: shell.workspaceService,
  };
  await assert.rejects(prepareHook(), /unambiguous MessageProcessingController/);

  environment.shell = {
    ...shell,
    messageControllerAlias: emptyWorkspaceShell().messageProcessingController,
  };
  await assert.rejects(prepareHook(), /unambiguous MessageProcessingController/);

  assert.equal(globalThis[controllerKey], installedController);
  assert.equal(environment.eventSources.length, 1);
  assert.equal(environment.eventSources[0].closeCount, 0);
});

isolatedTest("commands run in order with real service signatures and continue after failure", async () => {
  const pinGate = deferred();
  const calls = [];
  const persistedUnreadSessionIDs = [];
  const gitService = {
    async refreshLocalBranch() {},
    async refreshWorkspaceChanges() {},
    async renameBranch(input) {
      calls.push(["branch", input]);
    },
  };
  const workspaceService = {
    async archiveWorkspace(input) {
      calls.push(["archive", input]);
    },
    async createWorkspaceWithSetup(input) {
      input.onCreation();
    },
    async getWorkspaces() {
      calls.push("workspaces");
      return [{ id: "workspace-1", activeSessionId: "session-1" }];
    },
    async markUserSetBranchName(workspaceID) {
      calls.push(["userSetBranch", workspaceID]);
    },
    async setWorkspacePinned(input) {
      calls.push(["pin", input]);
      await pinGate.promise;
    },
    async setWorkspaceManualStatus(input) {
      calls.push(["status", input]);
      throw new Error("Setter failed.");
    },
  };
  const sessionService = {
    async createSession(input) {
      calls.push(["createSession", input]);
    },
    async getSessionsForWorkspace(input) {
      calls.push(["sessions", input]);
      return [{ id: "session-1" }];
    },
    async setUnread(sessionID, isUnread) {
      calls.push(["unread", sessionID, isUnread]);
      if (calls.filter((call) => call[0] === "unread").length === 2) {
        persistedUnreadSessionIDs.push(sessionID);
      }
    },
    async markWorkspaceAsRead(workspaceID) {
      calls.push(["read", workspaceID]);
    },
    async updateSessionFastMode(input) {
      calls.push(["fastMode", input]);
    },
    async setSessionAgentAndModel(sessionID, agentType, model) {
      calls.push(["agentAndModel", sessionID, agentType, model]);
    },
    async updateSessionModel(sessionID, model) {
      calls.push(["model", sessionID, model]);
    },
  };
  const { messageProcessingController } = emptyWorkspaceShell();
  const environment = installHookGlobals({
    shell: { gitService, messageProcessingController, workspaceService, sessionService },
  });
  await prepareHook();
  const source = environment.eventSources[0];

  source.onmessage(command({ pinned: true }));
  await waitUntil(() => calls.length === 1);
  assert.deepEqual(calls, [["pin", { workspaceId: "workspace-1", pinned: true }]]);

  await prepareHook();
  const replacementSource = environment.eventSources[1];
  replacementSource.onmessage(command({ status: "in-review" }));
  replacementSource.onmessage(command({ unread: true }));
  replacementSource.onmessage(command({ unread: false }));
  replacementSource.onmessage(sessionCommand({ model: "gpt-5.6-terra" }));
  replacementSource.onmessage(command({ createSession: true }));
  replacementSource.onmessage(command({ archive: true }));
  replacementSource.onmessage(command({ branch: "renamed-branch" }));
  replacementSource.onmessage(sessionCommand({
    agentAndModel: { agentType: "claude", model: "fable-5" },
  }));
  replacementSource.onmessage(command({ futureCommand: true }));
  replacementSource.onmessage(sessionCommand({ fastMode: true }));
  replacementSource.onmessage(command({ pinned: true, unread: false }));
  replacementSource.onmessage({ data: JSON.stringify({ id: "obsolete", workspaceId: "workspace-1", pinned: true }) });
  replacementSource.onmessage({ data: "not json" });
  assert.equal(calls.length, 1);
  assert.equal(environment.errors.length, 3);

  pinGate.resolve();
  await waitUntil(() => calls.length === 14);
  await waitUntil(() => environment.errors.length === 5);
  assert.deepEqual(calls, [
    ["pin", { workspaceId: "workspace-1", pinned: true }],
    ["status", { workspaceId: "workspace-1", status: "in-review" }],
    "workspaces",
    ["sessions", { workspaceId: "workspace-1", hidden: false }],
    ["unread", "session-1", true],
    ["unread", "session-1", true],
    ["read", "workspace-1"],
    ["model", "session-1", "gpt-5.6-terra"],
    ["createSession", { workspaceId: "workspace-1" }],
    ["archive", { workspaceId: "workspace-1" }],
    ["branch", {
      workspaceId: "workspace-1",
      branchName: "renamed-branch",
      autoRenameWorkspace: false,
    }],
    ["userSetBranch", "workspace-1"],
    ["agentAndModel", "session-1", "claude", "fable-5"],
    ["fastMode", { sessionId: "session-1", fastMode: true }],
  ]);
  assert.deepEqual(persistedUnreadSessionIDs, ["session-1"]);
  assert.equal(environment.errors.at(-1)[1].message, "Unsupported workspace command: futureCommand");
  assert.equal(environment.fetches.length, 2);
});

isolatedTest("message commands call the explicit controller modes and report results", async () => {
  const calls = [];
  const shell = emptyWorkspaceShell();
  const session = { id: "session-1", title: "Session" };
  shell.sessionService.getSessionsForWorkspace = async (input) => {
    calls.push(["sessions", input]);
    return [session];
  };
  shell.messageProcessingController.sendMessageImmediately = async (...arguments_) => {
    calls.push(["sent", arguments_]);
  };
  shell.messageProcessingController.enqueueMessage = async (...arguments_) => {
    calls.push(["queued", arguments_]);
    throw new Error("Rejected.");
  };
  const environment = installHookGlobals({ shell });
  await prepareHook();
  const source = environment.eventSources[0];

  source.onmessage(messageCommand({
    requestId: "request-1",
    content: "Run the tests.",
    mode: "sent",
  }));
  await waitUntil(() => environment.commandResults.length === 1);
  assert.deepEqual(calls[0], [
    "sessions",
    { workspaceId: "workspace-1", hidden: false },
  ]);
  assert.deepEqual(calls[1], [
    "sent",
    [{
      session,
      message: "Run the tests.",
      workspaceId: "workspace-1",
      includeAttachments: false,
    }],
  ]);
  assert.deepEqual(environment.commandResults[0], {
    requestId: "request-1",
  });

  source.onmessage(messageCommand({
    requestId: "request-2",
    content: "Fail.",
    mode: "queued",
  }));
  await waitUntil(() => environment.commandResults.length === 2);
  await waitUntil(() => environment.errors.length === 1);
  assert.deepEqual(calls[2], [
    "sessions",
    { workspaceId: "workspace-1", hidden: false },
  ]);
  assert.deepEqual(calls[3], [
    "queued",
    [{
      session,
      message: "Fail.",
      workspaceId: "workspace-1",
      includeAttachments: false,
      sendMode: "queued",
    }],
  ]);
  assert.deepEqual(environment.commandResults[1], {
    requestId: "request-2",
    error: "Rejected.",
  });
  assert.equal(environment.errors[0][1].message, "Rejected.");
});

isolatedTest("command result reporting retries without executing twice", async () => {
  const calls = [];
  const shell = emptyWorkspaceShell();
  shell.sessionService.getSessionsForWorkspace = async () => [{ id: "session-1" }];
  shell.messageProcessingController.sendMessageImmediately = async (...arguments_) => {
    calls.push(arguments_);
  };
  const environment = installHookGlobals({ shell });
  environment.commandResultFailures = 1;
  await prepareHook();

  environment.eventSources[0].onmessage(messageCommand({
    requestId: "request-1",
    content: "Run the tests.",
    mode: "sent",
  }));

  await waitUntil(() => environment.commandResultAttempts.length === 2);
  assert.equal(calls.length, 1);
  assert.equal(environment.commandResults.length, 1);
});

isolatedTest("stop commands cancel the exact session and report success or errors", async () => {
  const sessionIDs = [];
  const shell = emptyWorkspaceShell();
  shell.messageProcessingController.cancelSession = async (sessionID) => {
    sessionIDs.push(sessionID);
    if (sessionID === "session-2") throw new Error("Cannot stop.");
  };
  const environment = installHookGlobals({ shell });
  await prepareHook();
  const source = environment.eventSources[0];

  source.onmessage(stopCommand({ requestId: "request-1", sessionId: "session-1" }));
  await waitUntil(() => environment.commandResults.length === 1);
  assert.deepEqual(environment.commandResults[0], { requestId: "request-1" });

  source.onmessage(stopCommand({ requestId: "request-2", sessionId: "session-2" }));
  await waitUntil(() => environment.commandResults.length === 2);
  assert.deepEqual(environment.commandResults[1], {
    requestId: "request-2",
    error: "Cannot stop.",
  });
  assert.deepEqual(sessionIDs, ["session-1", "session-2"]);
});

isolatedTest("message sends bypass a blocked workspace command", async () => {
  const pinGate = deferred();
  const calls = [];
  const shell = emptyWorkspaceShell();
  shell.workspaceService.setWorkspacePinned = async () => {
    calls.push("pin");
    await pinGate.promise;
  };
  shell.sessionService.getSessionsForWorkspace = async () => [{ id: "session-1" }];
  shell.messageProcessingController.sendMessageImmediately = async () => {
    calls.push("message");
    return { messageId: "message-1", state: "sent" };
  };
  const environment = installHookGlobals({ shell });
  await prepareHook();

  environment.eventSources[0].onmessage(command({ pinned: true }));
  await waitUntil(() => calls.length === 1);
  environment.eventSources[0].onmessage(messageCommand({
    requestId: "request-1",
    content: "Run the tests.",
    mode: "sent",
  }));

  await waitUntil(() => calls.length === 2);
  assert.deepEqual(calls, ["pin", "message"]);
  await waitUntil(() => environment.commandResults.length === 1);
  pinGate.resolve();
});

isolatedTest("workspace creation resolves when Conductor publishes the workspace", async () => {
  const shell = emptyWorkspaceShell();
  const creation = deferred();
  shell.workspaceService.createWorkspaceWithSetup = async (input) => {
    creation.resolve(input);
    input.onCreation({ id: input.workspaceId });
  };
  const environment = installHookGlobals({ shell });
  await prepareHook();

  environment.eventSources[0].onmessage({
    data: JSON.stringify({
      createWorkspace: {
        agentType: "codex",
        model: "gpt-5.6-sol",
        repositoryId: "repository-1",
        workspaceId: "workspace-1",
      },
    }),
  });

  const input = await creation.promise;
  assert.equal(typeof input.onCreation, "function");
  assert.deepEqual(
    {
      agentType: input.agentType,
      model: input.model,
      repositoryId: input.repositoryId,
      workspaceId: input.workspaceId,
    },
    {
      agentType: "codex",
      model: "gpt-5.6-sol",
      repositoryId: "repository-1",
      workspaceId: "workspace-1",
    },
  );
});

const browserHookSource = fs.readFile(new URL("./browser-hook.mjs", import.meta.url), "utf8")
  .then((source) => source
    .replace(
      "const moduleURL = new URL(import.meta.url);",
      'const moduleURL = new URL("http://127.0.0.1:3769/workspace-ui-hook/hook.js?revision=%22revision-1%22");',
    )
    .replace(
      "const shell = await import(shellURL);",
      "const shell = await globalThis.__workspaceHookImportShell(shellURL);",
    )
    .replace(
      "const module = await import(latestHookURL.href);",
      "const module = await globalThis.__workspaceHookImport(latestHookURL.href);",
    ));

function prepareHook() {
  const moduleID = crypto.randomUUID();
  return browserHookSource
    .then((source) => import(
      `data:text/javascript;base64,${Buffer.from(source).toString("base64")}#${moduleID}`,
    ))
    .then((module) => module.prepareWorkspaceUIHook());
}

function installHookGlobals({
  modulePreloads = [],
  renderAppSource = 'import "./shell-main.js";',
  resources = ["tauri://localhost/assets/renderApp-main.js"],
  shell,
}) {
  const environment = {
    errors: [],
    eventSources: [],
    fetches: [],
    hookRevision: '"revision-1"',
    importedHookURLs: [],
    importedShellURLs: [],
    infos: [],
    commandResultAttempts: [],
    commandResultFailures: 0,
    commandResults: [],
    preparedHookUpdates: 0,
    shell,
  };
  defineGlobal("window", globalThis);
  defineGlobal("top", globalThis);
  defineGlobal("document", {
    querySelectorAll: () => modulePreloads.map((href) => ({
      href: new URL(href, globalThis.location.href).href,
    })),
  });
  defineGlobal("location", { href: "tauri://localhost/", origin: "tauri://localhost" });
  defineGlobal("performance", { getEntriesByType: () => resources.map((name) => ({ name })) });
  defineGlobal("console", {
    error: (...arguments_) => environment.errors.push(arguments_),
    info: (...arguments_) => environment.infos.push(arguments_),
    warn: () => {},
  });
  class FakeEventSource {
    constructor(url) {
      this.closeCount = 0;
      this.url = String(url);
      environment.eventSources.push(this);
    }

    close() {
      this.closeCount += 1;
    }
  }
  defineGlobal("EventSource", FakeEventSource);
  defineGlobal("__workspaceHookImportShell", async (url) => {
    environment.importedShellURLs.push(String(url));
    return environment.shell;
  });
  defineGlobal("__workspaceHookImport", async (url) => {
    environment.importedHookURLs.push(String(url));
    return {
      async prepareWorkspaceUIHook() {
        environment.preparedHookUpdates += 1;
      },
    };
  });
  defineGlobal("fetch", async (url, options = {}) => {
    environment.fetches.push([String(url), options]);
    if (String(url).endsWith("/workspace-ui-hook/command-result")) {
      const result = JSON.parse(options.body);
      environment.commandResultAttempts.push(result);
      if (environment.commandResultFailures > 0) {
        environment.commandResultFailures -= 1;
        throw new Error("Connection lost.");
      }
      environment.commandResults.push(result);
      return new Response(null, { status: 204 });
    }
    if (String(url).startsWith("http://127.0.0.1:3769/workspace-ui-hook/hook.js")) {
      return new Response("", {
        headers: { ETag: environment.hookRevision },
        status: 200,
      });
    }
    return new Response(renderAppSource, { status: 200 });
  });
  delete globalThis[controllerKey];
  return environment;
}

function emptyWorkspaceShell() {
  const gitService = {
    async refreshLocalBranch() {},
    async refreshWorkspaceChanges() {},
    async renameBranch() {},
  };
  const workspaceService = {
    async archiveWorkspace() {},
    async createWorkspaceWithSetup(input) { input.onCreation(); },
    async getWorkspaces() { return []; },
    async markUserSetBranchName() {},
    async setWorkspacePinned() {},
    async setWorkspaceManualStatus() {},
  };
  const sessionService = {
    async createSession() {},
    async getSessionsForWorkspace() { return []; },
    async setSessionAgentAndModel() {},
    async setUnread() {},
    async markWorkspaceAsRead() {},
    async updateSessionFastMode() {},
    async updateSessionModel() {},
  };
  const messageProcessingController = {
    async cancelSession() {},
    async enqueueMessage() {},
    async sendMessageImmediately() {},
  };
  return { gitService, messageProcessingController, workspaceService, sessionService };
}

function command(mutation) {
  return { data: JSON.stringify({ workspaceId: "workspace-1", ...mutation }) };
}

function sessionCommand(mutation) {
  return { data: JSON.stringify({ sessionId: "session-1", ...mutation }) };
}

function messageCommand({ requestId, ...sendMessage }) {
  return {
    data: JSON.stringify({
      requestId,
      sessionId: "session-1",
      workspaceId: "workspace-1",
      sendMessage,
    }),
  };
}

function stopCommand({ requestId, sessionId }) {
  return {
    data: JSON.stringify({ requestId, sessionId, stopSession: true }),
  };
}

function isolatedTest(name, operation) {
  test(name, async () => {
    const restore = preserveGlobals(testGlobals);
    try {
      await operation();
    } finally {
      globalThis[controllerKey]?.retire?.();
      restore();
    }
  });
}

function preserveGlobals(names) {
  const descriptors = new Map(
    names.map((name) => [name, Object.getOwnPropertyDescriptor(globalThis, name)]),
  );
  return () => {
    for (const [name, descriptor] of descriptors) {
      if (descriptor) {
        Object.defineProperty(globalThis, name, descriptor);
      } else {
        delete globalThis[name];
      }
    }
  };
}

function defineGlobal(name, value) {
  Object.defineProperty(globalThis, name, { configurable: true, value, writable: true });
}

function deferred() {
  let resolve;
  const promise = new Promise((promiseResolve) => {
    resolve = promiseResolve;
  });
  return { promise, resolve };
}

async function waitUntil(predicate, timeoutMilliseconds = 1_000) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for condition.");
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
}
