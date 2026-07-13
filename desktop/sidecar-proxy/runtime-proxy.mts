#!/usr/bin/env node

import { randomUUID } from "node:crypto";
import { spawn, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as http from "node:http";
import type { IncomingMessage, Server as HttpServer, ServerResponse } from "node:http";
import * as net from "node:net";
import type { Server as NetServer, Socket } from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { pathToFileURL } from "node:url";

const BRIDGE_MARKER = "FAKE_CONDUCTOR_BRIDGE_MARKER;v0.1";

type JsonObject = Record<string, unknown>;

interface PendingResponse {
  response: ServerResponse;
  timer: ReturnType<typeof setTimeout>;
}

interface ProxyContext {
  realRuntime: string;
  realArgs: string[];
  tmpDir: string;
  env: NodeJS.ProcessEnv;
  publicSocketPath: string;
  infoPath: string;
  logPath: string;
  child: ChildProcess | null;
  activeClient: Socket | null;
  activeSidecar: Socket | null;
  sidecarBuffer: string;
  realStdoutBuffer: string;
  controlUrl: string | null;
  pending: Map<string, PendingResponse>;
  realSocketPath: string | null;
}

interface MessageInput {
  sessionId?: unknown;
  workspaceId?: unknown;
  cwd?: unknown;
  message?: unknown;
  agentType?: unknown;
  model?: unknown;
  messageId?: unknown;
  rpcId?: unknown;
  prompt?: unknown;
  turnId?: unknown;
  permissionMode?: unknown;
  fastMode?: unknown;
  deliveryMode?: unknown;
  agentParams?: unknown;
  modelReasoningEffort?: unknown;
  personality?: unknown;
}

interface StopInput {
  agentType?: unknown;
  sessionId?: unknown;
}

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: string;
  method: "cancel" | "query";
  params: JsonObject;
}

interface InjectedHttpResponse {
  status: number;
  payload: unknown;
}

function main(): void {
  const context = createContext(process.argv.slice(2), process.env);

  prepareInfoFiles(context);
  startRealRuntime(context);

  const controlServer = createControlServer(context);
  const proxyServer = createProxyServer(context);

  installSignalHandlers(context);
  advertiseProxySocket(context);
  listen(context, proxyServer, controlServer);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}

function createContext(args: string[], env: NodeJS.ProcessEnv): ProxyContext {
  const [realRuntime, ...realArgs] = args;
  if (!realRuntime) {
    console.error("usage: runtime-proxy.mjs <conductor-runtime.real> [args...]");
    process.exit(127);
  }

  const tmpDir = os.tmpdir();

  return {
    realRuntime,
    realArgs,
    tmpDir,
    env,
    publicSocketPath: path.join(tmpDir, `conductor-sidecar-v2-${process.pid}.sock`),
    infoPath:
      env.CONDUCTOR_MOBILE_BRIDGE_INFO_PATH ||
      path.join(os.homedir(), "conductor-sidecar-mitm-info.json"),
    logPath:
      env.CONDUCTOR_MOBILE_BRIDGE_LOG_PATH ||
      path.join(os.homedir(), "conductor-sidecar-mitm.jsonl"),
    child: null,
    activeClient: null,
    activeSidecar: null,
    sidecarBuffer: "",
    realStdoutBuffer: "",
    controlUrl: null,
    pending: new Map(),
    realSocketPath: null,
  };
}

function prepareInfoFiles(context: ProxyContext): void {
  fs.mkdirSync(path.dirname(context.infoPath), { recursive: true });
  fs.mkdirSync(path.dirname(context.logPath), { recursive: true });
}

function startRealRuntime(context: ProxyContext): void {
  context.child = spawn(context.realRuntime, context.realArgs, {
    env: context.env,
    stdio: ["ignore", "pipe", "pipe"],
  });

  context.realSocketPath = path.join(
    context.tmpDir,
    `conductor-sidecar-v2-${context.child.pid}.sock`,
  );

  if (!context.child.stdout || !context.child.stderr) {
    throw new Error("Expected real runtime stdout/stderr pipes");
  }

  context.child.stdout.on("data", (chunk: Buffer) => handleRealStdoutData(context, chunk));
  context.child.stderr.on("data", (chunk: Buffer) => handleRealStderrData(context, chunk));
  context.child.on("exit", (code, signal) => handleRealRuntimeExit(context, code, signal));
}

function createControlServer(context: ProxyContext): HttpServer {
  return http.createServer((request, response) => {
    routeControlRequest(context, request, response);
  });
}

