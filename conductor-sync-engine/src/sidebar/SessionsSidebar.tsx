import { useState, useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";
import "./SessionsSidebar.css";

type ConductorSession = {
  id: string;
  workspace_id: string;
  title: string;
  agent_type: string;

  created_at: string;
  updated_at: string;
  last_user_message_at: string | null;

  status: string;
  model: string;

  unread_count: number | null;
  freshly_compacted: boolean | null;
  context_token_count: number | null;
  // context_used_percent: number | null;
};

type LoadState =
  | { kind: "loading" }
  | { kind: "loaded"; sessions: ConductorSession[] }
  | { kind: "failed"; message: string }

function formatDate(value: string | null) {
  if (value == null) {
    return "No update date";
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return value;
  } else {
    return date.toLocaleString();
  }
}

export function SessionsSidebar() {
  const [loadState, setLoadState] = useState<LoadState>({ kind: "loading" });

  async function loadSessions() {
    setLoadState({ kind: "loading" });

    try {
      const sessions = await invoke<ConductorSession[]>("list_sessions");
      setLoadState({ kind: "loaded", sessions });
    } catch (error) {
      setLoadState({
        kind: "failed",
        message: error instanceof Error ? error.message : String(error)
      });
    }
  }

  useEffect(() => {
    loadSessions();
  }, []);

  return (
    <div className="sidebar">
      <header className="toolbar">
        <h1> Conductor Sessions </h1>

        <button onClick={loadSessions}>Refresh</button>
      </header>

      {loadState.kind == "loading" && <p>Loading sessions....</p>}

      {loadState.kind == "failed" && (
        <section className="error">
          <h2> Could not load sessions </h2>
          <pre>{loadState.message}</pre>
        </section>
      )}

      {loadState.kind == "loaded" && (
        <section className="session-list">
          {loadState.sessions.map((session) => (
            <article className="session-row" key={session.id}>
              <div className="session-main">
                <h2>{session.title}</h2>

                <p>
                  {session.status ?? "unknown status"}
                  {" · "}
                  {session.agent_type}
                  {" · "}
                  {session.model}
                </p>
              </div>

              <div className="session-meta">
                <span>{session.unread_count} unread</span>

                {/* <span>
                    {session.context_used_percent == null ? "No context %" : `${Math.round(session.context_used_percent)}% context`}
                  </span> */}

                <span>{formatDate(session.updated_at)}</span>
              </div>
            </article>
          ))}
        </section>
      )}
    </div>
  );
}
