# Security review — 2026-09-13

Base: `8a8b2e7b4a0e32a3c2747802f730d5a3dd0fe4ed`, also `origin/main` when fetched.
The review covers the security fixes accompanying this document.

## Scope and trust boundaries

Reviewed all executable project files: Model.js, Panel.qml, the shell helper,
and the manifest. Followed metadata into Lua, shell arguments, file writes,
and visible labels; also inspected preview, rollback, backups and IPC.
Monitor metadata is untrusted. The local user, their plugin files, config,
PATH and environment are trusted; the helper does not elevate privileges.

## Fixed

1. **High: metadata becomes executable Lua.** Output selectors were inserted
   directly into quoted strings, affecting preview and persistence, including
   disabled displays. The patch validates connectors and uses a shared Lua
   encoder for every emitted string. Quotes and backslashes remain data.
2. **High: metadata escapes saved comments.** Raw model labels containing CR
   or LF could introduce executable statements in monitors.lua. Generated
   comments now flatten control characters. Both injection routes were
   reproduced on the original source with harmless boolean sentinels.
3. **Potential metadata markup injection.** Metadata-bearing Qt Text items
   used automatic text-format detection. These now explicitly use PlainText,
   including notices and the selected display header. Qt documents that
   auto-detected rich text can include remote images:
   [Qt Text documentation](https://doc.qt.io/qt-6/qml-qtquick-text.html#textFormat-prop).
   This is supported by source inspection and Qt documentation; remote image
   loading was not reproduced in the target Quickshell runtime.
4. **Config integrity: malformed markers can discard user content.** A start
   marker without an end caused the splice to consume the remaining file.
   Saves now reject missing, reversed, nested, or duplicate marker pairs in
   input and existing config. Tests verify byte-for-byte preservation after
   rejection. This is a data-loss bug, not an independently established
   privilege escalation.
5. **Backup integrity: timestamp collisions and retention.** Predictable
   millisecond filenames could overwrite earlier backups. Unique mktemp
   files now preserve separate snapshots even with an identical clock value.
   Backups have mode 0600 and retain backup-time mtimes rather than copying
   source mtimes. Temporary generated files are cleaned on failure.

## Other observations and remaining limits

- Shell arguments are quoted or passed as positional parameters. No additional
  shell-command injection was identified in the reviewed paths. Lua escaping
  is still essential despite correct shell quoting.
- The save helper accepts Lua on stdin; its markers and monitor-call checks
  are structural checks, not a Lua sandbox. Invoking it directly with hostile
  Lua requires a caller already able to run commands as the same local user.
  Do not expose it to remote callers or use it with elevated privileges.
- Concurrent external edits or separate helper invocations can still race the
  read/replace sequence; atomic rename prevents partial writes, not lost
  updates. This remains a local config-integrity limitation.
- Save still intentionally acts as Keep after generation succeeds, before the
  helper reports success. A later filesystem failure therefore cancels the
  countdown. Restore clears its snapshot before the restore process exits,
  and its exit handler does not report restore failure. These are existing
  recovery/UX limitations; this patch preserves rollback on validation errors
  but does not redesign the asynchronous state machine.
- Numeric metadata can still produce invalid geometry (for example infinity
  or an unsupported transform). Numeric conversion/encoding prevents it
  becoming source syntax, but domain validation could improve robustness.
- Full Quickshell UI, remote-image behavior, actual connector matching,
  compositor error handling and physical monitor recovery require testing
  on Omarchy. This review is not a guarantee that no other defects exist.

## Verification

Passed on this macOS host:

- Existing model suite.
- 165 restricted Lua executions plus invalid connector rejection checks,
  using Lua 5.1.5 and stubbed monitor calls.
- Actual QML action functions extracted into a JS harness with process stubs.
- Shell splice suite, including malformed markers, identical backup timestamps,
  private backups, retention, external edits and missing files.
- Bash syntax and git diff whitespace checks.

Tests never access real monitor configuration or the running compositor.
The repository now declares CommonJS explicitly so tests also work when
cloned below a parent directory configured for ES modules. No npm packages
are required. Run `npm test` with Node and Lua available (or use the individual
commands in README.md); set `LUA` to override the interpreter path.

Marketplace validation and maintainer approval must target the full commit SHA
containing these fixes. Local test results do not replace marketplace validation
or testing on Omarchy.