function createProxyServer(context: ProxyContext): NetServer {
  unlinkIfExists(context.publicSocketPath);

  return net.createServer((client) => {
    attachClient(context, client).catch((error: unknown) => {
      log(context, "attach_error", { error: errorMessage(error) });
      client.destroy(asError(error));
    });
  });
}

function listen(context: ProxyContext, proxyServer: NetServer, controlServer: HttpServer): void {
  proxyServer.listen(context.publicSocketPath, () => {
    controlServer.listen(49321, "127.0.0.1", () => {
      const control = controlServer.address();
      if (!control || typeof control === "string") {
        throw new Error("Expected HTTP control server to listen on a TCP address");
      }

      context.controlUrl = `http://127.0.0.1:${control.port}`;
      writeInfo(context);
      log(context, "proxy_ready", {
        publicSocketPath: context.publicSocketPath,
        realSocketPath: context.realSocketPath,
        controlUrl: context.controlUrl,
      });
    });
  });
}

function installSignalHandlers(context: ProxyContext): void {
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => {
      log(context, "signal", { signal });
      context.child?.kill(signal);
      cleanup(context, { signal });
      process.exit(0);
    });
  }
}

function advertiseProxySocket(context: ProxyContext): void {
  waitForFile(requireRealSocketPath(context), 10_000)
    .then(() => {
      // Conductor reads SOCKET_PATH from stdout; advertise this proxy instead of the real socket.
      process.stdout.write(`SOCKET_PATH=${context.publicSocketPath}\n`);
      writeInfo(context, { advertised: true });
      log(context, "proxy_advertised", {
        publicSocketPath: context.publicSocketPath,
        realSocketPath: context.realSocketPath,
      });
    })
    .catch((error: unknown) => {
      log(context, "proxy_advertise_failed", { error: errorMessage(error) });
    });
}

function handleRealStdoutData(context: ProxyContext, chunk: Buffer | string): void {
  context.realStdoutBuffer += chunk.toString();
  const lines = context.realStdoutBuffer.split("\n");
  context.realStdoutBuffer = lines.pop() || "";

  for (const line of lines) {
    if (line.startsWith("SOCKET_PATH=")) {
      // Letting Conductor see the real socket would bypass this proxy.
      log(context, "real_stdout_socket_path_suppressed", {
        replacement: context.publicSocketPath,
      });
      continue;
    }

    process.stdout.write(`${line}\n`);
    log(context, "real_stdout", { text: `${line}\n` });
  }
}

function handleRealStderrData(context: ProxyContext, chunk: Buffer | string): void {
  process.stderr.write(chunk);
  log(context, "real_stderr", { text: chunk.toString() });
}

function handleRealRuntimeExit(
  context: ProxyContext,
  code: number | null,
  signal: NodeJS.Signals | null,
): void {
  log(context, "real_exit", { code, signal });
  cleanup(context, { code, signal });
  process.exit(code ?? (signal ? 1 : 0));
}

function routeControlRequest(
  context: ProxyContext,
  request: IncomingMessage,
  response: ServerResponse,
): void {
  if (request.method === "GET" && request.url === "/status") {
    writeInfo(context);
    response.writeHead(200, { "content-type": "application/json" });
    response.end(fs.readFileSync(context.infoPath));
    return;
  }

  if (request.method === "POST" && request.url === "/message") {
    readJsonBody<MessageInput>(request, response, (body) => {
      injectRequest(context, body, response, buildQueryRequest);
    });
    return;
  }

  if (request.method === "POST" && request.url === "/stop") {
    readJsonBody<StopInput>(request, response, (body) => {
      injectRequest(context, body, response, buildCancelRequest);
    });
    return;
  }

  writeJson(response, 404, { error: "Not found" });
}

async function attachClient(context: ProxyContext, client: Socket): Promise<void> {
  log(context, "client_connect");
  context.activeClient?.destroy();
  context.activeClient = client;
  writeInfo(context);

  let realSocketPath: string;
  try {
    realSocketPath = requireRealSocketPath(context);
    await waitForFile(realSocketPath);
  } catch (error: unknown) {
    log(context, "real_socket_missing", { error: errorMessage(error) });
    client.destroy(asError(error));
    return;
  }

  const sidecar = net.createConnection(realSocketPath);
  context.activeSidecar = sidecar;
  context.sidecarBuffer = "";
  writeInfo(context);

  client.on("data", (chunk: Buffer) => forwardClientData(context, chunk));
  sidecar.on("data", (chunk: Buffer) => handleSidecarData(context, chunk));
  client.on("close", () => closeConnectionPair(context, client, sidecar, "client"));
  sidecar.on("close", () => closeConnectionPair(context, client, sidecar, "sidecar"));
  client.on("error", (error) => log(context, "client_error", { error: errorMessage(error) }));
  sidecar.on("error", (error) => log(context, "sidecar_error", { error: errorMessage(error) }));
}

