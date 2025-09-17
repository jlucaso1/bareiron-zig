const std = @import("std");
const c = @import("c_api.zig").c;
const net = std.net;
const posix = std.posix;

comptime {
    _ = @import("varnum.zig");
}
comptime {
    _ = @import("structures.zig");
}
comptime {
    _ = @import("crafting.zig");
}
comptime {
    _ = @import("serialize.zig");
}
comptime {
    _ = @import("tools.zig");
}
comptime {
    _ = @import("commands.zig");
}
comptime {
    _ = @import("worldgen.zig");
}
const dispatch = @import("dispatch.zig");
const connections = @import("connections.zig");
const state_mod = @import("state.zig");
const builtin = @import("builtin");
const windows = std.os.windows;

const MAX_PLAYERS = c.MAX_PLAYERS;
const PORT: u16 = @intCast(c.PORT);
const TIME_BETWEEN_TICKS: i64 = @intCast(c.TIME_BETWEEN_TICKS);

pub const client_streams = &connections.client_streams;
var g_state: state_mod.ServerState = undefined;

const is_esp = @import("builtin").target.os.tag == .freestanding;

// Yield helper for platforms (ESP). Implemented in Zig to avoid a separate C file.
var last_yield: i64 = 0;
fn task_yield() void {
    if (!is_esp) return;
    // TASK_YIELD_INTERVAL = 1000 * 1000 (microseconds)
    const TASK_YIELD_INTERVAL: i64 = 1000 * 1000;
    const TASK_YIELD_TICKS: c_int = 1;
    const time_now = c.esp_timer_get_time();
    if (time_now - last_yield < TASK_YIELD_INTERVAL) return;
    _ = c.vTaskDelay(TASK_YIELD_TICKS);
    last_yield = time_now;
}

pub fn main() !void {
    // Initialize server state context
    g_state = state_mod.ServerState.init();
    _ = c.initSerializer(@ptrCast(&g_state.context));

    var address = try net.Address.parseIp("0.0.0.0", PORT);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    // Non-blocking server socket
    if (comptime builtin.target.os.tag == .windows) {
        var mode: c_ulong = 1;
        const sock_val: usize = @intFromPtr(server.stream.handle);
        const sock: c.SOCKET = @intCast(sock_val);
        const FIONBIO_UL: c_ulong = 0x8004667E; // avoid cimport _IOW macro
        const FIONBIO_L: c_long = @bitCast(FIONBIO_UL);
        _ = c.ioctlsocket(sock, FIONBIO_L, &mode);
    } else {
        const cur_flags = try posix.fcntl(server.stream.handle, posix.F.GETFL, 0);
        const nonblock_mask: c_int = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
        _ = try posix.fcntl(server.stream.handle, posix.F.SETFL, cur_flags | nonblock_mask);
    }
    std.log.info("Server listening on port {}", .{PORT});

    var last_tick_time: i64 = c.get_program_time();

    while (true) {
        const now: i64 = c.get_program_time();
        const elapsed = now - last_tick_time;
        var time_to_next_tick: i64 = TIME_BETWEEN_TICKS - elapsed;
        if (time_to_next_tick < 0) time_to_next_tick = 0;

        var pfds: [MAX_PLAYERS + 1]posix.pollfd = undefined;
        var idxmap: [MAX_PLAYERS + 1]isize = undefined;
        var count: usize = 0;

        pfds[count] = .{ .fd = server.stream.handle, .events = posix.POLL.IN, .revents = 0 };
        idxmap[count] = -1;
        count += 1;

        for (client_streams.*, 0..) |maybe_stream, i| {
            if (maybe_stream) |stream| {
                pfds[count] = .{ .fd = stream.handle, .events = posix.POLL.IN, .revents = 0 };
                idxmap[count] = @intCast(i);
                count += 1;
            }
        }

        const timeout_ms: c_int = @intCast(@divTrunc(time_to_next_tick, 1000));
        _ = posix.poll(pfds[0..count], timeout_ms) catch |err| {
            std.log.warn("poll() error: {s}", .{@errorName(err)});
        };

        if (pfds[0].revents & posix.POLL.IN != 0) {
            acceptNewConnection(&server) catch |err| {
                if (err != error.WouldBlock) {
                    std.log.warn("accept failed: {s}", .{@errorName(err)});
                }
            };
        }

        var i: usize = 1;
        while (i < count) : (i += 1) {
            const ev = pfds[i].revents;
            if (ev == 0) continue;
            const slot = idxmap[i];
            if (slot < 0) continue;
            const idx: usize = @intCast(slot);
            if (ev & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                disconnectClient(idx);
                continue;
            }
            if (ev & posix.POLL.IN != 0) {
                if (client_streams.*[idx]) |stream| {
                    processClientPacket(stream);
                }
            }
        }

        const after_wait: i64 = c.get_program_time();
        if ((after_wait - last_tick_time) >= TIME_BETWEEN_TICKS) {
            c.handleServerTick(@ptrCast(&g_state.context), after_wait - last_tick_time);
            last_tick_time = after_wait;
        }
    }
}

