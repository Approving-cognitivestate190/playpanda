const std = @import("std");

// -- CDP over WebSocket client --
// Minimal WebSocket client for Chrome DevTools Protocol communication.
// Supports text frames only (sufficient for CDP JSON-RPC).

pub const CdpError = error{
    HandshakeFailed,
    ConnectionClosed,
    InvalidFrame,
    Timeout,
    CommandFailed,
};

pub const CdpCommand = struct {
    id: u32,
    method: []const u8,
    params: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

pub const FrameOpcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

/// Build a CDP JSON-RPC command string.
pub fn buildCommand(allocator: std.mem.Allocator, cmd: CdpCommand) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try std.fmt.format(w, "{{\"id\":{d},\"method\":\"{s}\"", .{ cmd.id, cmd.method });

    if (cmd.session_id) |sid| {
        try std.fmt.format(w, ",\"sessionId\":\"{s}\"", .{sid});
    }

    if (cmd.params) |params| {
        try w.writeAll(",\"params\":");
        try w.writeAll(params);
    }

    try w.writeByte('}');
    return try allocator.dupe(u8, buf.items);
}

/// Encode a WebSocket text frame with client masking.
pub fn encodeTextFrame(allocator: std.mem.Allocator, payload: []const u8) ![]const u8 {
    const len = payload.len;
    const ext_len_size: usize = if (len < 126) 0 else if (len <= 65535) 2 else 8;
    const frame_size = 2 + ext_len_size + 4 + len; // header + ext_len + mask + payload

    var frame = try allocator.alloc(u8, frame_size);

    // FIN=1 + opcode=text(0x1)
    frame[0] = 0x81;

    var offset: usize = 1;

    // Payload length + MASK bit
    if (len < 126) {
        frame[offset] = @as(u8, @intCast(len)) | 0x80;
        offset += 1;
    } else if (len <= 65535) {
        frame[offset] = 126 | 0x80;
        offset += 1;
        std.mem.writeInt(u16, frame[offset..][0..2], @intCast(len), .big);
        offset += 2;
    } else {
        frame[offset] = 127 | 0x80;
        offset += 1;
        std.mem.writeInt(u64, frame[offset..][0..8], @intCast(len), .big);
        offset += 8;
    }

    // Masking key — use crypto random
    var mask: [4]u8 = undefined;
    std.crypto.random.bytes(&mask);
    @memcpy(frame[offset..][0..4], &mask);
    offset += 4;

    // Masked payload
    for (payload, 0..) |b, i| {
        frame[offset + i] = b ^ mask[i % 4];
    }

    return frame;
}

/// Decoded WebSocket frame.
pub const DecodedFrame = struct {
    opcode: FrameOpcode,
    fin: bool,
    payload: []const u8,
    total_size: usize, // total bytes consumed from input
};

/// Decode a WebSocket frame from raw bytes (server->client frames are unmasked).
pub fn decodeFrame(data: []const u8) !DecodedFrame {
    if (data.len < 2) return error.InvalidFrame;

    const fin = (data[0] & 0x80) != 0;
    const opcode: FrameOpcode = @enumFromInt(@as(u4, @intCast(data[0] & 0x0F)));
    const masked = (data[1] & 0x80) != 0;
    var payload_len: u64 = data[1] & 0x7F;
    var offset: usize = 2;

    if (payload_len == 126) {
        if (data.len < 4) return error.InvalidFrame;
        payload_len = std.mem.readInt(u16, data[2..4], .big);
        offset = 4;
    } else if (payload_len == 127) {
        if (data.len < 10) return error.InvalidFrame;
        payload_len = std.mem.readInt(u64, data[2..10], .big);
        offset = 10;
    }

    if (masked) {
        if (data.len < offset + 4) return error.InvalidFrame;
        offset += 4; // skip mask key (server frames shouldn't be masked, but handle it)
    }

    const end = offset + @as(usize, @intCast(payload_len));
    if (data.len < end) return error.InvalidFrame;

    return .{
        .opcode = opcode,
        .fin = fin,
        .payload = data[offset..end],
        .total_size = end,
    };
}

