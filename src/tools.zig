const std = @import("std");
const builtin = @import("builtin");
const c = @import("c_api.zig").c;
const connections = @import("connections.zig");
const net = std.net;
const posix = std.posix;

pub export var total_bytes_received: u64 = 0;

const is_esp = builtin.target.os.tag == .freestanding;
const is_windows = builtin.target.os.tag == .windows;

var last_yield_time: i64 = 0;
fn task_yield() void {
    if (comptime is_esp) {
        const TASK_YIELD_INTERVAL: i64 = 1_000_000; // microseconds
        const TASK_YIELD_TICKS: c.BaseType_t = 1;
        const now = c.esp_timer_get_time();
        if (now - last_yield_time >= TASK_YIELD_INTERVAL) {
            _ = c.vTaskDelay(TASK_YIELD_TICKS);
            last_yield_time = now;
        }
    } else {
        // no-op on non-ESP
    }
}

// errno stub retained for C signature compatibility; not used with std.net here
pub export fn get_errno() c_int {
    return 0;
}

// Monotonic time in microseconds
pub export fn get_program_time() i64 {
    if (comptime is_esp) {
        return c.esp_timer_get_time();
    } else {
        const ns: i128 = std.time.nanoTimestamp();
        return @intCast(@divTrunc(ns, 1000));
    }
}
fn getStream(client_fd: c_int) !*net.Stream {
    if (comptime builtin.target.os.tag == .windows) {
        for (&connections.client_streams, 0..) |*maybe_stream, i| {
            if (maybe_stream.*) |*stream| {
                if (connections.client_ids[i] == client_fd) return stream;
            }
        }
        return error.StreamNotFound;
    } else {
        const fd_val: std.posix.fd_t = @intCast(client_fd);
        for (&connections.client_streams) |*maybe_stream| {
            if (maybe_stream.*) |*stream| {
                if (stream.handle == fd_val) return stream;
            }
        }
        return error.StreamNotFound;
    }
}

fn read_all_with_timeout(stream: *net.Stream, buffer: []u8) !void {
    if (comptime is_windows) {
        var last_update_time = get_program_time();
        var off: usize = 0;
        const sock: c.SOCKET = @intCast(@intFromPtr(stream.handle));
        while (off < buffer.len) {
            const want: c_int = @intCast(buffer.len - off);
            const got: c_int = c.recv(sock, @ptrCast(&buffer[off]), want, 0);
            if (got == 0) return error.ConnectionResetByPeer;
            if (got == -1) {
                const werr: c_int = c.WSAGetLastError();
                // 10035 = WSAEWOULDBLOCK
                if (werr == 10035) {
                    if (get_program_time() - last_update_time > c.NETWORK_TIMEOUT_TIME) return error.Timeout;
                    task_yield();
                    continue;
                }
                return error.Unexpected;
            }
            off += @intCast(got);
            last_update_time = get_program_time();
        }
    } else {
        var last_update_time = get_program_time();
        var off: usize = 0;
        while (off < buffer.len) {
            const n = stream.read(buffer[off..]) catch |err| switch (err) {
                error.WouldBlock => {
                    if (get_program_time() - last_update_time > c.NETWORK_TIMEOUT_TIME) return error.Timeout;
                    task_yield();
                    continue;
                },
                else => |e| return e,
            };
            if (n == 0) return error.ConnectionResetByPeer;
            off += n;
            last_update_time = get_program_time();
        }
    }
}

fn write_all_with_timeout(stream: *net.Stream, data: []const u8) !void {
    if (comptime is_windows) return error.Unexpected;
    var off: usize = 0;
    const start = get_program_time();
    while (off < data.len) {
        const wrote_res = stream.write(data[off..]);
        if (wrote_res) |n| {
            if (n == 0) return error.ConnectionResetByPeer;
            off += n;
            continue;
        } else |err| {
            if (err == error.WouldBlock) {
                const now = get_program_time();
                if (now - start > c.NETWORK_TIMEOUT_TIME) return error.Timeout;
                var pfd = [_]posix.pollfd{.{ .fd = stream.handle, .events = posix.POLL.OUT, .revents = 0 }};
                const remaining_us: i64 = c.NETWORK_TIMEOUT_TIME - (now - start);
                const timeout_ms: c_int = @intCast(@max(1, @divTrunc(remaining_us, 1000)));
                _ = posix.poll(&pfd, timeout_ms) catch {};
                continue;
            }
            return err;
        }
    }
}

