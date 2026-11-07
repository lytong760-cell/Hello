const std = @import("std");

pub fn run(allocator: std.mem.Allocator, args_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    const path = if (o.get("path")) |p| p.string else return error.MissingPath;
    const old = if (o.get("old_string")) |x| x.string else return error.MissingOld;
    const new = if (o.get("new_string")) |x| x.string else return error.MissingNew;
    const f = try std.fs.openFileAbsolute(path, .{});
    defer f.close();
    const data = try f.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);
    const idx = std.mem.indexOf(u8, data, old) orelse return error.NotFound;
    // count occurrences
    var count: usize = 0;
    var search: usize = 0;
    while (std.mem.indexOf(u8, data[search..], old)) |i| {
        count += 1;
        search += i + old.len;
    }
    if (count > 1) return error.MultipleMatches;
    var out = std.ArrayList(u8).init(allocator);
    try out.appendSlice(data[0..idx]);
    try out.appendSlice(new);
    try out.appendSlice(data[idx + old.len ..]);
    const nf = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer nf.close();
    try nf.writeAll(out.items);
    return try std.fmt.allocPrint(allocator, "Edited {s}", .{path});
}
