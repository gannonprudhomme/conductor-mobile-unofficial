import assert from "node:assert/strict";
import test from "node:test";

import { buildCancelRequest, injectedHttpResponse } from "./runtime-proxy.mjs";

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
