const std = @import("std");

pub const Role = enum { system, user, assistant, tool };

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8, // raw JSON string
};

pub const Message = struct {
    role: Role,
    content: ?[]const u8 = null,
    tool_calls: []ToolCall = &.{},
    tool_call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub fn roleString(r: Role) []const u8 {
    return switch (r) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}
