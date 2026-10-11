# Agent guide

Impulse is a native macOS launcher in Swift. The user's actions live in `config/actions.json`, which Git ignores.

## Build and test
- Build: `zsh scripts/build.sh` (writes `dist/Impulse.app` and `dist/launcherctl`).
- Test: `zsh scripts/test.sh`. It must end with `ALL PASS`.
- Self-tests use temporary folders and private pasteboards. They never touch the user's config or clipboard.

## Change the user's actions
- Write a candidate file, then run `dist/launcherctl validate candidate.json`.
- Apply it with `dist/launcherctl apply candidate.json`. Undo with `dist/launcherctl rollback`.
- Use `dist/launcherctl resolve '<input>'` to check what an input opens. It changes nothing.
- Never put personal actions in `examples/`.

## Change the code
- `Sources/LauncherCore`: config, validation, routing, ranking, calculator. No UI. Tests in `Tests/`.
- `Sources/LauncherApp`: the AppKit panel. Checks in `IntegrationChecks.swift`.
- `Sources/LauncherCLI`: `launcherctl`. Its JSON output is a contract; keep types stable.
- `vendor/` holds third-party code. Record any change in its `UPSTREAM.md`.
- Keep the router deterministic: the same input and config give the same result.