function closeConnectionPair(
  context: ProxyContext,
  client: Socket,
  sidecar: Socket,
  source: string,
): void {
  log(context, "connection_close", { source });
  if (context.activeClient === client) context.activeClient = null;
  if (context.activeSidecar === sidecar) context.activeSidecar = null;
  if (!client.destroyed) client.destroy();
  if (!sidecar.destroyed) sidecar.destroy();
  writeInfo(context);
}

function forwardClientData(context: ProxyContext, chunk: Buffer | string): void {
  log(context, "client_to_sidecar", { bytes: chunk.length });
  context.activeSidecar?.write(chunk);
}

function handleSidecarData(context: ProxyContext, chunk: Buffer | string): void {
  context.sidecarBuffer += chunk.toString();
  const lines = context.sidecarBuffer.split("\n");
  context.sidecarBuffer = lines.pop() || "";
  for (const line of lines) forwardSidecarLine(context, line);
}

function forwardSidecarLine(context: ProxyContext, line: string): void {
  if (!line.trim()) return;

  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    // Preserve unexpected sidecar output instead of making the proxy the source of failure.
    log(context, "sidecar_to_client_non_json");
    context.activeClient?.write(`${line}\n`);
    return;
  }

  const pendingId = jsonRpcId(parsed);
  if (pendingId && context.pending.has(pendingId)) {
    const pending = context.pending.get(pendingId);
    if (!pending) return;

    clearTimeout(pending.timer);
    context.pending.delete(pendingId);
    const response = injectedHttpResponse(parsed);
    writeJson(pending.response, response.status, response.payload);
    writeInfo(context);
    return;
  }

  context.activeClient?.write(`${JSON.stringify(parsed)}\n`);
}

function injectRequest<Input>(
  context: ProxyContext,
  body: Input,
  response: ServerResponse,
  buildRequest: (input: Input) => JsonRpcRequest,
): void {
  const sidecar = context.activeSidecar;
  if (!sidecar || sidecar.destroyed) {
    writeJson(response, 503, { error: "No active sidecar connection" });
    return;
  }

  let request: JsonRpcRequest;
  try {
    request = buildRequest(body);
  } catch (error: unknown) {
    writeJson(response, 400, { error: errorMessage(error) });
    return;
  }

  const id = String(request.id);
  const timer = setTimeout(() => {
    if (!context.pending.has(id)) return;
    context.pending.delete(id);
    writeJson(response, 504, { error: "Timed out waiting for sidecar response", id });
    writeInfo(context);
  }, 120_000);

  context.pending.set(id, { response, timer });
  log(context, "bridge_to_sidecar", { id, method: request.method });
  const handleWriteFailure = (error: Error): void => {
    clearTimeout(timer);
    context.pending.delete(id);
    writeJson(response, 503, { error: error.message });
    writeInfo(context);
  };

  try {
    sidecar.write(`${JSON.stringify(request)}\n`, (error) => {
      if (!error || !context.pending.has(id)) return;
      handleWriteFailure(error);
    });
  } catch (error: unknown) {
    handleWriteFailure(asError(error));
  }
  writeInfo(context);
}

function log(context: ProxyContext, kind: string, payload: JsonObject = {}): void {
  const entry = {
    ts: new Date().toISOString(),
    kind,
    proxyPid: process.pid,
    realPid: context.child?.pid,
    ...payload,
  };
  fs.appendFile(context.logPath, `${JSON.stringify(entry)}\n`, () => {});
}

function writeInfo(context: ProxyContext, extra: JsonObject = {}): void {
  const info = {
    publicSocketPath: context.publicSocketPath,
    realSocketPath: context.realSocketPath,
    proxyPid: process.pid,
    realPid: context.child?.pid,
    logPath: context.logPath,
    controlUrl: context.controlUrl,
    updatedAt: new Date().toISOString(),
    activeClient: Boolean(context.activeClient),
    activeSidecar: Boolean(context.activeSidecar),
    pending: context.pending.size,
    ...extra,
  };
  fs.writeFileSync(context.infoPath, JSON.stringify(info, null, 2));
}

function cleanup(context: ProxyContext, extra: JsonObject = {}): void {
  unlinkIfExists(context.publicSocketPath);
  writeInfo(context, { shuttingDown: true, ...extra });
}