fn write_all_windows(client_fd: c_int, data: []const u8) !void {
    var off: usize = 0;
    const stream = try getStream(client_fd);
    const sock: c.SOCKET = @intCast(@intFromPtr(stream.handle));
    var last_update_time = get_program_time();
    while (off < data.len) {
        const want: c_int = @intCast(data.len - off);
        const sent: c_int = c.send(sock, @ptrCast(&data[off]), want, 0);
        if (sent == -1) {
            const werr: c_int = c.WSAGetLastError();
            if (werr == 10035) {
                if (get_program_time() - last_update_time > c.NETWORK_TIMEOUT_TIME) return error.Timeout;
                task_yield();
                continue;
            }
            return error.Unexpected;
        }
        if (sent == 0) return error.ConnectionResetByPeer;
        off += @intCast(sent);
        last_update_time = get_program_time();
    }
}

pub export fn recv_all(client_fd: c_int, buf: ?*anyopaque, n: usize, require_first: u8) isize {
    _ = require_first;
    if (buf == null) return -1;
    const slice: []u8 = @as([*]u8, @ptrCast(buf.?))[0..n];
    if (comptime is_windows) {
        // On Windows, use Winsock directly
        var off: usize = 0;
        var last_update_time = get_program_time();
        const stream = getStream(client_fd) catch return -1;
        const sock: c.SOCKET = @intCast(@intFromPtr(stream.handle));
        while (off < slice.len) {
            const want: c_int = @intCast(slice.len - off);
            const got: c_int = c.recv(sock, @ptrCast(&slice[off]), want, 0);
            if (got == 0) return -1;
            if (got == -1) {
                const werr: c_int = c.WSAGetLastError();
                if (werr == 10035) {
                    if (get_program_time() - last_update_time > c.NETWORK_TIMEOUT_TIME) return -1;
                    task_yield();
                    continue;
                }
                return -1;
            }
            off += @intCast(got);
            last_update_time = get_program_time();
        }
    } else {
        const stream = getStream(client_fd) catch return -1;
        read_all_with_timeout(stream, slice) catch return -1;
    }
    total_bytes_received += n;
    return @intCast(n);
}

pub export fn send_all(client_fd: c_int, buf: ?*const anyopaque, len: isize) isize {
    if (buf == null or len < 0) return -1;
    const slice: []const u8 = @as([*]const u8, @ptrCast(buf.?))[0..@intCast(len)];
    if (comptime is_windows) {
        write_all_windows(client_fd, slice) catch return -1;
    } else {
        const stream = getStream(client_fd) catch return -1;
        write_all_with_timeout(stream, slice) catch return -1;
    }
    return len;
}

// Writers (big-endian)
pub export fn writeByte(client_fd: c_int, byte: u8) isize {
    if (comptime is_windows) {
        var b = [_]u8{byte};
        write_all_windows(client_fd, &b) catch return -1;
    } else {
        const s = getStream(client_fd) catch return -1;
        var b = [_]u8{byte};
        write_all_with_timeout(s, &b) catch return -1;
    }
    return 1;
}

pub export fn writeUint16(client_fd: c_int, num: u16) isize {
    var be: u16 = std.mem.nativeToBig(u16, num);
    if (comptime is_windows) {
        write_all_windows(client_fd, std.mem.asBytes(&be)) catch return -1;
    } else {
        const s = getStream(client_fd) catch return -1;
        write_all_with_timeout(s, std.mem.asBytes(&be)) catch return -1;
    }
    return @sizeOf(u16);
}

pub export fn writeUint32(client_fd: c_int, num: u32) isize {
    var be: u32 = std.mem.nativeToBig(u32, num);
    if (comptime is_windows) {
        write_all_windows(client_fd, std.mem.asBytes(&be)) catch return -1;
    } else {
        const s = getStream(client_fd) catch return -1;
        write_all_with_timeout(s, std.mem.asBytes(&be)) catch return -1;
    }
    return @sizeOf(u32);
}

pub export fn writeUint64(client_fd: c_int, num: u64) isize {
    var be: u64 = std.mem.nativeToBig(u64, num);
    if (comptime is_windows) {
        write_all_windows(client_fd, std.mem.asBytes(&be)) catch return -1;
    } else {
        const s = getStream(client_fd) catch return -1;
        write_all_with_timeout(s, std.mem.asBytes(&be)) catch return -1;
    }
    return @sizeOf(u64);
}

