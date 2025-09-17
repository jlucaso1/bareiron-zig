const std = @import("std");
const net = std.net;
const posix = std.posix;
const c = @import("c_api.zig").c;

pub const MAX_PLAYERS: usize = c.MAX_PLAYERS;

pub const Client = struct {
    stream: net.Stream,
    id: c_int,
};

pub var clients: [MAX_PLAYERS]?Client = .{null} ** MAX_PLAYERS;

pub fn findSlotByFd(fd: c_int) ?usize {
    for (clients, 0..) |maybe_client, i| {
        if (maybe_client) |client| {
            if (comptime @import("builtin").target.os.tag == .windows) {
                if (client.id == fd) return i;
            } else {
                if (client.stream.handle == @as(posix.fd_t, @intCast(fd))) return i;
            }
        }
    }
    return null;
}