/// Build the WebSocket upgrade request.
pub fn buildUpgradeRequest(buf: []u8, host: []const u8, port: u16, path: []const u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();
    try std.fmt.format(w, "GET {s} HTTP/1.1\r\n", .{path});
    try std.fmt.format(w, "Host: {s}:{d}\r\n", .{ host, port });
    try w.writeAll("Upgrade: websocket\r\n");
    try w.writeAll("Connection: Upgrade\r\n");
    try w.writeAll("Sec-WebSocket-Key: cGxheXBhbmRhLWNkcC1rZXk=\r\n");
    try w.writeAll("Sec-WebSocket-Version: 13\r\n");
    // Origin header required by Chrome 145+ for CDP WebSocket connections
    try std.fmt.format(w, "Origin: http://{s}:{d}\r\n", .{ host, port });
    try w.writeAll("\r\n");
    return stream.getWritten();
}

// -- Live CDP connection (requires actual browser) --

pub const CdpClient = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    next_id: u32 = 1,
    recv_buf: [1048576]u8 = undefined, // 1MB
    recv_len: usize = 0,

    /// Connect to a CDP WebSocket endpoint.
    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16, path: []const u8) !CdpClient {
        // Resolve address
        const address = try std.net.Address.parseIp4(host, port);

        // TCP connect
        const stream = std.net.tcpConnectToAddress(address) catch return error.ConnectionFailed;
        errdefer stream.close();

        // Send WebSocket upgrade
        var upgrade_buf: [1024]u8 = undefined;
        const upgrade = try buildUpgradeRequest(&upgrade_buf, host, port, path);
        _ = stream.write(upgrade) catch return error.ConnectionFailed;

        // Read upgrade response
        var resp_buf: [2048]u8 = undefined;
        const n = stream.read(&resp_buf) catch return error.ConnectionFailed;
        if (n == 0) return error.HandshakeFailed;

        // Verify 101 response
        if (!std.mem.startsWith(u8, resp_buf[0..n], "HTTP/1.1 101")) {
            return error.HandshakeFailed;
        }

        return .{
            .stream = stream,
            .allocator = allocator,
        };
    }

    /// Send a CDP command and return the response JSON.
    pub fn sendCommand(self: *CdpClient, method: []const u8, params: ?[]const u8) !std.json.Parsed(std.json.Value) {
        const id = self.next_id;
        self.next_id += 1;

        // Build and send command
        const cmd_json = try buildCommand(self.allocator, .{
            .id = id,
            .method = method,
            .params = params,
        });
        defer self.allocator.free(cmd_json);

        const frame = try encodeTextFrame(self.allocator, cmd_json);
        defer self.allocator.free(frame);

        _ = self.stream.write(frame) catch return error.ConnectionFailed;

        // Read responses until we get our id
        return self.waitForResponse(id);
    }

    /// Send a CDP command with session ID.
    pub fn sendSessionCommand(self: *CdpClient, session_id: []const u8, method: []const u8, params: ?[]const u8) !std.json.Parsed(std.json.Value) {
        const id = self.next_id;
        self.next_id += 1;

        const cmd_json = try buildCommand(self.allocator, .{
            .id = id,
            .method = method,
            .params = params,
            .session_id = session_id,
        });
        defer self.allocator.free(cmd_json);

        const frame = try encodeTextFrame(self.allocator, cmd_json);
        defer self.allocator.free(frame);

        _ = self.stream.write(frame) catch return error.ConnectionFailed;

        return self.waitForResponse(id);
    }

    /// Read the next complete JSON message (response or event).
    pub fn readMessage(self: *CdpClient) !std.json.Parsed(std.json.Value) {
        var attempts: u32 = 0;
        while (attempts < 500) : (attempts += 1) {
            if (self.recv_len < 2 or !self.hasCompleteFrame()) {
                const n = self.stream.read(self.recv_buf[self.recv_len..]) catch return error.ConnectionFailed;
                if (n == 0) return error.ConnectionClosed;
                self.recv_len += n;
            }

            const frame = decodeFrame(self.recv_buf[0..self.recv_len]) catch continue;

            if (frame.opcode != .text) {
                self.consumeFrame(frame.total_size);
                continue;
            }

            // IMPORTANT: parse JSON BEFORE consuming the frame, because
            // consumeFrame shifts the buffer and invalidates the payload slice.
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                frame.payload,
                .{},
            ) catch {
                self.consumeFrame(frame.total_size);
                continue;
            };

            self.consumeFrame(frame.total_size);
            return parsed;
        }
        return error.Timeout;
    }

    fn waitForResponse(self: *CdpClient, target_id: u32) !std.json.Parsed(std.json.Value) {
        var attempts: u32 = 0;
        while (attempts < 500) : (attempts += 1) {
            if (self.recv_len < 2 or !self.hasCompleteFrame()) {
                const n = self.stream.read(self.recv_buf[self.recv_len..]) catch return error.ConnectionFailed;
                if (n == 0) return error.ConnectionClosed;
                self.recv_len += n;
            }

            const frame = decodeFrame(self.recv_buf[0..self.recv_len]) catch continue;

            if (frame.opcode != .text) {
                self.consumeFrame(frame.total_size);
                continue;
            }

            // Parse JSON BEFORE consuming the frame from buffer.
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                frame.payload,
                .{},
            ) catch {
                self.consumeFrame(frame.total_size);
                continue;
            };

            // Now safe to consume
            self.consumeFrame(frame.total_size);

            const obj = switch (parsed.value) {
                .object => |o| o,
                else => {
                    parsed.deinit();
                    continue;
                },
            };

            const id_val = obj.get("id") orelse {
                // Event without id — skip
                parsed.deinit();
                continue;
            };

            const resp_id: u32 = switch (id_val) {
                .integer => |i| @intCast(i),
                else => {
                    parsed.deinit();
                    continue;
                },
            };

            if (resp_id == target_id) {
                return parsed;
            }

            // Not our response, discard
            parsed.deinit();
        }

        return error.Timeout;
    }

    /// Remove a consumed frame from the front of the recv buffer.
    fn consumeFrame(self: *CdpClient, frame_size: usize) void {
        const remaining = self.recv_len - frame_size;
        if (remaining > 0) {
            std.mem.copyForwards(u8, &self.recv_buf, self.recv_buf[frame_size..self.recv_len]);
        }
        self.recv_len = remaining;
    }

    pub fn hasCompleteFrame(self: *CdpClient) bool {
        if (self.recv_len < 2) return false;
        const masked = (self.recv_buf[1] & 0x80) != 0;
        var payload_len: u64 = self.recv_buf[1] & 0x7F;
        var offset: usize = 2;

        if (payload_len == 126) {
            if (self.recv_len < 4) return false;
            payload_len = std.mem.readInt(u16, self.recv_buf[2..4], .big);
            offset = 4;
        } else if (payload_len == 127) {
            if (self.recv_len < 10) return false;
            payload_len = std.mem.readInt(u64, self.recv_buf[2..10], .big);
            offset = 10;
        }

        if (masked) offset += 4;
        return self.recv_len >= offset + @as(usize, @intCast(payload_len));
    }

    pub fn close(self: *CdpClient) void {
        // Send close frame
        const close_frame = [_]u8{
            0x88, 0x80, // FIN + close opcode, masked, 0 length
            0x00, 0x00, 0x00, 0x00, // mask key
        };
        _ = self.stream.write(&close_frame) catch {};
        self.stream.close();
    }
};

