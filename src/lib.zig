const std = @import("std");
const testing = std.testing;

// fn Buffer(comptime T: type, comptime stack_capacity: usize) type {
//     return union(enum) {
//         stack: [stack_capacity]T align(@alignOf(T)),
//         heap: std.ArrayList(T),
//     };
// }

/// Useful to pass around small explicitly-aligned arrays whose exact size is
/// only known at runtime, but whose maximum size is known at comptime, without
/// requiring an `Allocator`.
pub fn SmallArray(comptime T: type, comptime stack_capacity: usize) type {
    const Buffer = union(enum) {
        stack: [stack_capacity]T align(@alignOf(T)),
        heap: std.ArrayList(T),
    };

    return struct {
        allocator: std.mem.Allocator,

        len: usize,

        buf: Buffer,

        const Self = @This();

        // --------------------------------------------------------------------------------
        //                                  Public API
        // --------------------------------------------------------------------------------

        pub fn init(allocator: std.mem.Allocator) Self {
            // TODO: ?
            // if (len > stack_capacity) {
            //     var heap = std.ArrayList(T).init(allocator);
            //     self.buf = Buffer{ .heap = heap };
            // }

            return Self{
                .allocator = allocator,
                .len = 0,
                .buf = Buffer{ .stack = undefined },
            };
        }

        pub fn deinit(self: *Self) void {
            switch (self.buf) {
                .stack => {},
                .heap => {
                    self.buf.heap.deinit();
                },
            }
        }

        /// Return the maximum length of a slice.
        pub fn capacity(self: Self) usize {
            switch (self.buf) {
                .stack => |b| {
                    return b.len;
                },
                .heap => |b| {
                    return b.capacity;
                },
            }
        }

        pub fn resize(self: *Self, new_len: usize) !void {
            switch (self.buf) {
                .stack => {
                    if (new_len > stack_capacity) {
                        try self.moveToHeap();
                        return self.resize(new_len);
                    }
                    self.len = new_len;
                },
                .heap => {
                    try self.buf.heap.resize(new_len);
                    self.len = new_len;
                },
            }
        }

        pub fn isInStack(self: *Self) bool {
            return (std.meta.activeTag(self.buf) == .stack);
        }

        /// Check that the slice can hold at least `additional_count` items.
        pub fn ensureUnusedCapacity(self: *Self, additional_count: usize) !void {
            if (std.meta.activeTag(self.buf) == .stack) {
                if (self.len + additional_count <= stack_capacity) {
                    return;
                } else {
                    try self.moveToHeap();
                }
            }

            return self.buf.heap.ensureUnusedCapacity(additional_count);
        }

        /// Return a slice of only the extra capacity after items.
        /// This can be useful for writing directly into it.
        /// Note that such an operation must be followed up with a
        /// call to `resize()`
        pub fn unusedCapacitySlice(self: *Self) []align(@alignOf(T)) T {
            switch (self.buf) {
                .stack => |*buf| {
                    return buf[self.len..];
                },
                .heap => |buf| {
                    return buf.unusedCapacitySlice();
                },
            }
        }

        /// Increase length by 1, returning pointer to the new item.
        /// Asserts that there is space for the new item.
        pub fn addOneAssumeCapacity(self: *Self) *T {
            self.len += 1;
            return &self.slice()[self.len - 1];
        }

        /// Resize the slice, adding `n` new elements, which have `undefined` values.
        /// The return value is a slice pointing to the uninitialized elements.
        pub fn addManyAsArray(self: *Self, comptime n: usize) !*align(@alignOf(T)) [n]T {
            const prev_len = self.len;
            try self.resize(self.len + n);
            return self.slice()[prev_len..][0..n];
        }

        /// Increase length by 1, returning a pointer to the new item.
        pub fn addOne(self: *Self) !*T {
            try self.ensureUnusedCapacity(1);
            return self.addOneAssumeCapacity();
        }

        pub fn slice(self: anytype) []T {
            if (std.meta.activeTag(self.buf) == .stack) {
                return self.buf.stack[0..self.len];
            }
            return self.buf.heap.items;
        }

        pub fn append(self: *Self, item: T) !void {
            if (std.meta.activeTag(self.buf) == .stack) {
                if (self.len + 1 > stack_capacity) {
                    try self.moveToHeap();
                    try self.append(item);
                    return;
                }

                const new_item_ptr = try self.addOne();
                new_item_ptr.* = item;
            } else {
                try self.buf.heap.append(item);
            }
        }

        /// Append the slice of items to the slice.
        pub fn appendSlice(self: *Self, items: []const T) !void {
            try self.ensureUnusedCapacity(items.len);
            self.appendSliceAssumeCapacity(items);
        }

        /// Append the slice of items to the slice, asserting the capacity is already
        /// enough to store the new items.
        pub fn appendSliceAssumeCapacity(self: *Self, items: []const T) void {
            switch (self.buf) {
                .stack => |*buf| {
                    const old_len = self.len;
                    self.len += items.len;
                    @memcpy(buf[old_len..][0..items.len], items);
                },
                .heap => |*buf| {
                    self.len += items.len;
                    buf.appendSliceAssumeCapacity(items);
                },
            }
        }

        /// Remove and return the last element from the slice.
        /// Asserts the slice has at least one item.
        pub fn pop(self: *Self) T {
            switch (self.buf) {
                .stack => |buf| {
                    const item = buf[self.len - 1];
                    self.len -= 1;
                    return item;
                },
                .heap => |*buf| {
                    self.len -= 1;
                    return buf.pop();
                },
            }
        }

        /// Return the last element from the list.
        /// Asserts the list has at least one item.
        pub fn getLast(self: Self) T {
            switch (self.buf) {
                .stack => |buf| {
                    return buf[self.len - 1];
                },
                .heap => |*buf| {
                    return buf.items[self.len - 1];
                },
            }
        }

        /// Return the last element from the list, or
        /// return `null` if list is empty.
        pub fn getLastOrNull(self: Self) ?T {
            if (self.len == 0) {
                return null;
            }
            return self.getLast();
        }

        /// Remove and return the last element from the slice, or
        /// return `null` if the slice is empty.
        pub fn popOrNull(self: *Self) ?T {
            return if (self.len == 0) null else self.pop();
        }

        /// Insert `item` at index `i` by moving `slice[n .. slice.len]` to make room.
        /// This operation is O(N).
        pub fn insert(
            self: *Self,
            i: usize,
            item: T,
        ) !void {
            try self.ensureUnusedCapacity(1);
            switch (self.buf) {
                .stack => |*buf| {
                    if (i > stack_capacity) {
                        try self.moveToHeap();
                        try self.insert(i, item);
                        return;
                    }
                    _ = try self.addOne();
                    std.mem.copyBackwards(T, buf[i + 1 .. buf.len], buf[i .. buf.len - 1]);
                    buf[i] = item;
                },
                .heap => |*buf| {
                    self.len += 1;
                    try buf.insert(i, item);
                },
            }
        }

        /// Insert slice `items` at index `i` by moving `slice[i .. slice.len]` to make room.
        /// This operation is O(N).
        pub fn insertSlice(self: *Self, i: usize, items: []const T) !void {
            try self.ensureUnusedCapacity(items.len);
            switch (self.buf) {
                .stack => |*buf| {
                    if (i > stack_capacity) {
                        try self.moveToHeap();
                        try self.insertSlice(i, items);
                        return;
                    }
                    self.len += items.len;
                    std.mem.copyBackwards(T, buf[i + items.len .. self.len], buf[i .. self.len - items.len]);
                    @memcpy(buf[i..][0..items.len], items);
                },
                .heap => |*buf| {
                    try buf.insertSlice(i, items);
                    self.len += items.len;
                },
            }
        }

        /// Replace range of elements `slice[start..][0..len]` with `new_items`.
        /// Grows slice if `len < new_items.len`.
        /// Shrinks slice if `len > new_items.len`.
        pub fn replaceRange(
            self: *Self,
            start: usize,
            len: usize,
            new_items: []const T,
        ) !void {
            switch (self.buf) {
                .stack => |*buf| {
                    const after_range = start + len;
                    var range = buf[start..after_range];

                    if (range.len == new_items.len) {
                        @memcpy(range[0..new_items.len], new_items);
                    } else if (range.len < new_items.len) {
                        const first = new_items[0..range.len];
                        const rest = new_items[range.len..];
                        @memcpy(range[0..first.len], first);
                        try self.insertSlice(after_range, rest);
                    } else {
                        @memcpy(range[0..new_items.len], new_items);
                        const after_subrange = start + new_items.len;
                        for (buf[after_range..], 0..) |item, i| {
                            buf[after_subrange..][i] = item;
                        }
                        self.len -= len - new_items.len;
                    }
                },
                .heap => |*buf| {
                    try buf.replaceRange(start, len, new_items);
                },
            }
        }

        /// Remove the element at index `i`, shift elements after index
        /// `i` forward, and return the removed element.
        /// Asserts the slice has at least one item.
        /// This operation is O(N).
        pub fn orderedRemove(self: *Self, i: usize) T {
            switch (self.buf) {
                .stack => |*buf| {
                    const newlen = self.len - 1;
                    if (newlen == i) return self.pop();
                    const old_item = buf[i];
                    for (buf[i..newlen], 0..) |*b, j| b.* = buf[i + 1 + j];
                    buf[newlen] = undefined;
                    self.len = newlen;
                    return old_item;
                },
                .heap => |*buf| {
                    return buf.orderedRemove(i);
                },
            }
        }

        /// Remove the element at the specified index and return it.
        /// The empty slot is filled from the end of the slice.
        /// This operation is O(1).
        pub fn swapRemove(self: *Self, i: usize) T {
            switch (self.buf) {
                .stack => |*buf| {
                    if (self.len - 1 == i) return self.pop();
                    const old_item = buf[i];
                    buf[i] = self.pop();
                    return old_item;
                },
                .heap => |*buf| {
                    return buf.swapRemove(i);
                },
            }
        }

        /// Append a value to the slice `n` times.
        /// Allocates more memory as necessary.
        pub fn appendNTimes(self: *Self, value: T, n: usize) !void {
            switch (self.buf) {
                .stack => |*buf| {
                    if (self.len + n > stack_capacity) {
                        try self.moveToHeap();
                        return self.appendNTimes(value, n);
                    }
                    @memset(buf[self.len .. self.len + n], value);
                    self.len += n;
                },

                .heap => |*buf| {
                    try buf.appendNTimes(value, n);
                },
            }
        }

        /// Copy the content of an existing slice.
        pub fn fromSlice(allocator: std.mem.Allocator, m: []const T) !Self {
            const len = m.len;

            if (len > stack_capacity) {
                var heap = try std.ArrayList(T).initCapacity(allocator, stack_capacity);
                try heap.appendSlice(m);
                return Self{
                    .allocator = allocator,
                    .len = len,
                    .buf = Buffer{ .heap = heap },
                };
            } else {
                var self = init(allocator);
                self.len = len;
                @memcpy(self.buf.stack[0..], m);
                return self;
            }
        }

        pub const Writer = if (T != u8)
            @compileError("The Writer interface is only defined for SmallArray(u8, ...) " ++
                "but the given type is BoundedArray(" ++ @typeName(T) ++ ", ...)")
        else
            std.io.Writer(*Self, error{OutOfMemory}, appendWrite);

        /// Initializes a writer which will write into the array.
        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        /// Same as `appendSlice` except it returns the number of bytes written, which is always the same
        /// as `m.len`. The purpose of this function existing is to match `std.io.Writer` API.
        fn appendWrite(self: *Self, m: []const u8) !usize {
            try self.appendSlice(m);
            return m.len;
        }

        // --------------------------------------------------------------------------------
        //                                  Private API
        // --------------------------------------------------------------------------------

        fn moveToHeap(self: *Self) !void {
            var heap = try std.ArrayList(T).initCapacity(self.allocator, stack_capacity);
            try heap.appendSlice(self.buf.stack[0..self.len]);
            self.buf = Buffer{ .heap = heap };
        }
    };
}