fn acceptNewConnection(server: *net.Server) !void {
    var free_slot: ?usize = null;
    for (client_streams.*, 0..) |maybe_stream, i| {
        if (maybe_stream == null) {
            free_slot = i;
            break;
        }
    }
    const conn = server.accept() catch |err| {
        if (err == error.WouldBlock) return err; // non-fatal
        return err;
    };
    if (free_slot) |i| {
        if (comptime builtin.target.os.tag == .windows) {
            var mode: c_ulong = 1;
            const sock_val: usize = @intFromPtr(conn.stream.handle);
            const sock: c.SOCKET = @intCast(sock_val);
            const FIONBIO_UL: c_ulong = 0x8004667E;
            const FIONBIO_L: c_long = @bitCast(FIONBIO_UL);
            _ = c.ioctlsocket(sock, FIONBIO_L, &mode);
        } else {
            const cur = try posix.fcntl(conn.stream.handle, posix.F.GETFL, 0);
            const nb_mask: c_int = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
            _ = try posix.fcntl(conn.stream.handle, posix.F.SETFL, cur | nb_mask);
        }
        client_streams.*[i] = conn.stream;
        const fd_ci: c_int = if (comptime builtin.target.os.tag == .windows)
            @intCast(@intFromPtr(conn.stream.handle))
        else
            @intCast(conn.stream.handle);
        std.log.info("Accepted new client in slot {d} (fd: {d})", .{ i, fd_ci });
        if (comptime builtin.target.os.tag == .windows) connections.client_ids[i] = fd_ci;
        c.setClientState(@ptrCast(&g_state.context), fd_ci, c.STATE_NONE);
    } else {
        conn.stream.close();
    }
}

fn disconnectClient(slot: usize) void {
    if (client_streams.*[slot]) |*stream| {
        const fd_ci: c_int = if (comptime builtin.target.os.tag == .windows)
            @intCast(@intFromPtr(stream.handle))
        else
            @intCast(stream.handle);
        std.log.info("Client in slot {d} (fd: {d}) disconnected.", .{ slot, fd_ci });
        c.setClientState(@ptrCast(&g_state.context), fd_ci, c.STATE_NONE);
        c.handlePlayerDisconnect(@ptrCast(&g_state.context), fd_ci);
        stream.close();
        client_streams.*[slot] = null;
        if (comptime builtin.target.os.tag == .windows) connections.client_ids[slot] = 0;
        if (g_state.context.client_count > 0) g_state.context.client_count -= 1;
    }
}

fn processClientPacket(stream: net.Stream) void {
    const fd: c_int = if (comptime builtin.target.os.tag == .windows)
        @intCast(@intFromPtr(stream.handle))
    else
        @intCast(stream.handle);
    const length = c.readVarInt(@ptrCast(&g_state.context), fd);
    if (length == c.VARNUM_ERROR) return;
    if (length < 0 or @as(u32, @bitCast(length)) > g_state.context.recv_buffer.len) {
        std.log.warn("Bad packet length {d} from fd {d}; disconnecting.", .{ length, fd });
        if (comptime builtin.target.os.tag == .windows) {
            for (connections.client_ids, 0..) |cid, i| {
                if (cid == fd) {
                    disconnectClient(i);
                    break;
                }
            }
        } else {
            if (connections.findSlotByFd(@intCast(fd))) |slot| disconnectClient(slot);
        }
        return;
    }
    const packet_id = c.readVarInt(@ptrCast(&g_state.context), fd);
    if (packet_id == c.VARNUM_ERROR) return;
    const st = c.getClientState(@ptrCast(&g_state.context), fd);
    const pid_bits: u32 = @as(u32, @bitCast(packet_id));
    const header_size: c_int = c.sizeVarInt(pid_bits);
    const payload_len: c_int = length - header_size;
    dispatch.handlePacket(@ptrCast(&g_state.context), fd, payload_len, @intCast(packet_id), st);
}
