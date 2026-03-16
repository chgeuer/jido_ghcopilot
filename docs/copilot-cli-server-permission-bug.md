# Copilot CLI Permission Change in Server Mode (v0.0.421+)

## Summary

Starting with the native binary v0.0.421, the Copilot CLI enforces permissions in
`--server` mode. Clients MUST opt into the permission callback protocol or all
write/shell/url operations will be auto-denied.

## Affected Versions

- **v0.0.374** (JS bundle): `requestRequired: false` in server mode → all auto-approved
- **v0.0.421** (native binary): `requestRequired: true` → auto-denied without callback
- **v0.0.422** (JS bundle): Same as v0.0.421

## Root Cause

In v0.0.421+, the Session class changed from:

```js
// Old (v0.0.374): no permission checking in server mode
permissions: this.requestPermission
  ? { requestRequired: true, request: this.requestPermission }
  : { requestRequired: false }
```

To:

```js
// New (v0.0.421+): always requires permissions, auto-denies if no listener
permissions: this.hasEventListeners("permission.requested")
  ? { requestRequired: true, request: V => this.pendingRequests.requestPermission(V) }
  : { requestRequired: true, request: async () => ({ kind: "denied-no-approval-rule-and-could-not-request-from-user" }) }
```

## Fix

Clients must pass `requestPermission: true` in `session.create` and `session.resume`
params. The CLI then sends `permission.request` JSON-RPC requests which the client
must respond to with `{kind: "approved"}`.

### Protocol details

**Request** (CLI → client):
```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "permission.request",
  "params": {
    "sessionId": "...",
    "permissionRequest": {
      "kind": "write",
      "intention": "Create file",
      "fileName": "/path/to/file.md",
      "diff": "..."
    }
  }
}
```

**Response** (client → CLI):
```json
{"jsonrpc": "2.0", "id": 42, "result": {"result": {"kind": "approved"}}}
```

Note the double-nested `result`—the CLI's `dispatchPermissionRequest` does
`(await sendRequest(...)).result`, so the outcome must be nested inside a
`result` key within the JSON-RPC result.

Permission request kinds include: `write`, `read`, `commands` (shell), `url`, `mcp`, `custom-tool`.

### Event-based permission path

In addition to `permission.request` JSON-RPC requests, the CLI also emits
`permission.requested` as a `session.event` notification. This event contains
a `requestId` that must be resolved via a separate RPC method:

**Event** (CLI → client, as `session.event` notification):
```json
{
  "jsonrpc": "2.0",
  "method": "session.event",
  "params": {
    "sessionId": "...",
    "event": {
      "type": "permission.requested",
      "data": {
        "requestId": "req-uuid",
        "permissionRequest": {"kind": "write", "intention": "Create file", ...}
      }
    }
  }
}
```

**Resolution** (client → CLI, new RPC call):
```json
{
  "jsonrpc": "2.0",
  "id": 43,
  "method": "session.permissions.handlePendingPermissionRequest",
  "params": {
    "sessionId": "...",
    "requestId": "req-uuid",
    "result": {"kind": "approved"}
  }
}
```

Both paths must be handled — the CLI may use either depending on the context.

### Implementation in jido_ghcopilot

`Jido.GHCopilot.Server.Connection` now:
1. Passes `requestPermission: true` in all `session.create` and `session.resume` requests
2. Auto-approves all `permission.request` JSON-RPC requests from the CLI
3. Auto-approves all `permission.requested` session events via `session.permissions.handlePendingPermissionRequest`

This restores full tool execution (file create/edit, bash, URL fetch) while keeping
the Server protocol's advantages: usage tracking, external tool calls, model switching,
and attachments.

## Version Mismatch Note

The npm package may show v0.0.374 in `package.json` while the native binary
(`copilot-linux-x64`) reports v0.0.421. The `npm-loader.js` entry point prefers
the native binary, so the native version's behavior applies. Use `copilot --version`
to check the effective version.
