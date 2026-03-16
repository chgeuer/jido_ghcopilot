# Contributing to Jido.GHCopilot

## Development Setup

1. Clone the repo.
2. Install deps:

```bash
mix setup
```

3. Run tests:

```bash
mix test
```

4. Run quality checks:

```bash
mix quality
```

## Contribution Standards

- Target Elixir `~> 1.18`.
- Keep adapter behavior aligned with `Jido.Harness.Adapter`.
- Use Zoi for validation and Splode-style structured errors.
- Add or update tests for all behavior changes.
- Keep coverage at or above the configured threshold (90%).
- Use conventional commits (`feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`).

## Project Layout

- `lib/jido_ghcopilot/ghcopilot.ex` - public API facade
- `lib/jido_ghcopilot/adapter.ex` - adapter implementation
- `lib/jido_ghcopilot/mapper.ex` - line -> `Jido.Harness.Event` mapping
- `lib/jido_ghcopilot/options.ex` - metadata/runtime option normalization
- `lib/jido_ghcopilot/compatibility.ex` - CLI compatibility checks

## Integration Tests

Integration tests are tagged `:integration` and excluded by default.

Run them explicitly when the Copilot CLI and auth are available:

```bash
mix test --include integration
```

## License

By contributing, you agree contributions are licensed under Apache-2.0.
