#!/usr/bin/env node

/**
 * Copilot CLI Server Wrapper
 *
 * A thin JSON-RPC proxy that sits between the Elixir port and the real
 * `copilot --server --stdio` process. It forwards all standard RPC methods
 * transparently and adds a custom `session.setModel` method that enables
 * context-preserving model switching.
 *
 * How session.setModel works:
 *   1. Append a `session.model_change` event to the session's events.jsonl
 *   2. Destroy the in-memory session in the child server
 *   3. Resume the session (reloads from events.jsonl, picking up the new model)
 *   4. Suppress the internal destroy/resume events from reaching the parent
 *
 * The copilot SDK's Session.processEventForState handles `session.model_change`
 * by setting `this._selectedModel = event.data.newModel`, so the resumed session
 * uses the new model for subsequent API calls while preserving conversation history.
 */

const { spawn } = require("child_process");
const path = require("path");
const fs = require("fs");
const os = require("os");
const crypto = require("crypto");

const SESSION_DIR = path.join(
  os.homedir(),
  ".local",
  "state",
  ".copilot",
  "session-state"
);

class CopilotProxy {
  constructor(copilotPath) {
    this.copilotPath = copilotPath;
    this.parentBuffer = Buffer.alloc(0);
    this.childBuffer = Buffer.alloc(0);
    this.pendingInternal = new Map(); // id -> { resolve, reject, timer }
    this.nextInternalId = 900000;
    // Track sessions undergoing model switch to suppress their events
    this.suppressedSessions = new Set();
  }

  /**
   * Validate that a sessionId is safe for use in filesystem paths.
   * Rejects path separators, "..", and non-printable characters.
   */
  validateSessionId(sessionId) {
    if (typeof sessionId !== "string" || sessionId.length === 0) {
      return false;
    }
    // Only allow alphanumeric, hyphens, underscores, and dots (no "..")
    if (!/^[a-zA-Z0-9._-]+$/.test(sessionId)) {
      return false;
    }
    if (sessionId.includes("..")) {
      return false;
    }
    return true;
  }

  start() {
    const args = ["--server", "--stdio"];

    // Forward extra args (e.g. --log-level)
    const extraArgs = process.argv.slice(2);
    args.push(...extraArgs);

    this.child = spawn(this.copilotPath, args, {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env },
    });

    this.child.stderr.on("data", (data) => process.stderr.write(data));

    this.child.stdout.on("data", (data) => {
      this.childBuffer = Buffer.concat([this.childBuffer, data]);
      this.processChildBuffer();
    });

    this.child.on("exit", (code) => process.exit(code || 0));

    process.stdin.on("data", (data) => {
      this.parentBuffer = Buffer.concat([this.parentBuffer, data]);
      this.processParentBuffer();
    });

    process.stdin.on("end", () => {
      if (this.child && !this.child.killed) this.child.kill();
    });

    process.on("SIGTERM", () => {
      if (this.child && !this.child.killed) this.child.kill();
      process.exit(0);
    });