test "test ensureUnusedCapacity" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try testing.expect(arr.isInStack() == true);

    try arr.ensureUnusedCapacity(2);
    try testing.expect(arr.isInStack() == true);

    try arr.ensureUnusedCapacity(4);
    try testing.expect(arr.isInStack() == false);
}

test "test capacity" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try arr.append(1);
    try arr.append(2);

    try testing.expect(arr.capacity() == 2);

    try arr.append(3);
    try testing.expect(arr.capacity() > 4);
}

test "test isolution" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    var arr2 = SmallArray(u8, 2).init(allocator);

    try arr.append(1);
    try arr.append(2);
    try arr.append(3);

    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02\x03"));
    try testing.expect(std.mem.eql(u8, arr2.slice(), ""));

    try arr2.append(4);
    try arr2.append(5);
    try arr2.append(6);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02\x03"));
    try testing.expect(std.mem.eql(u8, arr2.slice(), "\x04\x05\x06"));

    arr.deinit();
    try testing.expect(std.mem.eql(u8, arr2.slice(), "\x04\x05\x06"));
    arr2.deinit();
}

test "test append" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try arr.append(1);
    try arr.append(2);

    try testing.expectEqual(arr.slice().len, 2);
    try testing.expect(arr.isInStack() == true);

    try arr.append(3);
    try testing.expectEqual(arr.slice().len, 3);
    try testing.expect(arr.isInStack() == false);

    const slice = arr.slice();
    try testing.expect(std.mem.eql(u8, slice, "\x01\x02\x03"));
}

