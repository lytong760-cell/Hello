const std = @import("std");

// returns: 0 = deny, 1 = allow, 2 = always allow
pub fn confirm(allocator: std.mem.Allocator, action: []const u8) i32 {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    stdout.print("Allow {s}? [y/N/a] ", .{action}) catch {};
    var buf: [64]u8 = undefined;
    const n = stdin.readUntilDelimiterOrEof(&buf, '\n') catch return 0;
    const line = if (n) |b| std.mem.trim(u8, b, " \r\n") else return 0;
    _ = allocator;
    if (std.mem.eql(u8, line, "y") or std.mem.eql(u8, line, "Y") or std.mem.eql(u8, line, "yes")) return 1;
    if (std.mem.eql(u8, line, "a") or std.mem.eql(u8, line, "A") or std.mem.eql(u8, line, "always")) return 2;
    return 0;
}
