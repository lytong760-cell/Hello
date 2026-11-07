const std = @import("std");

pub fn run(allocator: std.mem.Allocator, args_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    const path = if (o.get("path")) |p| p.string else return error.MissingPath;
    const content = if (o.get("content")) |c| c.string else return error.MissingContent;
    // ensure parent dir exists
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
    return try std.fmt.allocPrint(allocator, "Wrote {d} bytes to {s}", .{ content.len, path });
}