    process.on("SIGINT", () => {
      if (this.child && !this.child.killed) this.child.kill();
      process.exit(0);
    });
  }

  // ── LSP Content-Length Framing ──

  extractMessage(buffer) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd === -1) return null;

    const headers = buffer.slice(0, headerEnd).toString("utf8");
    const match = headers.match(/Content-Length:\s*(\d+)/i);
    if (!match) return null;

    const contentLength = parseInt(match[1], 10);
    const bodyStart = headerEnd + 4;
    const totalNeeded = bodyStart + contentLength;

    if (buffer.length < totalNeeded) return null;

    const body = buffer.slice(bodyStart, totalNeeded).toString("utf8");
    const rest = buffer.slice(totalNeeded);
    return { body, rest };
  }

  encodeLsp(obj) {
    const body = typeof obj === "string" ? obj : JSON.stringify(obj);
    const len = Buffer.byteLength(body, "utf8");
    return `Content-Length: ${len}\r\n\r\n${body}`;
  }

  sendToChild(msg) {
    if (this.child && this.child.stdin.writable) {
      this.child.stdin.write(this.encodeLsp(msg));
    }
  }

  sendToParent(msg) {
    process.stdout.write(this.encodeLsp(msg));
  }

  // ── Buffer Processing ──

  processParentBuffer() {
    while (true) {
      const result = this.extractMessage(this.parentBuffer);
      if (!result) break;
      this.parentBuffer = Buffer.isBuffer(result.rest)
        ? result.rest
        : Buffer.from(result.rest);

      try {
        const msg = JSON.parse(result.body);
        this.handleParentMessage(msg);
      } catch (e) {
        process.stderr.write(`[wrapper] Invalid JSON from parent: ${e.message}\n`);
      }
    }
  }

  processChildBuffer() {
    while (true) {
      const result = this.extractMessage(this.childBuffer);
      if (!result) break;
      this.childBuffer = Buffer.isBuffer(result.rest)
        ? result.rest
        : Buffer.from(result.rest);

      try {
        const msg = JSON.parse(result.body);
        this.handleChildMessage(msg);
      } catch (e) {
        process.stderr.write(`[wrapper] Invalid JSON from child: ${e.message}\n`);
      }
    }
  }

  // ── Message Routing ──

  handleParentMessage(msg) {
    if (msg.method === "session.setModel") {
      this.handleSetModel(msg);
      return;
    }

    // Forward everything else transparently
    this.sendToChild(msg);
  }

  handleChildMessage(msg) {
    // Check if this is a response to one of our internal requests
    if (msg.id !== undefined && this.pendingInternal.has(msg.id)) {
      const { resolve, timer } = this.pendingInternal.get(msg.id);
      this.pendingInternal.delete(msg.id);
      if (timer) clearTimeout(timer);
      resolve(msg);
      return;
    }

    // Suppress session events during model switch
    if (msg.method === "session.event" && msg.params) {
      const sessionId = msg.params.sessionId;
      if (this.suppressedSessions.has(sessionId)) {
        return; // swallow this event
      }
    }

    // Forward to parent
    this.sendToParent(msg);
  }

  // ── Internal RPC to Child ──

  sendInternalRequest(method, params, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
      const id = this.nextInternalId++;
      const timer = setTimeout(() => {
        if (this.pendingInternal.has(id)) {
          this.pendingInternal.delete(id);
          reject(new Error(`Internal ${method} request timed out`));
        }
      }, timeoutMs);

      this.pendingInternal.set(id, { resolve, reject, timer });
      this.sendToChild({ jsonrpc: "2.0", id, method, params });
    });
  }

  // ── session.setModel Handler ──

  async handleSetModel(msg) {
    const { sessionId, model } = msg.params || {};

    if (!sessionId || !model) {
      this.sendToParent({
        jsonrpc: "2.0",
        id: msg.id,
        error: {
          code: -32602,
          message: "Missing required parameter: sessionId and model",
        },
      });
      return;
    }

    if (!this.validateSessionId(sessionId)) {
      this.sendToParent({
        jsonrpc: "2.0",
        id: msg.id,
        error: {
          code: -32602,
          message: "Invalid sessionId: contains unsafe characters",
        },
      });
      return;
    }

    try {
      // Find the session's events.jsonl on disk
      const sessionDir = path.join(SESSION_DIR, sessionId);
      const eventsFile = path.join(sessionDir, "events.jsonl");

      if (!fs.existsSync(sessionDir)) {
        throw new Error(`Session directory not found: ${sessionDir}`);
      }

      if (!fs.existsSync(eventsFile)) {
        // No events persisted yet (no messages sent) — destroy and recreate
        // with the new model. No conversation context to preserve.
        this.suppressedSessions.add(sessionId);
        try {
          await this.sendInternalRequest("session.destroy", { sessionId });
        } catch (_e) {
          // ignore
        }
        const createResult = await this.sendInternalRequest("session.create", {
          model,
          sessionId,
        });
        this.suppressedSessions.delete(sessionId);

        if (createResult.error) {
          throw new Error(
            createResult.error.message || "Failed to recreate session"
          );
        }

        this.sendToParent({
          jsonrpc: "2.0",
          id: msg.id,
          result: {
            success: true,
            model,
            sessionId: createResult.result.sessionId,
            previousModel: null,
            changed: true,
          },
        });
        return;
      }

      // Read last event to get parentId for proper chaining
      const lines = fs.readFileSync(eventsFile, "utf8").trim().split("\n");
      const lastEvent = JSON.parse(lines[lines.length - 1]);
      const lastEventId = lastEvent.id;

      // Determine previous model from session.start or last model_change
      let previousModel = null;
      for (let i = lines.length - 1; i >= 0; i--) {
        const evt = JSON.parse(lines[i]);
        if (evt.type === "session.model_change") {
          previousModel = evt.data.newModel;
          break;
        }
        if (evt.type === "session.start" && evt.data.selectedModel) {
          previousModel = evt.data.selectedModel;
          break;
        }
      }

      if (previousModel === model) {
        // Already on this model, no-op success
        this.sendToParent({
          jsonrpc: "2.0",
          id: msg.id,
          result: { success: true, model, sessionId, changed: false },
        });
        return;
      }

      // Suppress events for this session during the switch
      this.suppressedSessions.add(sessionId);

      // Append session.model_change event to events.jsonl
      const modelChangeEvent = {
        type: "session.model_change",
        data: { previousModel, newModel: model },
        id: crypto.randomUUID(),
        timestamp: new Date().toISOString(),
        parentId: lastEventId,
      };
      fs.appendFileSync(eventsFile, JSON.stringify(modelChangeEvent) + "\n");

      // Destroy the in-memory session in the child server
      try {
        await this.sendInternalRequest("session.destroy", { sessionId });
      } catch (_e) {
        // Session might not be active in-memory, that's fine
      }

      // Resume the session — child reloads from events.jsonl with new model
      const resumeResult = await this.sendInternalRequest("session.resume", {
        sessionId,
      });

      // Un-suppress events
      this.suppressedSessions.delete(sessionId);

      if (resumeResult.error) {
        throw new Error(
          resumeResult.error.message || "Failed to resume session after model change"
        );
      }

      // Send a synthetic session.event to notify parent of the model change
      this.sendToParent({
        jsonrpc: "2.0",
        method: "session.event",
        params: {
          sessionId,
          event: {
            type: "session.model_change",
            data: { previousModel, newModel: model },
            id: modelChangeEvent.id,
            timestamp: modelChangeEvent.timestamp,
            parentId: lastEventId,
          },
        },
      });

      // Reply success
      this.sendToParent({
        jsonrpc: "2.0",
        id: msg.id,
        result: { success: true, model, sessionId, previousModel, changed: true },
      });
    } catch (error) {
      // Un-suppress on error
      this.suppressedSessions.delete(sessionId);

      this.sendToParent({
        jsonrpc: "2.0",
        id: msg.id,
        error: { code: -32000, message: error.message },
      });
    }
  }
}

// ── Entry Point ──

function findCopilot() {
  // Check COPILOT_CLI_PATH env var first
  const envPath = process.env.COPILOT_CLI_PATH;
  if (envPath && fs.existsSync(envPath)) return envPath;

  // Check common paths
  const candidates = [
    "/usr/bin/copilot",
    "/usr/local/bin/copilot",
    path.join(os.homedir(), ".local", "bin", "copilot"),
  ];

  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }

  // Fall back to PATH lookup
  const { execSync } = require("child_process");
  try {
    return execSync("which copilot", { encoding: "utf8" }).trim();
  } catch (_e) {
    process.stderr.write("[wrapper] Error: copilot CLI not found\n");
    process.exit(1);
  }
}

const copilotPath = findCopilot();
const proxy = new CopilotProxy(copilotPath);
proxy.start();