pub export fn writeFloat(client_fd: c_int, num: f32) isize {
    const bits: u32 = @bitCast(num);
    var be: u32 = std.mem.nativeToBig(u32, bits);
    if (comptime is_windows) {
        write_all_windows(client_fd, std.mem.asBytes(&be)) catch return -1;
    } else {
        const s = getStream(client_fd) catch return -1;
        write_all_with_timeout(s, std.mem.asBytes(&be)) catch return -1;
    }
    return @sizeOf(u32);
}

pub export fn writeDouble(client_fd: c_int, num: f64) isize {
    const bits: u64 = @bitCast(num);
    var be: u64 = std.mem.nativeToBig(u64, bits);
    if (comptime is_windows) {
        write_all_windows(client_fd, std.mem.asBytes(&be)) catch return -1;
    } else {
        const s = getStream(client_fd) catch return -1;
        write_all_with_timeout(s, std.mem.asBytes(&be)) catch return -1;
    }
    return @sizeOf(u64);
}

// Readers
pub export fn readByte(ctx: *c.ServerContext, client_fd: c_int) u8 {
    var buf: [1]u8 = undefined;
    if (comptime is_windows) {
        var off: usize = 0;
        var last_update_time = get_program_time();
        const stream = getStream(client_fd) catch {
            ctx.recv_count = -1;
            return 0;
        };
        const sock: c.SOCKET = @intCast(@intFromPtr(stream.handle));
        while (off < buf.len) {
            const got: c_int = c.recv(sock, @ptrCast(&buf[off]), 1, 0);
            if (got == 0) {
                ctx.recv_count = -1;
                return 0;
            }
            if (got == -1) {
                const werr: c_int = c.WSAGetLastError();
                if (werr == 10035) {
                    if (get_program_time() - last_update_time > c.NETWORK_TIMEOUT_TIME) {
                        ctx.recv_count = -1;
                        return 0;
                    }
                    task_yield();
                    continue;
                }
                ctx.recv_count = -1;
                return 0;
            }
            off += @intCast(got);
            last_update_time = get_program_time();
        }
    } else {
        const s = getStream(client_fd) catch {
            ctx.recv_count = -1;
            return 0;
        };
        read_all_with_timeout(s, &buf) catch {
            ctx.recv_count = -1;
            return 0;
        };
    }
    ctx.recv_count = 1;
    total_bytes_received += 1;
    return buf[0];
}

pub export fn readUint16(ctx: *c.ServerContext, client_fd: c_int) u16 {
    var buf: [2]u8 = undefined;
    if (comptime is_windows) {
        var off: usize = 0;
        var last_update_time = get_program_time();
        const stream = getStream(client_fd) catch {
            ctx.recv_count = -1;
            return 0;
        };
        const sock: c.SOCKET = @intCast(@intFromPtr(stream.handle));
        while (off < buf.len) {
            const want: c_int = @intCast(buf.len - off);
            const got: c_int = c.recv(sock, @ptrCast(&buf[off]), want, 0);
            if (got == 0) {
                ctx.recv_count = -1;
                return 0;
            }
            if (got == -1) {
                const werr: c_int = c.WSAGetLastError();
                if (werr == 10035) {
                    if (get_program_time() - last_update_time > c.NETWORK_TIMEOUT_TIME) {
                        ctx.recv_count = -1;
                        return 0;
                    }
                    task_yield();
                    continue;
                }
                ctx.recv_count = -1;
                return 0;
            }
            off += @intCast(got);
            last_update_time = get_program_time();
        }
    } else {
        const s = getStream(client_fd) catch {
            ctx.recv_count = -1;
            return 0;
        };
        read_all_with_timeout(s, &buf) catch {
            ctx.recv_count = -1;
            return 0;
        };
    }
    ctx.recv_count = 2;
    total_bytes_received += 2;
    return std.mem.readInt(u16, &buf, .big);
}

pub export fn readInt16(ctx: *c.ServerContext, client_fd: c_int) i16 {
    const u = readUint16(ctx, client_fd);
    return @bitCast(u);
}

