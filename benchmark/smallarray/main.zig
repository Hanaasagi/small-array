const std = @import("std");
const SmallArray = @import("smallarray").SmallArray;

fn bench() !void {
    const allocator = std.heap.page_allocator;

    var arr = SmallArray(u8, 128).init(allocator);
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
    for (0..10000) |_| {
        try bench();
    }
}