test "test appendSlice" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try arr.appendSlice("\x01\x02");
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02"));

    try arr.appendSlice("\x03\x04");

    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02\x03\x04"));
}

test "test pop" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try arr.append(1);
    try testing.expectEqual(arr.slice().len, 1);

    var item = arr.pop();
    try testing.expectEqual(arr.slice().len, 0);
    try testing.expectEqual(item, 1);

    try arr.append(1);
    try arr.append(2);
    try arr.append(3);
    try testing.expectEqual(arr.slice().len, 3);
    try testing.expect(arr.isInStack() == false);

    item = arr.pop();
    try testing.expectEqual(arr.slice().len, 2);
    try testing.expectEqual(item, 3);
}

test "test popOrNull" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try arr.append(1);
    try arr.append(2);
    try arr.append(3);

    _ = arr.popOrNull();
    _ = arr.popOrNull();
    _ = arr.popOrNull();
    _ = arr.popOrNull();
    const item = arr.popOrNull();

    try testing.expect(item == null);
}

test "test insert" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try arr.append(0x01);
    try arr.insert(0, 0x02);

    try testing.expect(std.mem.eql(u8, arr.slice(), "\x02\x01"));

    try arr.insert(0, 0x03);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x03\x02\x01"));
    try arr.insert(0, 0x04);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x04\x03\x02\x01"));
}

