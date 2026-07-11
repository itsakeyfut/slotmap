const slotmap = @import("slotmap.zig");
pub const SlotMap = slotmap.SlotMap;

test {
    @import("std").testing.refAllDecls(@This());
    _ = slotmap;
}
