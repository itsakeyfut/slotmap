# slotmap

[![CI](https://github.com/itsakeyfut/slotmap/actions/workflows/ci.yml/badge.svg)](https://github.com/itsakeyfut/slotmap/actions/workflows/ci.yml)
[![Zig](https://img.shields.io/badge/zig-0.16.0-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A generational slot map for Zig — stable handles that survive deletion.

## Why generational keys?

The naive approach to handing out handles is to use a plain array index. It works
until you delete something:

```
1. insert("goblin")  -> index 3
2. remove(index 3)                 // slot 3 is now free
3. insert("orc")     -> index 3    // slot 3 is reused for a *different* value
4. get(index 3)      -> "orc"      // the old goblin handle now silently points at the orc
```

That stale index is a bug that is hard to catch: it does not crash, it returns the
*wrong* value. Anyone still holding the old `goblin` handle now reads or mutates the
orc.

A slot map fixes this by pairing every index with a **generation counter**. The key
you get back is `{ index, generation }`. Each time a slot is freed, its generation is
bumped, so a reused slot no longer matches keys handed out for its previous occupant:

```
1. insert("goblin")  -> { index: 3, generation: 1 }
2. remove(...)                     // slot 3's generation becomes 2
3. insert("orc")     -> { index: 3, generation: 2 }
4. get({3, 1})       -> null       // stale goblin key is rejected at the value level
5. get({3, 2})       -> "orc"      // the current key still works
```

The check is `O(1)` — a single integer comparison — so you get use-after-free safety
for handles without a hash lookup and without reference counting. This is the standard
backing store for entities in an ECS, nodes in a scene graph, or any pool of objects
that are frequently created and destroyed while other things hold references to them.

## Install

Fetch the package (pins to a tagged release):

```sh
zig fetch --save "git+https://github.com/itsakeyfut/slotmap#v0.1.0"
```

Then wire the module into your `build.zig`:

```zig
const slotmap = b.dependency("slotmap", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("slotmap", slotmap.module("slotmap"));
```

Requires Zig `0.16.0` or newer.

## Usage

```zig
const std = @import("std");
const SlotMap = @import("slotmap").SlotMap;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var map = try SlotMap(u32).init(gpa.allocator());
    defer map.deinit();

    const key = try map.insert(42);

    std.debug.print("{?}\n", .{map.get(key)}); // 42

    _ = map.remove(key);

    std.debug.print("{?}\n", .{map.get(key)}); // null — the key is now stale
}
```

### As an entity store (ECS-style)

Because keys stay valid across unrelated insertions and removals, they make good
long-lived entity handles. Systems can store a `Key` and safely ask "is this entity
still alive?" every frame:

```zig
const std = @import("std");
const SlotMap = @import("slotmap").SlotMap;

const Entity = struct { name: []const u8, hp: u32 };

pub fn tick(world: *SlotMap(Entity), target: SlotMap(Entity).Key) void {
    // `getPtr` returns null if the entity was destroyed since we stored `target`,
    // so a dangling handle can never corrupt a live slot.
    if (world.getPtr(target)) |e| {
        e.hp -|= 10;
        if (e.hp == 0) _ = world.remove(target);
    }
}

pub fn render(world: *SlotMap(Entity)) void {
    var it = world.iterator();
    while (it.next()) |entry| {
        // iterates only live entities, in insertion-slot order
        std.debug.print("[{d}] {s} (hp {d})\n", .{
            entry.key.index, entry.value_ptr.name, entry.value_ptr.hp,
        });
    }
}
```

A runnable version lives in [`examples/basic.zig`](examples/basic.zig):

```sh
zig build examples
```

## API

`SlotMap(comptime T: type)` returns a map type storing values of type `T`.

| Method | Signature | Description |
| --- | --- | --- |
| `init` | `(allocator) !Self` | Create an empty map. Allocates lazily on first insert. |
| `deinit` | `(*Self) void` | Free all backing storage. |
| `insert` | `(*Self, T) !Key` | Store a value and return a stable key. Reuses freed slots. |
| `get` | `(Self, Key) ?T` | Return a copy of the value, or `null` if the key is stale/unknown. |
| `getPtr` | `(*Self, Key) ?*T` | Return a mutable pointer to the value, or `null` if stale. |
| `contains` | `(Self, Key) bool` | Whether the key currently refers to a live value. |
| `remove` | `(*Self, Key) ?T` | Remove and return the value, or `null` if the key is stale. Bumps the slot's generation. |
| `count` | `(Self) usize` | Number of live values. |
| `iterator` | `(*Self) Iterator` | Iterate live entries as `{ key, value_ptr }`, in slot order. |

`Key` is `struct { index: u32, generation: u32 }` — cheap to copy and store.

A `get`/`getPtr`/`remove`/`contains` call returns `null`/`false` when the key does not
match a live slot: either the value was removed, or the slot has since been reused by a
newer generation. This is the core guarantee — a stale handle can never read or mutate
an unrelated value.

## License

[MIT](LICENSE) © itsakeyfut
