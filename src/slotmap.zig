const std = @import("std");

pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();
        const nil: u32 = std.math.maxInt(u32);

        pub const Key = struct {
            index: u32,
            generation: u32,
        };

        const Slot = struct {
            generation: u32,
            occupied: bool,
            next_free: u32,
            value: T,
        };

        slots: []Slot,
        next_fresh: u32,
        free_head: u32,
        live: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .slots = try allocator.alloc(Slot, 0),
                .next_fresh = 0,
                .free_head = nil,
                .live = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        fn grow(self: *Self) !void {
            const old_cap = self.slots.len;
            const new_cap = if (old_cap == 0) 8 else old_cap * 2;
            const new_slots = try self.allocator.alloc(Slot, new_cap);
            @memcpy(new_slots[0..old_cap], self.slots[0..old_cap]);
            self.allocator.free(self.slots);
            self.slots = new_slots;
        }

        pub fn insert(self: *Self, value: T) !Key {
            if (self.free_head != nil) {
                const idx = self.free_head;
                const slot = &self.slots[idx];
                self.free_head = slot.next_free;
                slot.occupied = true;
                slot.value = value;
                self.live += 1;
                return .{ .index = idx, .generation = slot.generation };
            }
            if (self.next_fresh == self.slots.len) try self.grow();
            const idx = self.next_fresh;
            self.slots[idx] = .{ .generation = 1, .occupied = true, .next_free = nil, .value = value };
            self.next_fresh += 1;
            self.live += 1;
            return .{ .index = idx, .generation = 1 };
        }

        pub fn contains(self: Self, key: Key) bool {
            if (key.index >= self.next_fresh) return false;
            const slot = self.slots[key.index];
            return slot.occupied and slot.generation == key.generation;
        }

        pub fn get(self: Self, key: Key) ?T {
            if (!self.contains(key)) return null;
            return self.slots[key.index].value;
        }

        pub fn getPtr(self: *Self, key: Key) ?*T {
            if (!self.contains(key)) return null;
            return &self.slots[key.index].value;
        }

        pub fn remove(self: *Self, key: Key) ?T {
            if (!self.contains(key)) return null;
            const slot = &self.slots[key.index];
            const value = slot.value;
            slot.occupied = false;
            slot.generation +%= 1;
            slot.next_free = self.free_head;
            self.free_head = key.index;
            self.live -= 1;
            return value;
        }

        pub fn count(self: Self) usize {
            return self.live;
        }

        pub const Entry = struct { key: Key, value_ptr: *T };

        pub const Iterator = struct {
            map: *Self,
            index: u32,

            pub fn next(self: *Iterator) ?Entry {
                while (self.index < self.map.next_fresh) {
                    const i = self.index;
                    self.index += 1;
                    const slot = &self.map.slots[i];
                    if (slot.occupied) {
                        return .{
                            .key = .{ .index = i, .generation = slot.generation },
                            .value_ptr = &slot.value,
                        };
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .map = self, .index = 0 };
        }
    };
}

const testing = std.testing;

test "insert / get / count" {
    var m = try SlotMap(u32).init(testing.allocator);
    defer m.deinit();

    const a = try m.insert(10);
    const b = try m.insert(20);
    try testing.expectEqual(@as(usize, 2), m.count());
    try testing.expectEqual(@as(?u32, 10), m.get(a));
    try testing.expectEqual(@as(?u32, 20), m.get(b));
}

test "stale key is rejected even after slot reuse" {
    var m = try SlotMap(u32).init(testing.allocator);
    defer m.deinit();

    const k1 = try m.insert(10);
    try testing.expectEqual(@as(?u32, 10), m.get(k1));

    _ = m.remove(k1);
    try testing.expect(m.get(k1) == null);

    const k2 = try m.insert(20);
    try testing.expectEqual(k1.index, k2.index);
    try testing.expect(k1.generation != k2.generation);
    try testing.expect(m.get(k1) == null);
    try testing.expectEqual(@as(?u32, 20), m.get(k2));
}

