const std = @import("std");

const ByteTransport = @import("transport/byte_transport.zig").ByteTransport;
const framing = @import("framing/length_prefix.zig");
const codec = @import("codec/message_codec.zig");
const Message = @import("protocol/message.zig").Message;

pub const Mux = struct {
    alloc: std.mem.Allocator,
    transport: ByteTransport,
    recv_buf: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator, transport: ByteTransport) Mux {
        return .{
            .alloc = alloc,
            .transport = transport,
            .recv_buf = std.ArrayList(u8).init(alloc),
        };
    }

    pub fn deinit(self: *Mux) void {
        self.recv_buf.deinit();
        self.transport.deinit();
    }

    pub fn send(self: *Mux, msg: Message) !void {
        const payload = try codec.encode(self.alloc, msg);
        defer self.alloc.free(payload);

        const frame = try framing.encode(self.alloc, payload);
        defer self.alloc.free(frame);

        try self.transport.writeAll(frame);
    }

    pub fn recv(self: *Mux) !?Message {
        var tmp: [256]u8 = undefined;
        const n = try self.transport.readAtMost(&tmp);
        if (n == 0 and self.recv_buf.items.len == 0) return null;

        if (n > 0) {
            try self.recv_buf.appendSlice(tmp[0..n]);
        }

        const res = framing.decode(self.recv_buf.items) catch |err| switch (err) {
            framing.FrameError.IncompleteHeader,
            framing.FrameError.IncompletePayload => return null,
            else => return err,
        };

        if (res) |r| {
            const msg = try codec.decode(r.payload);
            // consume bytes
            // consume bytes from front of recv_buf
            const rest_len = self.recv_buf.items.len - r.consumed;
            if (rest_len > 0) {
                std.mem.copyForwards(u8, self.recv_buf.items[0..rest_len], self.recv_buf.items[r.consumed..]);
            }
            self.recv_buf.shrinkRetainingCapacity(rest_len);
            return msg;
        }

        return null;
    }
};
