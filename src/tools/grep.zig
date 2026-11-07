const std = @import("std");

pub fn run(allocator: std.mem.Allocator, args_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    const pattern = if (o.get("pattern")) |p| p.string else return error.MissingPattern;
    const root = if (o.get("path")) |p| p.string else ".";
    const include = if (o.get("include")) |p| p.string else null;

    const abs_root = if (std.fs.path.isAbsolute(root)) try allocator.dupe(u8, root) else blk: {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.join(allocator, &.{ cwd, root });
    };
    defer allocator.free(abs_root);

    var out = std.ArrayList(u8).init(allocator);
    const w = out.writer();
    var count: usize = 0;
    const max: usize = 200;

    const Walker = struct {
        fn isMatchName(name: []const u8, inc: ?[]const u8) bool {
            if (inc == null) return true;
            // simple suffix match on include like *.zig
            const p = inc.?;
            if (std.mem.startsWith(u8, p, "*.")) {
                const ext = p[1..];
                return std.mem.endsWith(u8, name, ext);
            }
            return std.mem.indexOf(u8, name, p) != null;
        }
    };

    var dir = try std.fs.openDirAbsolute(abs_root, .{ .iterate = true });
    // recursive
    const Rec = struct {
        fn run(alloc: std.mem.Allocator, d: *std.fs.Dir, prefix: []const u8, pat: []const u8, inc: ?[]const u8, writer: anytype, counter: *usize, mx: usize) !void {
            var it = d.iterate();
            while (try it.next()) |entry| {
                const full = try std.fs.path.join(alloc, &.{ prefix, entry.name });
                defer alloc.free(full);
                if (entry.kind == .directory) {
                    var sub = d.openDir(entry.name, .{ .iterate = true }) catch continue;
                    defer sub.close();
                    try @This().run(alloc, &sub, full, pat, inc, writer, counter, mx);
                } else if (entry.kind == .file) {
                    if (!Walker.isMatchName(entry.name, inc)) continue;
                    const f = std.fs.openFileAbsolute(full, .{}) catch continue;
                    defer f.close();
                    const data = f.readToEndAlloc(alloc, 1024 * 1024) catch continue;
                    defer alloc.free(data);
                    var lines = std.mem.splitScalar(u8, data, '\n');
                    var ln: usize = 0;
                    while (lines.next()) |l| {
                        ln += 1;
                        if (std.mem.indexOf(u8, l, pat) != null) {
                            try writer.print("{s}:{d}: {s}\n", .{ full, ln, l });
                            counter.* += 1;
                            if (counter.* >= mx) return;
                        }
                    }
                }
            }
        }
    };
    try Rec.run(allocator, &dir, abs_root, pattern, include, w, &count, max);
    dir.close();
    if (count == 0) try w.writeAll("(no matches)\n");
    return out.toOwnedSlice();
}