test "getPtr mutates in place" {
    var m = try SlotMap(u32).init(testing.allocator);
    defer m.deinit();

    const k = try m.insert(1);
    if (m.getPtr(k)) |p| p.* = 99;
    try testing.expectEqual(@as(?u32, 99), m.get(k));
}

test "grow across many inserts" {
    var m = try SlotMap(u32).init(testing.allocator);
    defer m.deinit();

    var keys: [100]@TypeOf(m).Key = undefined;
    for (0..100) |i| keys[i] = try m.insert(@intCast(i));
    try testing.expectEqual(@as(usize, 100), m.count());
    for (0..100) |i| try testing.expectEqual(@as(?u32, @intCast(i)), m.get(keys[i]));
}

test "iterator visits only live entries" {
    var m = try SlotMap(u32).init(testing.allocator);
    defer m.deinit();

    const a = try m.insert(1);
    const b = try m.insert(2);
    const c = try m.insert(3);
    _ = m.remove(b);

    var sum: u32 = 0;
    var n: usize = 0;
    var it = m.iterator();
    while (it.next()) |e| {
        sum += e.value_ptr.*;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u32, 4), sum); // 1 + 3
    _ = a;
    _ = c;
}

test "double remove returns null and does not double-decrement count" {
    var m = try SlotMap(u32).init(testing.allocator);
    defer m.deinit();

    const a = try m.insert(10);
    const b = try m.insert(20);
    try testing.expectEqual(@as(usize, 2), m.count());

    try testing.expectEqual(@as(?u32, 10), m.remove(a));
    try testing.expectEqual(@as(usize, 1), m.count());

    // Second remove of the same (now stale) key is a no-op.
    try testing.expect(m.remove(a) == null);
    try testing.expectEqual(@as(usize, 1), m.count());

    // b is unaffected.
    try testing.expectEqual(@as(?u32, 20), m.get(b));
}

test "stale key is rejected by every accessor, including after slot reuse" {
    var m = try SlotMap(u32).init(testing.allocator);
    defer m.deinit();

    const k = try m.insert(10);
    _ = m.remove(k);

    // Directly after removal: all accessors reject the stale key.
    try testing.expect(m.get(k) == null);
    try testing.expect(m.getPtr(k) == null);
    try testing.expect(!m.contains(k));
    try testing.expect(m.remove(k) == null);

    // Reuse the slot with a new generation, then re-check the old key.
    const k2 = try m.insert(20);
    try testing.expectEqual(k.index, k2.index);
    try testing.expect(k.generation != k2.generation);
    try testing.expect(m.get(k) == null);
    try testing.expect(m.getPtr(k) == null);
    try testing.expect(!m.contains(k));
    try testing.expect(m.remove(k) == null);
    // The new key still works.
    try testing.expectEqual(@as(?u32, 20), m.get(k2));
}

