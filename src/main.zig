const std = @import("std");

const slotmap = @import("slotmap");

const Entity = struct { name: []const u8, hp: u32 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var world = try slotmap.SlotMap(Entity).init(gpa);
    defer world.deinit();

    _ = try world.insert(.{ .name = "hero", .hp = 100 });
    const goblin = try world.insert(.{ .name = "goblin", .hp = 20 });
    _ = try world.insert(.{ .name = "slime", .hp = 8 });

    std.debug.print("live entities: {d}\n", .{world.count()});

    // Defeat a goblin
    _ = world.remove(goblin);
    std.debug.print("after removing goblin: live={d}\n", .{world.count()});

    std.debug.print("old goblin key still valid? {}\n", .{world.get(goblin) != null});

    // Add a new enemy
    const orc = try world.insert(.{ .name = "orc", .hp = 30 });
    std.debug.print("orc index={d} reused goblin's slot index={d}\n", .{ orc.index, goblin.index });
    std.debug.print("but old goblin key is STILL invalid? {}\n", .{world.get(goblin) == null});

    // iterate a entity that is alive
    std.debug.print("--- roster ---\n", .{});
    var it = world.iterator();
    while (it.next()) |e| {
        std.debug.print("  [{d}] {s} (hp {d})\n", .{ e.key.index, e.value_ptr.name, e.value_ptr.hp });
    }
}
