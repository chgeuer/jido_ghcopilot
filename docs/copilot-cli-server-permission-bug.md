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
{"jsonrpc": "2.0", "id": 42, "result": {"kind": "approved"}}
```

Permission request kinds include: `write`, `read`, `commands` (shell), `url`, `mcp`, `custom-tool`.

### Implementation in jido_ghcopilot

`Jido.GHCopilot.Server.Connection` now:
1. Passes `requestPermission: true` in all `session.create` and `session.resume` requests
2. Auto-approves all `permission.request` JSON-RPC requests from the CLI

This restores full tool execution (file create/edit, bash, URL fetch) while keeping
the Server protocol's advantages: usage tracking, external tool calls, model switching,
and attachments.

## Version Mismatch Note

The npm package may show v0.0.374 in `package.json` while the native binary
(`copilot-linux-x64`) reports v0.0.421. The `npm-loader.js` entry point prefers
the native binary, so the native version's behavior applies. Use `copilot --version`
to check the effective version.
