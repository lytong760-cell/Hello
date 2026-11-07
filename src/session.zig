const std = @import("std");
const types = @import("types.zig");

pub fn save(allocator: std.mem.Allocator, path: []const u8, messages: []const types.Message) !void {
    // ensure parent
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }
    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();
    const w = body.writer();
    try w.writeAll("[");
    for (messages, 0..) |m, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"role\":\"");
        try w.writeAll(types.roleString(m.role));
        try w.writeAll("\"");
        if (m.content) |c| {
            // escape
            try w.writeAll(",\"content\":\"");
            for (c) |ch| {
                switch (ch) {
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    '\t' => try w.writeAll("\\t"),
                    else => try w.writeByte(ch),
                }
            }
            try w.writeAll("\"");
        }
        try w.writeByte('}');
    }
    try w.writeAll("]");
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(body.items);
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) ![]types.Message {
    const f = try std.fs.openFileAbsolute(path, .{});
    defer f.close();
    const data = try f.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    var list = std.ArrayList(types.Message).init(allocator);
    for (arr.items) |v| {
        const o = v.object;
        const role_str = o.get("role").?.string;
        const role: types.Role = if (std.mem.eql(u8, role_str, "system")) .system else if (std.mem.eql(u8, role_str, "assistant")) .assistant else if (std.mem.eql(u8, role_str, "tool")) .tool else .user;
        var content: ?[]const u8 = null;
        if (o.get("content")) |c| {
            if (c == .string) {
                content = try allocator.dupe(u8, c.string);
            }
        }
        try list.append(.{ .role = role, .content = content });
    }
    return list.toOwnedSlice();
}
