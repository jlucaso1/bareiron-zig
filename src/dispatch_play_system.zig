const c = @import("c_api.zig").c;

pub export fn handlePlaySystem(
    ctx: *c.ServerContext,
    client_fd: c_int,
    length: c_int,
    packet_id: c_int,
) void {
    switch (packet_id) {
        0x0B => {
            _ = c.cs_clientStatus(ctx, client_fd);
        },

        0x1B => {
            _ = c.recv_all(client_fd, &ctx.recv_buffer, @intCast(length), 0);
        },

        0x29 => {
            _ = c.cs_playerCommand(ctx, client_fd);
        },

        0x2A => {
            _ = c.cs_playerInput(ctx, client_fd);
        },

        0x2B => {
            _ = c.cs_playerLoaded(ctx, client_fd);
        },

        else => {
            _ = c.recv_all(client_fd, &ctx.recv_buffer, @intCast(length), 0);
        },
    }
}
