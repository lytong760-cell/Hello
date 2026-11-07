const std = @import("std");

pub fn run(allocator: std.mem.Allocator, args_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    const command = if (o.get("command")) |c| c.string else return error.MissingCommand;

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", command }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout_buf = std.ArrayList(u8).init(allocator);
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    defer stderr_buf.deinit();
    try std.process.Child.collectOutput(child, &stdout_buf, &stderr_buf, 10 * 1024 * 1024);
    const term = try child.wait();

    var out = std.ArrayList(u8).init(allocator);
    const w = out.writer();
    if (stdout_buf.items.len > 0) try w.writeAll(stdout_buf.items);
    if (stderr_buf.items.len > 0) {
        try w.writeAll("\n[stderr]\n");
        try w.writeAll(stderr_buf.items);
    }
    const code: i32 = switch (term) {
        .Exited => |c| @as(i32, c),
        else => -1,
    };
    try w.print("\n[exit code: {d}]\n", .{code});
    return out.toOwnedSlice();
}
