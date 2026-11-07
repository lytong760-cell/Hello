const std = @import("std");
const config = @import("config.zig");

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    body: []const u8,
    path: []const u8,
};

pub fn loadAll(allocator: std.mem.Allocator, cwd: []const u8) ![]Skill {
    var list = std.ArrayList(Skill).init(allocator);
    errdefer list.deinit();
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch "/tmp";
    defer if (home.ptr != "/tmp".ptr) allocator.free(home);

    // global then project
    const dirs = [_][]const u8{
        try std.fmt.allocPrint(allocator, "{s}/.config/hello/skills", .{home}),
        try std.fmt.allocPrint(allocator, "{s}/.hello/skills", .{cwd}),
    };
    for (dirs) |d| {
        defer allocator.free(d);
        var dir = std.fs.openDirAbsolute(d, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ d, entry.name });
            const f = std.fs.openFileAbsolute(full, .{}) catch { allocator.free(full); continue; };
            defer f.close();
            const data = f.readToEndAlloc(allocator, 1024 * 1024) catch { allocator.free(full); continue; };
            // parse frontmatter
            var name: []const u8 = entry.name[0 .. entry.name.len - 3];
            var desc: []const u8 = "";
            var body: []const u8 = data;
            if (std.mem.startsWith(u8, data, "---\n")) {
                const rest = data[4..];
                if (std.mem.indexOf(u8, rest, "\n---\n")) |end| {
                    const fm = rest[0..end];
                    body = rest[end + 5 ..];
                    // parse name/description lines
                    var lines = std.mem.splitScalar(u8, fm, '\n');
                    while (lines.next()) |ln| {
                        if (std.mem.startsWith(u8, ln, "name:")) {
                            name = std.mem.trim(u8, ln[5..], " ");
                        } else if (std.mem.startsWith(u8, ln, "description:")) {
                            desc = std.mem.trim(u8, ln[12..], " ");
                        }
                    }
                }
            }
            name = try allocator.dupe(u8, name);
            desc = try allocator.dupe(u8, desc);
            body = try allocator.dupe(u8, body);
            try list.append(.{ .name = name, .description = desc, .body = body, .path = full });
        }
    }
    return list.toOwnedSlice();
}