// ── Tests ──

const testing = std.testing;

test "buildCommand — basic method" {
    const cmd = try buildCommand(testing.allocator, .{ .id = 1, .method = "Page.navigate" });
    defer testing.allocator.free(cmd);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, cmd, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqual(@as(i64, 1), obj.get("id").?.integer);
    try testing.expectEqualStrings("Page.navigate", obj.get("method").?.string);
}

test "buildCommand — with params" {
    const cmd = try buildCommand(testing.allocator, .{
        .id = 2,
        .method = "Page.navigate",
        .params = "{\"url\":\"https://example.com\"}",
    });
    defer testing.allocator.free(cmd);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, cmd, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const params = obj.get("params").?.object;
    try testing.expectEqualStrings("https://example.com", params.get("url").?.string);
}

test "buildCommand — with session ID" {
    const cmd = try buildCommand(testing.allocator, .{
        .id = 3,
        .method = "Network.enable",
        .session_id = "sess-123",
    });
    defer testing.allocator.free(cmd);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, cmd, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("sess-123", parsed.value.object.get("sessionId").?.string);
}

test "encodeTextFrame — small payload" {
    const payload = "hello";
    const frame = try encodeTextFrame(testing.allocator, payload);
    defer testing.allocator.free(frame);

    // FIN=1 + text opcode
    try testing.expectEqual(@as(u8, 0x81), frame[0]);
    // Length=5 + MASK bit
    try testing.expectEqual(@as(u8, 5 | 0x80), frame[1]);
    // Total: 2 header + 4 mask + 5 payload = 11
    try testing.expectEqual(@as(usize, 11), frame.len);
}

