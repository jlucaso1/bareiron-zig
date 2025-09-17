const std = @import("std");
const net = std.net;
const posix = std.posix;
const c = @import("c_api.zig").c;

pub const MAX_PLAYERS: usize = c.MAX_PLAYERS;

pub var client_streams: [MAX_PLAYERS]?net.Stream = .{null} ** MAX_PLAYERS;
pub var client_ids: [MAX_PLAYERS]c_int = .{0} ** MAX_PLAYERS;

pub fn findSlotByFd(fd: posix.fd_t) ?usize {
    for (client_streams, 0..) |maybe_stream, i| {
        if (maybe_stream) |s| {
            if (s.handle == fd) return i;
        }
    }
    return null;
}
