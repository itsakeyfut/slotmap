# Design Notes

This document records **why slotmap has the shape it does**, the trade-offs that
were chosen deliberately, and the conditions under which each decision should be
revisited. It is not a roadmap and not a list of missing features. If something is
absent, this file should explain whether that is an accident (to be fixed) or a
choice (to be defended).

The intended reader is a future maintainer — most likely the author — who is about
to add or change something and wants to know: *was this considered, what does it
cost, and what should trigger doing it?*

## Design principles

1. **Reliability over feature count.** A small, auditable core that is obviously
   correct beats a large surface that is hard to trust. This library is meant to be
   depended on for a long time.
2. **Add features on demand, not on speculation.** New capability is added when
   LegendEngine (or another concrete user) demonstrably needs it — not because
   another ecosystem's slot map has it.
3. **Prefer Zig-native solutions.** Where another language's slot map reaches for a
   particular API, ask whether Zig's `comptime`, optionals, or allocators offer a
   better-fitting answer before copying the shape.
4. **Guard the core invariant above all.** Every change is judged first by whether it
   keeps the safety guarantee below easy to verify.

## The core invariant

> A `Key` can only read or mutate the value it was issued for. Once that value is
> removed, the key is inert forever.

This is implemented with a per-slot generation counter. `insert` returns
`Key{ index, generation }`; `remove` bumps the slot's generation so any outstanding
key for that slot stops matching. Every accessor (`get`, `getPtr`, `contains`,
`remove`) checks the generation before touching the value. Everything else in the
design is subordinate to keeping this invariant simple and correct.

## Current design and rationale

### Sparse slot storage

Values live in place inside a single `slots: []Slot`. Removed slots become holes and
are recycled through an intrusive free list (`free_head` + `next_free`).

- **Chosen benefit:** one allocation, O(1) insert / get / remove, and a value's
  address does not change just because *other* entries are removed.
- **Accepted cost:** iteration walks the holes. As the map fragments, `iterator`
  touches unoccupied slots and cache locality degrades. This is a conscious trade —
  see *Dense storage* under considered alternatives.

### Generational keys (`index: u32`, `generation: u32`)

- Fresh slots start at generation `1`; `remove` does `generation +%= 1` (wrapping).
- The key is 8 bytes, trivially copyable, and safe to store anywhere.
- **Capacity bound:** indices are `u32`, and `maxInt(u32)` is reserved as the
  free-list `nil` sentinel, so the map holds up to ~2³² slots. Far beyond any
  realistic use; noted only for completeness.
- **Generation wraparound (ABA):** because generation is `u32`, removing and reusing
  *the same slot* 2³² times wraps it back to a previously issued value. A key that
  old would then alias a live entry. This is a theoretical soundness limit, not a
  practical concern for game-scale workloads. Revisit only if a workload could
  plausibly approach billions of reuse cycles on a single slot (see *Packed u64
  keys*, which would make this bound **worse**, and *Reserved null key*).

### Growth by doubling

Backing storage grows `0 → 8 → 16 → 32 → …`, giving amortized O(1) insert. `grow()`
allocates a new array, copies, and frees the old one.

### Pointer semantics — important and subtle

`getPtr` and `iterator` hand out pointers into the slot array. **Those pointers are
valid only until the next mutation that reallocates.** Because `insert` may trigger
`grow()`, and `grow()` replaces the whole backing array, a pointer held across an
`insert` can dangle:

```zig
const p = map.getPtr(k).?;   // valid now
_ = try map.insert(x);       // may grow() → reallocates → p may now dangle
p.* = 5;                     // ⚠️ use-after-free if a grow happened
```

Within a run of reads with no intervening insert, pointers are stable. **This is a
deliberate, documented limitation, not a bug.** Callers should re-fetch via `getPtr`
after any insert. If a real need for pointers that survive inserts appears, that is a
backing-store decision (see *Segmented storage*), not a small patch.

### Error and allocation surface

Only `init` and `insert` allocate, so only they return `!`. `get` / `getPtr` /
`contains` / `remove` never allocate and return optionals / `bool`. Keeping the
failible surface this small is intentional and worth preserving.

