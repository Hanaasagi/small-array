const std = @import("std");
const BoundedArray = std.BoundedArray;

fn bench() !void {
    var arr = try BoundedArray(u8, 128).init(0);

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
