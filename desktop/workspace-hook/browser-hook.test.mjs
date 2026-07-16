import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import test from "node:test";

const loaderGenerationKey = "__conductorMobileWorkspaceUIHookLoaderRun";
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
  loaderGenerationKey,
  controllerKey,
  commandQueueKey,
  "__workspaceHookImport",
  "__workspaceHookImportShell",
];

isolatedTest("loader reports the original connection error", async () => {
  const errors = [];
  const connectionError = new Error("Connection refused.");
  defineGlobal("console", { error: (...arguments_) => errors.push(arguments_) });
  defineGlobal("__workspaceHookImport", async () => { throw connectionError; });
  const source = await fs.readFile(new URL("./bootstrap-loader.js", import.meta.url), "utf8");
  Function(source
    .replace("import(hookURL.href)", "globalThis.__workspaceHookImport(hookURL.href)"))();

  await waitUntil(() => errors.length === 1);
  assert.deepEqual(errors, [[
    "Conductor Mobile could not connect the Workspace UI Hook. Run the saved Conductor Mobile snippet again.",
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
  assert.equal(globalThis[controllerKey], firstController);
  assert.equal(firstEventSource.closeCount, 0);

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
    "http://127.0.0.1:3769/workspace-ui-hook/events",
  );
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

isolatedTest("stale and failed candidates preserve the installed controller", async () => {
  const oldShellImport = deferred();
  const environment = installHookGlobals({ shell: oldShellImport.promise });
  const olderPreparation = prepareHook();
  await waitUntil(() => environment.importedShellURLs.length === 1);

  environment.shell = emptyWorkspaceShell();
  const installedController = await prepareHook();
  oldShellImport.resolve(emptyWorkspaceShell());
  assert.equal(await olderPreparation, undefined);
  assert.equal(globalThis[controllerKey], installedController);

  const { sessionService, workspaceService } = emptyWorkspaceShell();
  environment.shell = {
    sessionService,
    workspaceService,
    workspaceAlias: emptyWorkspaceShell().workspaceService,
  };
  await assert.rejects(prepareHook(), /unambiguous WorkspaceService/);
  assert.equal(globalThis[controllerKey], installedController);
  assert.equal(environment.eventSources.length, 1);
  assert.equal(environment.eventSources[0].closeCount, 0);
});

isolatedTest("commands run in order with real service signatures and continue after failure", async () => {
  const pinGate = deferred();
  const calls = [];
  const persistedUnreadSessionIDs = [];
  const workspaceService = {
    async getWorkspaces() {
      calls.push("workspaces");
      return [{ id: "workspace-1", activeSessionId: "session-1" }];
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
  };
  const environment = installHookGlobals({ shell: { workspaceService, sessionService } });
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
  replacementSource.onmessage(command({ pinned: true, unread: false }));
  replacementSource.onmessage({ data: JSON.stringify({ id: "obsolete", workspaceId: "workspace-1", pinned: true }) });
  replacementSource.onmessage({ data: "not json" });
  assert.equal(calls.length, 1);
  assert.equal(environment.errors.length, 3);

  pinGate.resolve();
  await waitUntil(() => calls.length === 7);
  assert.deepEqual(calls, [
    ["pin", { workspaceId: "workspace-1", pinned: true }],
    ["status", { workspaceId: "workspace-1", status: "in-review" }],
    "workspaces",
    ["sessions", { workspaceId: "workspace-1", hidden: false }],
    ["unread", "session-1", true],
    ["unread", "session-1", true],
    ["read", "workspace-1"],
  ]);
  assert.deepEqual(persistedUnreadSessionIDs, ["session-1"]);
  assert.equal(environment.errors.at(-1)[1].message, "Setter failed.");
  assert.equal(environment.fetches.length, 2);
});

const browserHookSource = fs.readFile(new URL("./browser-hook.mjs", import.meta.url), "utf8")
  .then((source) => source
    .replace(
      'const hookBaseURL = new URL("./", moduleURL);',
      'const hookBaseURL = new URL("http://127.0.0.1:3769/workspace-ui-hook/");',
    )
    .replace(
      "const shell = await import(shellURL);",
      "const shell = await globalThis.__workspaceHookImportShell(shellURL);",
    ));

function prepareHook() {
  const generation = crypto.randomUUID();
  defineGlobal(loaderGenerationKey, generation);
  return browserHookSource
    .then((source) => import(
      `data:text/javascript;base64,${Buffer.from(source).toString("base64")}#${generation}`,
    ))
    .then((module) => module.prepareWorkspaceUIHook(generation));
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
    importedShellURLs: [],
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
    info() {},
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
  defineGlobal("fetch", async (url, options = {}) => {
    environment.fetches.push([String(url), options]);
    return new Response(renderAppSource, { status: 200 });
  });
  delete globalThis[controllerKey];
  return environment;
}

function emptyWorkspaceShell() {
  const workspaceService = {
    async getWorkspaces() { return []; },
    async setWorkspacePinned() {},
    async setWorkspaceManualStatus() {},
  };
  const sessionService = {
    async getSessionsForWorkspace() { return []; },
    async setUnread() {},
    async markWorkspaceAsRead() {},
  };
  return { workspaceService, sessionService };
}

function command(mutation) {
  return { data: JSON.stringify({ workspaceId: "workspace-1", ...mutation }) };
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