test "test insertSlice" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try arr.insertSlice(0, "\x01");
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01"));

    try arr.insertSlice(0, "\x03\x02");
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x03\x02\x01"));

    try arr.insertSlice(3, "\x00");
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x03\x02\x01\x00"));
}

test "test replaceRange" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try arr.append(0x01);
    try arr.append(0x02);

    try arr.replaceRange(0, 2, "\x03\x04");
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x03\x04"));

    try arr.append(0x05);

    try testing.expect(std.mem.eql(u8, arr.slice(), "\x03\x04\x05"));

    try arr.replaceRange(0, 3, "\x06\x07\x08");

    try testing.expect(std.mem.eql(u8, arr.slice(), "\x06\x07\x08"));
}

test "test orderedRemove" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try arr.append(0x01);
    try arr.append(0x02);

    var item = arr.orderedRemove(0);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x02"));
    try testing.expect(item == 0x01);

    item = arr.orderedRemove(0);
    try testing.expect(std.mem.eql(u8, arr.slice(), ""));
    try testing.expect(item == 0x02);

    try arr.append(0x01);
    try arr.append(0x02);
    try arr.append(0x03);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02\x03"));

    item = arr.orderedRemove(2);
    try testing.expect(item == 0x03);
    item = arr.orderedRemove(1);
    try testing.expect(item == 0x02);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01"));

    try arr.append(0x02);
    try arr.append(0x03);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02\x03"));

    item = arr.orderedRemove(0);
    try testing.expect(item == 0x01);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x02\x03"));
}

test "test swapRemove" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try arr.append(0x01);
    try arr.append(0x02);

    var item = arr.swapRemove(0);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x02"));
    try testing.expect(item == 0x01);

    item = arr.swapRemove(0);
    try testing.expect(std.mem.eql(u8, arr.slice(), ""));
    try testing.expect(item == 0x02);

    try arr.append(0x01);
    try arr.append(0x02);
    try arr.append(0x03);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02\x03"));

    item = arr.swapRemove(1);
    try testing.expect(item == 0x02);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x03"));

    try arr.append(0x02);
    try arr.append(0x03);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x03\x02\x03"));

    item = arr.swapRemove(0);
    try testing.expect(item == 0x01);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x03\x03\x02"));
}

