import assert from "node:assert/strict";
import test from "node:test";

import {
  buildCancelRequest,
  buildQueryRequest,
  injectedHttpResponse,
} from "./runtime-proxy.mjs";

test("buildQueryRequest steers messages by default", () => {
  const request = buildQueryRequest({
    agentType: "codex",
    cwd: "/tmp/workspace-1",
    message: "Run the tests.",
    messageId: "message-1",
    model: "gpt-5.5",
    rpcId: "rpc-1",
    sessionId: "session-1",
    workspaceId: "workspace-1",
  });

  assert.deepEqual(request, {
    jsonrpc: "2.0",
    id: "rpc-1",
    method: "query",
    params: {
      type: "query",
      id: "session-1",
      agentType: "codex",
      message: "Run the tests.",
      prompt: "Run the tests.",
      options: {
        cwd: "/tmp/workspace-1",
        workspaceId: "workspace-1",
        userMessageId: "message-1",
        turnId: "message-1",
        model: "gpt-5.5",
        permissionMode: "default",
        fastMode: false,
        deliveryMode: "steering",
        agentParams: {
          agentType: "codex",
          modelReasoningEffort: "high",
          personality: "pragmatic",
        },
      },
    },
  });
});

test("buildQueryRequest forwards fast mode", () => {
  const request = buildQueryRequest({
    agentType: "codex",
    cwd: "/tmp/workspace-1",
    fastMode: true,
    message: "Run the tests.",
    messageId: "message-1",
    model: "gpt-5.6-sol",
    rpcId: "rpc-1",
    sessionId: "session-1",
    workspaceId: "workspace-1",
  });

  assert.equal((request.params.options as { fastMode: boolean }).fastMode, true);
});

test("buildQueryRequest preserves explicit queue delivery", () => {
  const request = buildQueryRequest({
    cwd: "/tmp/workspace-1",
    deliveryMode: "default",
    message: "Run this next.",
    sessionId: "session-1",
    workspaceId: "workspace-1",
  });

  assert.equal(
    (request.params.options as { deliveryMode: string }).deliveryMode,
    "default",
  );
});

test("buildQueryRequest steers Claude messages by default", () => {
  const request = buildQueryRequest({
    agentType: "claude",
    cwd: "/tmp/workspace-1",
    message: "Run the tests.",
    sessionId: "session-1",
    workspaceId: "workspace-1",
  });

  assert.equal(
    (request.params.options as { deliveryMode: string }).deliveryMode,
    "steering",
  );
});

test("buildQueryRequest queues unsupported agents by default", () => {
  for (const agentType of ["acp", "future-agent"]) {
    const request = buildQueryRequest({
      agentType,
      cwd: "/tmp/workspace-1",
      message: "Run the tests.",
      sessionId: "session-1",
      workspaceId: "workspace-1",
    });

    assert.equal(
      (request.params.options as { deliveryMode: string }).deliveryMode,
      "default",
    );
  }
});

test("buildCancelRequest creates the SidecarV2 cancel wire format", () => {
  const request = buildCancelRequest({
    agentType: "codex",
    sessionId: "session-1",
  });

  assert.match(request.id, /^mobile-cancel-/);
  assert.deepEqual(request, {
    jsonrpc: "2.0",
    id: request.id,
    method: "cancel",
    params: {
      type: "cancel",
      id: "session-1",
      agentType: "codex",
      expectsTerminalResponse: true,
    },
  });
});

test("buildCancelRequest requires its protocol fields", () => {
  assert.throws(
    () => buildCancelRequest({ agentType: "codex" }),
    /Required: sessionId/,
  );
  assert.throws(
    () => buildCancelRequest({ sessionId: "session-1" }),
    /Required: agentType/,
  );
});

test("injectedHttpResponse preserves successful JSON-RPC responses", () => {
  const response = {
    jsonrpc: "2.0",
    id: "mobile-cancel-1",
    result: null,
  };

  assert.deepEqual(injectedHttpResponse(response), {
    status: 200,
    payload: response,
  });
});

test("injectedHttpResponse converts JSON-RPC errors to HTTP errors", () => {
  assert.deepEqual(
    injectedHttpResponse({
      jsonrpc: "2.0",
      id: "mobile-cancel-1",
      error: {
        code: -32_000,
        message: "Cancellation failed",
      },
    }),
    {
      status: 502,
      payload: { error: "Cancellation failed" },
    },
  );
});