function buildQueryRequest(input: MessageInput): JsonRpcRequest {
  const sessionId = requiredNonEmptyString(input.sessionId, "sessionId");
  const workspaceId = requiredNonEmptyString(input.workspaceId, "workspaceId");
  const cwd = requiredNonEmptyString(input.cwd, "cwd");
  const message = requiredNonEmptyString(input.message, "message");

  const agentType = optionalString(input.agentType) ?? "codex";
  const model = optionalString(input.model) ?? "gpt-5.5";
  const messageId = optionalString(input.messageId) ?? randomUUID();

  return {
    jsonrpc: "2.0",
    id: optionalString(input.rpcId) ?? `mobile-query-${randomUUID()}`,
    method: "query",
    params: {
      type: "query",
      id: sessionId,
      agentType,
      message,
      prompt: optionalString(input.prompt) ?? message,
      options: {
        cwd,
        workspaceId,
        userMessageId: messageId,
        turnId: optionalString(input.turnId) ?? messageId,
        model,
        permissionMode: optionalString(input.permissionMode) ?? "default",
        fastMode: Boolean(input.fastMode),
        deliveryMode: optionalString(input.deliveryMode) ?? "default",
        agentParams: input.agentParams ?? {
          agentType,
          modelReasoningEffort: optionalString(input.modelReasoningEffort) ?? "high",
          personality: optionalString(input.personality) ?? "pragmatic",
        },
      },
    },
  };
}

export function buildCancelRequest(input: StopInput): JsonRpcRequest {
  const sessionId = requiredNonEmptyString(input.sessionId, "sessionId");
  const agentType = requiredNonEmptyString(input.agentType, "agentType");

  return {
    jsonrpc: "2.0",
    id: `mobile-cancel-${randomUUID()}`,
    method: "cancel",
    params: {
      type: "cancel",
      id: sessionId,
      agentType,
      expectsTerminalResponse: true,
    },
  };
}

export function injectedHttpResponse(response: unknown): InjectedHttpResponse {
  const error = jsonRpcErrorMessage(response);
  if (error !== null) {
    return {
      status: 502,
      payload: { error },
    };
  }

  return {
    status: 200,
    payload: response,
  };
}

function readJsonBody<Input>(
  request: IncomingMessage,
  response: ServerResponse,
  callback: (body: Input) => void,
): void {
  let raw = "";
  request.setEncoding("utf8");
  request.on("data", (chunk: string) => {
    raw += chunk;
    if (raw.length > 1_000_000) request.destroy(new Error("Request body too large"));
  });
  request.on("end", () => {
    try {
      const body: unknown = raw ? JSON.parse(raw) : {};
      if (!body || typeof body !== "object" || Array.isArray(body)) {
        throw new Error("Expected JSON object");
      }
      callback(body as Input);
    } catch (error: unknown) {
      writeJson(response, 400, { error: errorMessage(error) });
    }
  });
}

function writeJson(response: ServerResponse, status: number, payload: unknown): void {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(payload));
}

function waitForFile(file: string, timeoutMs = 10_000): Promise<void> {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const tick = (): void => {
      fs.stat(file, (error) => {
        if (!error) {
          resolve();
          return;
        }
        if (Date.now() - started > timeoutMs) {
          reject(new Error(`Timed out waiting for ${file}`));
          return;
        }
        setTimeout(tick, 50);
      });
    };
    tick();
  });
}

function unlinkIfExists(file: string): void {
  try {
    fs.unlinkSync(file);
  } catch (error: unknown) {
    if (!isNodeErrorWithCode(error, "ENOENT")) throw error;
  }
}

function requireRealSocketPath(context: ProxyContext): string {
  if (!context.realSocketPath) {
    throw new Error("Real sidecar socket path is not known yet");
  }
  return context.realSocketPath;
}

function jsonRpcId(value: unknown): string | null {
  if (!value || typeof value !== "object" || !Object.hasOwn(value, "id")) {
    return null;
  }

  return String((value as { id: unknown }).id);
}

function jsonRpcErrorMessage(value: unknown): string | null {
  if (!value || typeof value !== "object" || !Object.hasOwn(value, "error")) {
    return null;
  }

  const error = (value as { error: unknown }).error;
  if (typeof error === "string") {
    return error;
  }
  if (
    error &&
    typeof error === "object" &&
    "message" in error &&
    typeof error.message === "string"
  ) {
    return error.message;
  }
  return "The Conductor sidecar rejected the request.";
}

function isNodeErrorWithCode(error: unknown, code: string): boolean {
  return Boolean(error && typeof error === "object" && "code" in error && error.code === code);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

function requiredNonEmptyString(value: unknown, name: string): string {
  const normalized = optionalString(value);
  if (!normalized) {
    throw new Error(`Required: ${name}`);
  }
  return normalized;
}

function optionalString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed ? trimmed : undefined;
}
