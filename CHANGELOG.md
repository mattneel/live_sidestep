# Changelog

## 0.1.0 — Unreleased

### Added

- `LiveSidestep.open/2`, `close/1`, `view_pid/1`, `restart_view/1`, and
  `inspect_native/2`, with validated startup options and explicit session ownership.
- LiveView-shaped native callbacks, Phoenix assigns, function constructors, and
  `~V` templates for columns, wrapping rows, lists, labels, buttons, and inputs.
- Main-thread AppKit host using Sidestep pinned to
  `626422b1fa52fc14af13976c5c90b4efd657b1d7`; real native controls and field editing,
  keyed object retention, native scrolling, and intrinsic text measurement.
- Separate callback workers, validated assigns checkpoints, bounded worker
  recovery, and temporary sessions that never resurrect a closed native window.
- Strict acknowledged snapshot/patch protocol, atomic tree validation, bounded
  I/O and semantic queues, mailbox credits, and explicit overload/timeout errors.
- Full-value revisioned input events, stale-echo protection, incarnation-based
  lifetime checks, UTF-16 selection mapping, and deferred composition transforms.
- Streaming bounded native inspection of control identity, frames, editor state,
  applied revisions, host PID, and native run-loop ticks.
- Locked native source builds integrated with Mix, checksum-verified binding
  generation, native artifacts under application `priv`, source package metadata,
  release support, and upstream license notices.
- Interactive demo, native lifecycle/topology regression coverage, real headless
  Wayland input acceptance, and an expanded `mix ci` native/Elixir quality gate.
- Per-line vertical centering for mixed-height native row controls, including
  count labels next to buttons, without transiently repositioning native editors.

### Acceptance boundaries

- Linux x64/Wayland is the exercised graphical target. macOS selects system
  AppKit but has not been validated by this release's CI or acceptance runs.
  X11 and Windows are not supported targets.
- Real IME sessions have not been exercised. Composition transitions and UTF-16
  reconciliation have state-level regression coverage, not end-to-end IME proof.
- Native inspection/publication acknowledgement is not a presentation fence;
  run-loop tick counts are not presented-frame metrics.
- Checkpoints are in-memory presentation recovery, not durable transactions or
  rollback of external callback effects.
