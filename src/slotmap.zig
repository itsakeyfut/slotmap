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
