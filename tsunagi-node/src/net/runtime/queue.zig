const std = @import("std");

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        list: std.ArrayList(T),

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{ .list = std.ArrayList(T).init(alloc) };
        }

        pub fn deinit(self: *Self) void {
            self.list.deinit();
        }

        pub fn push(self: *Self, item: T) !void {
            try self.list.append(item);
        }

        pub fn pop(self: *Self) ?T {
            if (self.list.items.len == 0) return null;
            // FIFO: take first
            const item = self.list.items[0];
            _ = self.list.orderedRemove(0);
            return item;
        }

        pub fn len(self: *Self) usize {
            return self.list.items.len;
        }
    };
}
