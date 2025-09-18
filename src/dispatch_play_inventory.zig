const c = @import("c_api.zig").c;

pub export fn handlePlayInventory(ctx: *c.ServerContext, client_fd: c_int, length: c_int, packet_id: c_int) void {
    switch (packet_id) {
        0x11 => {
            _ = c.cs_clickContainer(ctx, client_fd);
        },
        0x12 => {
            _ = c.cs_closeContainer(ctx, client_fd);
        },
        0x19 => {
            _ = c.cs_interact(ctx, client_fd);
        },
        0x28 => {
            _ = c.cs_playerAction(ctx, client_fd);
        },
        0x34 => {
            _ = c.cs_setHeldItem(ctx, client_fd);
        },
        0x3C => {
            _ = c.cs_swingArm(ctx, client_fd);
        },
        0x3F => {
            _ = c.cs_useItemOn(ctx, client_fd);
        },
        0x40 => {
            _ = c.cs_useItem(ctx, client_fd);
        },
        else => {
            _ = c.recv_all(client_fd, &ctx.recv_buffer, @intCast(length), 0);
        },
    }
}
