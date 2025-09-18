const c = @import("c_api.zig").c;

pub export fn handlePlayChat(
    ctx: *c.ServerContext,
    client_fd: c_int,
    length: c_int,
    packet_id: c_int,
) void {
    switch (packet_id) {
        0x06, 0x07 => {
            _ = c.cs_chatCommand(ctx, client_fd);
        },

        0x08 => {
            _ = c.cs_chat(ctx, client_fd);
        },

        else => {
            _ = c.recv_all(client_fd, &ctx.recv_buffer, @intCast(length), 0);
        },
    }
}
