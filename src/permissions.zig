const std = @import("std");

pub fn confirm(allocator: std.mem.Allocator, action: []const u8) bool {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    stdout.print("Allow {s}? [y/N] ", .{action}) catch {};
    var buf: [64]u8 = undefined;
    const n = stdin.readUntilDelimiterOrEof(&buf, '\n') catch return false;
    const line = if (n) |b| std.mem.trim(u8, b, " \r\n") else return false;
    _ = allocator;
    return std.mem.eql(u8, line, "y") or std.mem.eql(u8, line, "Y") or std.mem.eql(u8, line, "yes");
}
