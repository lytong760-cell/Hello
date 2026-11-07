const std = @import("std");

pub fn run(allocator: std.mem.Allocator, args_json: []const u8) ![]u8 {
    // parse path, optional offset/limit
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    const path = if (o.get("path")) |p| p.string else return error.MissingPath;
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);
    const offset = if (o.get("offset")) |x| (if (x == .integer) @as(usize, @intCast(x.integer)) else 1) else 1;
    const limit = if (o.get("limit")) |x| (if (x == .integer) @as(usize, @intCast(x.integer)) else 2000) else 2000;
    // line-based
    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| try lines.append(ln);
    const start = if (offset > 0) offset - 1 else 0;
    const end = @min(start + limit, lines.items.len);
    var out = std.ArrayList(u8).init(allocator);
    const w = out.writer();
    var i = start;
    while (i < end) : (i += 1) {
        try w.print("{d}: {s}\n", .{ i + 1, lines.items[i] });
    }
    if (end < lines.items.len) try w.print("... ({d} more lines)\n", .{lines.items.len - end});
    return out.toOwnedSlice();
}
