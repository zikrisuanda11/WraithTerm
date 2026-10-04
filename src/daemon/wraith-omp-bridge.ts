// WraithTerm omp bridge (P2.5, D6).
//
// An omp extension that reports agent lifecycle state to the daemon's
// harness socket as JSON-lines. Installed by `+install-omp-bridge`
// (P2.6) into `~/.omp/agent/extensions/wraith-omp-bridge.ts`.
//
// MARKER: wraith-omp-bridge (the installer keys on this line; do not remove)
//
// Contract, mirroring the proven herdr/orca extensions (HARNESS_OMP.md §2):
// - Fire-and-forget: a slow or missing daemon NEVER stalls the agent.
//   Single attempt, 50 ms timeout, socket destroyed on completion.
// - Silent when `WRAITH_HARNESS_SOCK` / `WRAITH_SESSION_ID` are unset.
// - `timer.unref?.()` so hooks never hold the process open.
// - States follow HARNESS_OMP.md §4 (Tier 1 mapping).

// @ts-nocheck
import net from "node:net";

const socketPath = process.env.WRAITH_HARNESS_SOCK;
const sessionId = process.env.WRAITH_SESSION_ID;
const ompVersion = process.env.OMP_VERSION || "";

function enabled() {
  return !!socketPath && !!sessionId;
}

// One JSON-lines event per call. Never throws, never waits.
function send(state, tool) {
  if (!enabled()) return;
  const event = { v: 1, type: "state", state, session_id: sessionId };
  if (tool) event.tool = tool;
  if (ompVersion) event.omp_version = ompVersion;
  let line;
  try {
    line = JSON.stringify(event) + "\n";
  } catch {
    return;
  }
  let socket;
  try {
    socket = net.createConnection(socketPath);
  } catch {
    return;
  }
  const done = () => {
    try {
      socket.destroy();
    } catch {}
  };
  const timer = setTimeout(done, 50);
  timer.unref?.();
  socket.on("error", () => {
    clearTimeout(timer);
    done();
  });
  socket.on("connect", () => {
    try {
      socket.write(line, () => {
        clearTimeout(timer);
        done();
      });
    } catch {
      clearTimeout(timer);
      done();
    }
  });
}

export default function (pi) {
  if (!enabled()) return;

  pi.on("agent_start", () => send("thinking"));
  pi.on("before_agent_start", () => send("thinking"));
  pi.on("agent_settled", () => send("idle"));
  pi.on("agent_end", (event) => {
    if (event?.willContinue === true) return;
    send("idle");
  });
  pi.on("tool_call", (event) => send("executing_tool", event?.toolName));
  pi.on("tool_execution_start", (event) => send("executing_tool", event?.toolName));
  pi.on("tool_execution_end", () => send("thinking"));
  pi.on("tool_approval_requested", (event) =>
    send("awaiting_approval", event?.toolName),
  );
  pi.on("tool_approval_resolved", () => send("thinking"));
  pi.on("session_start", () => send("idle"));
  pi.on("session_shutdown", () => send("idle"));
}
