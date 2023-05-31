const std = @import("std");
const ArrayList = std.ArrayList;

fn bench(allocator: std.mem.Allocator) !void {
    var arr = try ArrayList(u8).initCapacity(allocator, 128);
    defer arr.deinit();

    var i: u8 = 0;
    while (i < 128) {
        try arr.append(i);
        i += 1;
    }

    while (i > 0) {
        i -= 1;
        const j = arr.pop();
        std.debug.assert(i == j);
    }
}

pub fn main() !void {
    var buffer: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    for (0..10000) |_| {
        try bench(allocator);
    }
}
