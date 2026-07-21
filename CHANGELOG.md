# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `remove` now reserves generation `0` (it skips `0` on wraparound), making the
  "a live slot never has generation `0`" invariant unconditional. This is internal
  hardening with no public API change; the recommended way to represent an absent
  key remains `?Key`.

## [0.1.0] - 2026-07-12

Initial release.

### Added

- `SlotMap(comptime T)` — a generational slot map with `O(1)` insert, get, and remove.
- Generational keys (`Key { index, generation }`) that reject stale handles after a
  slot is reused.
- Core API: `init`, `deinit`, `insert`, `get`, `getPtr`, `contains`, `remove`, `count`.
- `iterator()` over live entries yielding `{ key, value_ptr }`.
- `examples/basic.zig` demonstrating entity-store usage.

[Unreleased]: https://github.com/itsakeyfut/slotmap/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/itsakeyfut/slotmap/releases/tag/v0.1.0