pub export fn readUint32(ctx: *c.ServerContext, client_fd: c_int) u32 {
    var buf: [4]u8 = undefined;
    if (comptime is_windows) {
        var off: usize = 0;
        var last_update_time = get_program_time();
        const stream = getStream(client_fd) catch {
            ctx.recv_count = -1;
            return 0;
        };
        const sock: c.SOCKET = @intCast(@intFromPtr(stream.handle));
        while (off < buf.len) {
            const want: c_int = @intCast(buf.len - off);
            const got: c_int = c.recv(sock, @ptrCast(&buf[off]), want, 0);
            if (got == 0) {
                ctx.recv_count = -1;
                return 0;
            }
            if (got == -1) {
                const werr: c_int = c.WSAGetLastError();
                if (werr == 10035) {
                    if (get_program_time() - last_update_time > c.NETWORK_TIMEOUT_TIME) {
                        ctx.recv_count = -1;
                        return 0;
                    }
                    task_yield();
                    continue;
                }
                ctx.recv_count = -1;
                return 0;
            }
            off += @intCast(got);
            last_update_time = get_program_time();
        }
    } else {
        const s = getStream(client_fd) catch {
            ctx.recv_count = -1;
            return 0;
        };
        read_all_with_timeout(s, &buf) catch {
            ctx.recv_count = -1;
            return 0;
        };
    }
    ctx.recv_count = 4;
    total_bytes_received += 4;
    return std.mem.readInt(u32, &buf, .big);
}

pub export fn readUint64(ctx: *c.ServerContext, client_fd: c_int) u64 {
    var buf: [8]u8 = undefined;
    if (comptime is_windows) {
        var off: usize = 0;
        var last_update_time = get_program_time();
        const stream = getStream(client_fd) catch {
            ctx.recv_count = -1;
            return 0;
        };
        const sock: c.SOCKET = @intCast(@intFromPtr(stream.handle));
        while (off < buf.len) {
            const want: c_int = @intCast(buf.len - off);
            const got: c_int = c.recv(sock, @ptrCast(&buf[off]), want, 0);
            if (got == 0) {
                ctx.recv_count = -1;
                return 0;
            }
            if (got == -1) {
                const werr: c_int = c.WSAGetLastError();
                if (werr == 10035) {
                    if (get_program_time() - last_update_time > c.NETWORK_TIMEOUT_TIME) {
                        ctx.recv_count = -1;
                        return 0;
                    }
                    task_yield();
                    continue;
                }
                ctx.recv_count = -1;
                return 0;
            }
            off += @intCast(got);
            last_update_time = get_program_time();
        }
    } else {
        const s = getStream(client_fd) catch {
            ctx.recv_count = -1;
            return 0;
        };
        read_all_with_timeout(s, &buf) catch {
            ctx.recv_count = -1;
            return 0;
        };
    }
    ctx.recv_count = 8;
    total_bytes_received += 8;
    return std.mem.readInt(u64, &buf, .big);
}

pub export fn readInt64(ctx: *c.ServerContext, client_fd: c_int) i64 {
    const u = readUint64(ctx, client_fd);
    return @bitCast(u);
}

pub export fn readFloat(ctx: *c.ServerContext, client_fd: c_int) f32 {
    const u: u32 = readUint32(ctx, client_fd);
    return @bitCast(u);
}

pub export fn readDouble(ctx: *c.ServerContext, client_fd: c_int) f64 {
    const u: u64 = readUint64(ctx, client_fd);
    return @bitCast(u);
}

pub export fn readString(ctx: *c.ServerContext, client_fd: c_int) void {
    const length = c.readVarInt(ctx, client_fd);
    if (ctx.recv_count == -1) return;
    const len_u: u32 = @bitCast(length);
    if (len_u > ctx.recv_buffer.len - 1) {
        var discard_buf: [128]u8 = undefined;
        var remaining: u32 = len_u;
        while (remaining > 0) {
            const to_read: usize = @min(@as(usize, remaining), discard_buf.len);
            const got = recv_all(client_fd, &discard_buf, to_read, 0);
            if (got <= 0) {
                ctx.recv_count = -1;
                return;
            }
            remaining -= @intCast(got);
        }
        ctx.recv_count = -1;
        return;
    }
    ctx.recv_count = recv_all(client_fd, &ctx.recv_buffer[0], len_u, 0);
    if (ctx.recv_count <= 0) {
        ctx.recv_count = -1;
        return;
    }
    ctx.recv_buffer[@intCast(ctx.recv_count)] = 0;
}

// RNG
pub export fn fast_rand(ctx: *c.ServerContext) u32 {
    ctx.rng_seed ^= ctx.rng_seed << 13;
    ctx.rng_seed ^= ctx.rng_seed >> 17;
    ctx.rng_seed ^= ctx.rng_seed << 5;
    return ctx.rng_seed;
}

pub export fn splitmix64(state: u64) u64 {
    var z = state +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}