## Considered but not adopted

| Alternative | What it buys | What it costs | Firing condition |
| --- | --- | --- | --- |
| **Dense storage** (values packed contiguously + an index-redirection table) | Fully contiguous iteration, no holes | Values move on removal → **no pointer stability**; extra indirection on `get` | Entity counts reach tens of thousands *and* iteration shows up in profiles. Add a **separate `DenseSlotMap(T)` type** with different guarantees — do not change this one. |
| **Segmented / chunked backing store** | Pointers stay valid across inserts (no realloc) | More complex indexing, slightly slower access | The "pointer dangles across insert" limitation causes real bugs or friction in engine code. |
| **Packed `u64` keys** | Single-word handles, cheaper to store en masse | Caps index/generation bit-widths; bit-twiddling; **shrinks the generation space, worsening the ABA bound** | Storing very large numbers of handles becomes a measured memory problem. |
| **Secondary maps** (attach extra per-key data outside the primary store) | Rust's `SecondaryMap` use case | Copying Rust's API may not be the right Zig shape | A concrete need appears. Prefer a Zig-native answer first — a parallel `SlotMap`, a `std.AutoHashMap` keyed by `Key`, or `comptime` composition — before porting another library's design. |
| **Reserved null key (`Key.none`)** | An in-band "no entity" value without `?Key`'s size cost | Steals one generation value; adds a wrap special-case | A use case needs to embed nullable handles compactly. See note below. |

**On the null key.** There is currently no canonical invalid key; the Zig-idiomatic
choice is `?Key`. Generation starts at `1`, so `Key{ _, 0 }` is *almost* always
invalid — but not guaranteed, because generation can wrap to `0`. If a compact null
is ever wanted, reserve generation `0` permanently (skip `0` when wrapping in
`remove`) so `Key{ _, 0 }` becomes a guaranteed-invalid `Key.none`. Until then,
prefer `?Key`.

## Features under consideration

Each of these is *intentionally absent* until its condition is met. Listing the
condition is the point: it distinguishes "not built yet, on purpose" from "missing."

| Feature | What it does | When to add it |
| --- | --- | --- |
| `initCapacity` / `reserve` | Pre-allocate slots up front | Per-frame allocation churn from incremental `grow()` shows up in profiles. |
| `clear` | Empty the map, invalidating all outstanding keys | A reset/level-transition use case appears. **See the trap below.** |
| `realloc`-based growth | Grow in place when the allocator can, avoiding the copy | `grow()`'s copy cost appears in profiles. Switch `alloc` + `@memcpy` + `free` to `allocator.realloc`. |
| Iteration variants | Values-only / keys-only iterators | Call sites want the ergonomics. |

**The `clear` trap.** A correct `clear` **must bump the generation of every occupied
slot** (or reset the whole array to fresh generations). The cheap version — setting
`next_fresh = 0` and `free_head = nil` — reuses slots without changing their
generations, so keys issued before the clear would silently match values inserted
after it. That breaks the core invariant. Do not ship the cheap version.

## Explicit non-goals

Declaring these keeps the library's scope sharp. They are not oversights.

- **Thread safety.** The map is single-threaded; callers synchronize externally.
- **Serialization.** The caller's responsibility. `Key` is trivially serializable,
  but faithfully restoring the internal free list and generation counters is out of
  scope and easy to get subtly wrong.
- **Feature parity with other ecosystems' slot maps.** The value here is a robust,
  engine-proven slot map for Zig — not a checklist match against Rust's `slotmap` or
  any other library. Features are earned by real use, not copied.

## Using this document

When a need arises:

1. Check **Features under consideration** — the firing condition tells you whether
   now is the time, and the notes flag the traps.
2. Check **Considered but not adopted** — if it's there, you'll find why it isn't in
   and what adding it would cost.
3. If it's an **explicit non-goal**, that's a scope decision; reconsider the scope
   deliberately before crossing it, and record the new reasoning here.

When a decision changes, update this file with the new rationale. The history of
*why* is more valuable than the list of *what*.
