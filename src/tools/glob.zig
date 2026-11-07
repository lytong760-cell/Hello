const std = @import("std");

fn match(pattern: []const u8, name: []const u8) bool {
    // simple * and ? glob
    if (pattern.len == 0) return name.len == 0;
    // We'll do two-pointer backtracking
    var i: usize = 0;
    var j: usize = 0;
    var star_i: ?usize = null;
    var star_j: usize = 0;
    while (j < name.len) {
        if (i < pattern.len and (pattern[i] == '?' or pattern[i] == name[j])) {
            i += 1;
            j += 1;
        } else if (i < pattern.len and pattern[i] == '*') {
            star_i = i;
            star_j = j;
            i += 1;
        } else if (star_i) |si| {
            i = si + 1;
            star_j += 1;
            j = star_j;
        } else {
            return false;
        }
    }
    while (i < pattern.len and pattern[i] == '*') i += 1;
    return i == pattern.len;
}

pub fn run(allocator: std.mem.Allocator, args_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    const pattern = if (o.get("pattern")) |p| p.string else "*";
    const root = if (o.get("path")) |p| p.string else ".";
    // resolve root to absolute
    const abs_root = if (std.fs.path.isAbsolute(root)) try allocator.dupe(u8, root) else blk: {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.join(allocator, &.{ cwd, root });
    };
    defer allocator.free(abs_root);

    var out = std.ArrayList(u8).init(allocator);
    const w = out.writer();
    var dir = try std.fs.openDirAbsolute(abs_root, .{ .iterate = true });
    // recursive walk
    const Walker = struct {
        fn walk(alloc: std.mem.Allocator, d: *std.fs.Dir, prefix: []const u8, pat: []const u8, writer: anytype) !void {
            var it = d.iterate();
            while (try it.next()) |entry| {
                const full = try std.fs.path.join(alloc, &.{ prefix, entry.name });
                defer alloc.free(full);
                if (entry.kind == .directory) {
                    var sub = d.openDir(entry.name, .{ .iterate = true }) catch continue;
                    defer sub.close();
                    try walk(alloc, &sub, full, pat, writer);
                } else if (entry.kind == .file) {
                    if (match(pat, entry.name)) {
                        try writer.print("{s}\n", .{full});
                    }
                }
            }
        }
    };
    try Walker.walk(allocator, &dir, abs_root, pattern, w);
    dir.close();
    if (out.items.len == 0) try w.writeAll("(no matches)\n");
    return out.toOwnedSlice();
}
