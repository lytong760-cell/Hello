const std = @import("std");

pub fn println(s: []const u8) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("{s}\n", .{s}) catch {};
}

pub fn print(s: []const u8) void {
    const stdout = std.io.getStdOut().writer();
    stdout.writeAll(s) catch {};
}

pub fn prompt() void {
    const stdout = std.io.getStdOut().writer();
    stdout.writeAll("\n> ") catch {};
}