test "test appendNTimes" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try arr.appendNTimes(0x01, 2);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x01"));

    try arr.appendNTimes(0x02, 2);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x01\x02\x02"));
}

test "test fromSlice" {
    const allocator = testing.allocator;

    var arr = try SmallArray(u8, 2).fromSlice(allocator, "\x01\x02");

    try testing.expectEqual(arr.slice().len, 2);
    try testing.expect(arr.isInStack() == true);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02"));

    arr.deinit();

    arr = try SmallArray(u8, 2).fromSlice(allocator, "\x01\x02\x03");
    defer arr.deinit();

    try testing.expectEqual(arr.slice().len, 3);
    try testing.expect(arr.isInStack() == false);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02\x03"));
}

test "test fromSlice ownership" {
    const allocator = testing.allocator;

    var slice = [_]u8{ 0x01, 0x02 };

    var arr = try SmallArray(u8, 2).fromSlice(allocator, &slice);
    defer arr.deinit();

    try testing.expectEqual(arr.slice().len, 2);
    try testing.expect(arr.isInStack() == true);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02"));

    // Change the slice.
    slice[0] = 0x03;
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02"));

    var slice2 = [_]u8{ 0x01, 0x02, 0x03 };

    var arr2 = try SmallArray(u8, 2).fromSlice(allocator, &slice2);
    defer arr2.deinit();

    try testing.expect(arr2.isInStack() == false);
    try testing.expect(std.mem.eql(u8, arr2.slice(), "\x01\x02\x03"));

    // Change the slice.
    slice2[0] = 0x04;
    try testing.expect(std.mem.eql(u8, arr2.slice(), "\x01\x02\x03"));
}

test "test change element value" {
    const allocator = testing.allocator;

    var slice = [_]u8{ 0x01, 0x02 };

    var arr = try SmallArray(u8, 2).fromSlice(allocator, &slice);
    defer arr.deinit();

    try testing.expectEqual(arr.slice().len, 2);
    try testing.expect(arr.isInStack() == true);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02"));

    // Change array element value inplace
    arr.slice()[0] = 0x03;
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x03\x02"));

    var slice2 = [_]u8{ 0x01, 0x02, 0x03 };

    var arr2 = try SmallArray(u8, 2).fromSlice(allocator, &slice2);
    defer arr2.deinit();

    try testing.expect(arr2.isInStack() == false);
    try testing.expect(std.mem.eql(u8, arr2.slice(), "\x01\x02\x03"));

    // Change array element value inplace
    arr2.slice()[0] = 0x04;
    try testing.expect(std.mem.eql(u8, arr2.slice(), "\x04\x02\x03"));
}

test "test resize" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try arr.append(1);
    try arr.append(2);

    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02"));

    try arr.resize(1);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01"));

    try arr.resize(4);

    try arr.append(3);
    try arr.append(4);
    try testing.expect(std.mem.eql(u8, arr.slice()[4..], "\x03\x04"));

    try arr.resize(1);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01"));
}

test "test addManyAsArray" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    var slice = try arr.addManyAsArray(2);

    slice[0] = 0x01;
    slice[1] = 0x02;

    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02"));

    slice = try arr.addManyAsArray(2);
    slice[0] = 0x03;
    slice[1] = 0x04;
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02\x03\x04"));
}

test "test unusedCapacitySlice" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    var slice = arr.unusedCapacitySlice();

    slice[0] = 0x01;
    slice[1] = 0x02;

    try arr.resize(2);
    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02"));

    // more 2 element
    try arr.ensureUnusedCapacity(2);
    slice = arr.unusedCapacitySlice();
    slice[0] = 0x03;
    slice[1] = 0x04;

    // change the size to 4
    try arr.resize(4);

    try testing.expect(std.mem.eql(u8, arr.slice(), "\x01\x02\x03\x04"));
}

test "test getLast" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    try arr.append(2);
    try testing.expectEqual(arr.getLast(), 2);
}

test "test getLastOrNull" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();
    try testing.expectEqual(arr.getLastOrNull(), null);

    try arr.append(2);
    try testing.expectEqual(arr.getLastOrNull().?, 2);
}

test "test writer" {
    const allocator = testing.allocator;

    var arr = SmallArray(u8, 2).init(allocator);
    defer arr.deinit();

    const writer = arr.writer();
    const s = "a test string";
    try writer.writeAll(s);

    try testing.expectEqualStrings(arr.slice(), s);
}