test "iterator reflects removals and empties fully" {
    var m = try SlotMap(u32).init(testing.allocator);
    defer m.deinit();

    const a = try m.insert(1);
    const b = try m.insert(2);
    const c = try m.insert(3);
    const d = try m.insert(4);
    _ = m.remove(b);
    _ = m.remove(d);

    // Only live entries (a=1, c=3) are visited, with correct values.
    var sum: u32 = 0;
    var n: usize = 0;
    var it = m.iterator();
    while (it.next()) |e| {
        try testing.expect(m.contains(e.key));
        sum += e.value_ptr.*;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(m.count(), n);
    try testing.expectEqual(@as(u32, 4), sum); // 1 + 3
    _ = a;
    _ = c;

    // After removing everything, the iterator yields nothing immediately.
    var drain_it = m.iterator();
    while (drain_it.next()) |e| _ = m.remove(e.key);
    try testing.expectEqual(@as(usize, 0), m.count());
    var it2 = m.iterator();
    try testing.expect(it2.next() == null);
}

test "generation wraps from maxInt to 0 and still rejects the stale key" {
    // White-box: forcing a real 2^32-cycle wrap is infeasible, so we set the
    // slot's generation to maxInt directly and exercise the wrap boundary.
    // This documents the CURRENT behavior (wrap -> 0) and the immediate-reuse
    // safety. The astronomically-rare true ABA collision (a key from 2^32
    // reuse cycles ago) cannot be reproduced in bounded time and is out of scope.
    const Key = SlotMap(u32).Key;
    var m = try SlotMap(u32).init(testing.allocator);
    defer m.deinit();

    const k = try m.insert(10);
    m.slots[k.index].generation = std.math.maxInt(u32);
    const kmax = Key{ .index = k.index, .generation = std.math.maxInt(u32) };
    try testing.expect(m.contains(kmax));

    _ = m.remove(kmax); // generation: maxInt +% 1 == 0
    try testing.expectEqual(@as(u32, 0), m.slots[kmax.index].generation);
    try testing.expect(!m.contains(kmax));

    const k2 = try m.insert(20); // reuses the slot; generation is now 0
    try testing.expectEqual(@as(u32, 0), k2.generation);
    try testing.expect(m.contains(k2));
    try testing.expect(m.get(kmax) == null); // old maxInt key rejected vs gen 0
    try testing.expectEqual(@as(?u32, 20), m.get(k2));
}

test "insert failure during grow is atomic: state survives and recovers" {
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var m = try SlotMap(u32).init(fa.allocator());
    defer m.deinit();

    const Key = SlotMap(u32).Key;
    var keys: [8]Key = undefined;
    // Inserts 1..8 succeed (grow 0->8 is the single allowed allocation).
    for (0..8) |i| keys[i] = try m.insert(@intCast(i));
    try testing.expectEqual(@as(usize, 8), m.count());

    // Insert 9 forces grow 8->16, which the failing allocator rejects.
    try testing.expectError(error.OutOfMemory, m.insert(99));

    // Core invariant: failure did not corrupt state.
    try testing.expectEqual(@as(usize, 8), m.count());
    for (0..8) |i| try testing.expectEqual(@as(?u32, @intCast(i)), m.get(keys[i]));

    // Recovery (white-box): swap to a healthy allocator; further inserts work.
    // (FailingAllocator is sticky, so the same instance cannot recover.)
    m.allocator = testing.allocator;
    const k9 = try m.insert(99);
    try testing.expectEqual(@as(usize, 9), m.count());
    try testing.expectEqual(@as(?u32, 99), m.get(k9));
}

test "grow relocates the backing array (pointer-invalidation hazard is real)" {
    var m = try SlotMap(u32).init(testing.allocator);
    defer m.deinit();

    _ = try m.insert(0); // triggers first grow 0->8
    // Fill to the growth boundary so the next insert reallocates.
    while (m.next_fresh < m.slots.len) _ = try m.insert(1);
    const before = m.slots.ptr;
    _ = try m.insert(2); // grows 8->16, relocating the array
    try testing.expect(m.slots.ptr != before);
}

test "safe pattern: re-fetch getPtr after an insert that grows" {
    var m = try SlotMap(u32).init(testing.allocator);
    defer m.deinit();

    const k = try m.insert(100);
    // Read via getPtr (valid now).
    try testing.expectEqual(@as(u32, 100), m.getPtr(k).?.*);

    // Fill to the growth boundary, then insert to force a reallocation.
    while (m.next_fresh < m.slots.len) _ = try m.insert(0);
    _ = try m.insert(0); // reallocates the backing array

    // The recommended pattern: re-fetch after the insert, then it is correct.
    const p = m.getPtr(k) orelse return error.TestExpectedNonNull;
    try testing.expectEqual(@as(u32, 100), p.*);
    p.* = 101;
    try testing.expectEqual(@as(?u32, 101), m.get(k));
}

const OracleEntry = struct { key: SlotMap(u32).Key, val: u32 };

const Op = enum { insert, remove_live, get_live, getptr_mutate_live, touch_stale };

// Drives a random sequence of operations against SlotMap(u32) and checks it
// against a black-box oracle (a live-key model + a stale-key list). Generic over
// `Source` so the same logic runs from a seeded PRNG and from std.testing.Smith.
fn runSequence(comptime Source: type, src: *Source, gpa: std.mem.Allocator) !void {
    var map = try SlotMap(u32).init(gpa);
    defer map.deinit();

    var live: std.ArrayList(OracleEntry) = .empty;
    defer live.deinit(gpa);
    var stale: std.ArrayList(SlotMap(u32).Key) = .empty;
    defer stale.deinit(gpa);

    while (!src.done()) {
        var op = src.nextOp();
        // Empty-collection guard: remap ops with an empty target to `insert`,
        // else index(0) would panic (and read as a false fuzzer crash).
        switch (op) {
            .remove_live, .get_live, .getptr_mutate_live => if (live.items.len == 0) {
                op = .insert;
            },
            .touch_stale => if (stale.items.len == 0) {
                op = .insert;
            },
            .insert => {},
        }

        switch (op) {
            .insert => {
                const v = src.value();
                const k = try map.insert(v);
                try testing.expectEqual(@as(?u32, v), map.get(k));
                try testing.expect(map.contains(k));
                try live.append(gpa, .{ .key = k, .val = v });
            },
            .remove_live => {
                const i = src.index(live.items.len);
                const e = live.items[i];
                try testing.expectEqual(@as(?u32, e.val), map.remove(e.key));
                _ = live.swapRemove(i);
                try stale.append(gpa, e.key);
            },
            .get_live => {
                const i = src.index(live.items.len);
                const e = live.items[i];
                try testing.expectEqual(@as(?u32, e.val), map.get(e.key));
                try testing.expect(map.contains(e.key));
                const p = map.getPtr(e.key) orelse return error.TestExpectedNonNull;
                try testing.expectEqual(e.val, p.*);
            },
            .getptr_mutate_live => {
                const i = src.index(live.items.len);
                const nv = src.value();
                const p = map.getPtr(live.items[i].key) orelse return error.TestExpectedNonNull;
                p.* = nv;
                live.items[i].val = nv;
            },
            .touch_stale => {
                const i = src.index(stale.items.len);
                const k = stale.items[i];
                try testing.expect(map.get(k) == null);
                try testing.expect(map.getPtr(k) == null);
                try testing.expect(!map.contains(k));
                try testing.expect(map.remove(k) == null);
            },
        }

        // Invariants after every op.
        try testing.expectEqual(live.items.len, map.count());
        for (live.items) |e| {
            try testing.expectEqual(@as(?u32, e.val), map.get(e.key));
            try testing.expect(map.contains(e.key));
        }
        // The iterator yields exactly the live set (compare as a set on index).
        var seen = std.AutoHashMap(u32, u32).init(gpa);
        defer seen.deinit();
        var it = map.iterator();
        var n: usize = 0;
        while (it.next()) |entry| {
            try seen.put(entry.key.index, entry.value_ptr.*);
            n += 1;
        }
        try testing.expectEqual(live.items.len, n);
        for (live.items) |e| {
            try testing.expectEqual(@as(?u32, e.val), seen.get(e.key.index));
        }
    }
}

const PrngSource = struct {
    random: std.Random,
    remaining: usize,

    fn done(self: *PrngSource) bool {
        if (self.remaining == 0) return true;
        self.remaining -= 1;
        return false;
    }
    fn nextOp(self: *PrngSource) Op {
        return self.random.enumValueWithIndex(Op, usize);
    }
    fn value(self: *PrngSource) u32 {
        return self.random.int(u32);
    }
    fn index(self: *PrngSource, len: usize) usize {
        return self.random.uintLessThan(usize, len);
    }
};

test "property: random op sequences match the oracle" {
    const seeds = [_]u64{ 0x1234, 0xdeadbeef, 0xcafef00d, 1, 42, 99_999 };
    for (seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        var src = PrngSource{ .random = prng.random(), .remaining = 500 };
        try runSequence(PrngSource, &src, testing.allocator);
    }
}
