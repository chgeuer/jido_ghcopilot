# Changelog

## v0.1.0

- Initial release
- Full `Jido.Harness.Adapter` implementation
  - `id/0`, `capabilities/0`, `run/2`, `cancel/1`
- Process-based execution via `copilot -p` (non-interactive mode)
- Line-based output mapping to `Jido.Harness.Event` structs
- Session lifecycle + cancellation registry (`Jido.GHCopilot.SessionRegistry`)
- Runtime modules
  - `Jido.GHCopilot.Options` — metadata/runtime option normalization
  - `Jido.GHCopilot.Compatibility` — CLI compatibility checks
  - `Jido.GHCopilot.Error` — Splode-based structured errors
  - `Jido.GHCopilot.CLI` — CLI binary resolution
  - `Jido.GHCopilot.SystemCommand` — system command wrapper
- Test suite with full unit coverage