test "encodeTextFrame — medium payload (126-65535 bytes)" {
    const payload = "x" ** 200;
    const frame = try encodeTextFrame(testing.allocator, payload);
    defer testing.allocator.free(frame);

    try testing.expectEqual(@as(u8, 0x81), frame[0]);
    // Extended length indicator
    try testing.expectEqual(@as(u8, 126 | 0x80), frame[1]);
    // 2 header + 2 ext_len + 4 mask + 200 payload = 208
    try testing.expectEqual(@as(usize, 208), frame.len);
}

test "decodeFrame — text frame" {
    // Unmasked text frame: FIN=1, opcode=text, payload="hi"
    const data = [_]u8{ 0x81, 0x02, 'h', 'i' };
    const frame = try decodeFrame(&data);

    try testing.expectEqual(FrameOpcode.text, frame.opcode);
    try testing.expect(frame.fin);
    try testing.expectEqualStrings("hi", frame.payload);
    try testing.expectEqual(@as(usize, 4), frame.total_size);
}

test "decodeFrame — close frame" {
    const data = [_]u8{ 0x88, 0x00 };
    const frame = try decodeFrame(&data);
    try testing.expectEqual(FrameOpcode.close, frame.opcode);
}

test "decodeFrame — too short returns error" {
    const data = [_]u8{0x81};
    try testing.expectError(error.InvalidFrame, decodeFrame(&data));
}

test "decodeFrame — incomplete payload returns error" {
    // Claims 10 bytes payload but only has 2
    const data = [_]u8{ 0x81, 0x0A, 'h', 'i' };
    try testing.expectError(error.InvalidFrame, decodeFrame(&data));
}

test "buildUpgradeRequest — contains required headers" {
    var buf: [1024]u8 = undefined;
    const req = try buildUpgradeRequest(&buf, "127.0.0.1", 9222, "/devtools/page/ABC");

    try testing.expect(std.mem.indexOf(u8, req, "GET /devtools/page/ABC HTTP/1.1") != null);
    try testing.expect(std.mem.indexOf(u8, req, "Upgrade: websocket") != null);
    try testing.expect(std.mem.indexOf(u8, req, "Sec-WebSocket-Version: 13") != null);
    try testing.expect(std.mem.indexOf(u8, req, "Origin: http://127.0.0.1:9222") != null);
}
