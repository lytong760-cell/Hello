const std = @import("std");
const types = @import("../types.zig");
const config = @import("../config.zig");

pub const ToolCall = types.ToolCall;
pub const Response = struct {
    content: ?[]const u8,
    tool_calls: []ToolCall,
};

fn escapeJson(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    const w = out.writer();
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c);
            },
        }
    }
    return out.toOwnedSlice();
}

fn baseUrl(cfg: config.Config, default: []const u8) []const u8 {
    if (cfg.base_url_override) |b| if (b.len > 0) return b;
    return default;
}

pub fn chatOpenAI(allocator: std.mem.Allocator, cfg: config.Config, messages: []const types.Message, tools_json: []const u8) !Response {
    const key = cfg.openai_key orelse return error.MissingApiKey;
    const model = cfg.model;
    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{baseUrl(cfg, "https://api.openai.com/v1")});
    defer allocator.free(url);

    // build messages JSON
    var body = std.ArrayList(u8).init(allocator);
    const w = body.writer();
    try w.writeAll("{\"model\":\"");
    try w.writeAll(model);
    try w.writeAll("\",\"messages\":[");
    for (messages, 0..) |m, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"role\":\"");
        try w.writeAll(types.roleString(m.role));
        try w.writeAll("\"");
        if (m.content) |c| {
            const esc = try escapeJson(allocator, c);
            defer allocator.free(esc);
            try w.writeAll(",\"content\":\"");
            try w.writeAll(esc);
            try w.writeAll("\"");
        } else {
            try w.writeAll(",\"content\":null");
        }
        if (m.tool_calls.len > 0) {
            try w.writeAll(",\"tool_calls\":[");
            for (m.tool_calls, 0..) |tc, j| {
                if (j > 0) try w.writeByte(',');
                const escArgs = try escapeJson(allocator, tc.arguments);
                defer allocator.free(escArgs);
                const escName = try escapeJson(allocator, tc.name);
                defer allocator.free(escName);
                const escId = try escapeJson(allocator, tc.id);
                defer allocator.free(escId);
                try w.print("{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}}}", .{ escId, escName, escArgs });
            }
            try w.writeAll("]");
        }
        if (m.tool_call_id) |tid| {
            const esc = try escapeJson(allocator, tid);
            defer allocator.free(esc);
            try w.writeAll(",\"tool_call_id\":\"");
            try w.writeAll(esc);
            try w.writeAll("\"");
        }
        if (m.name) |nm| {
            const esc = try escapeJson(allocator, nm);
            defer allocator.free(esc);
            try w.writeAll(",\"name\":\"");
            try w.writeAll(esc);
            try w.writeAll("\"");
        }
        try w.writeByte('}');
    }
    try w.writeAll("]");
    if (tools_json.len > 0) {
        try w.writeAll(",\"tools\":");
        try w.writeAll(tools_json);
        try w.writeAll(",\"tool_choice\":\"auto\"");
    }
    try w.writeAll("}");

    // HTTP request
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const uri = try std.Uri.parse(url);
    var header_buf: [16384]u8 = undefined;
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = &header_buf,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key}) },
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.items.len };
    try req.send();
    try req.writeAll(body.items);
    try req.finish();
    try req.wait();

    const resp_body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(resp_body);

    if (req.response.status != .ok) {
        // return error text
        return .{ .content = try allocator.dupe(u8, resp_body), .tool_calls = &.{} };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp_body, .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;
    const choices = root_obj.get("choices").?.array;
    const msg = choices.items[0].object.get("message").?.object;

    var content: ?[]const u8 = null;
    if (msg.get("content")) |c| {
        if (c == .string) content = try allocator.dupe(u8, c.string);
    }

    var tcs = std.ArrayList(ToolCall).init(allocator);
    if (msg.get("tool_calls")) |tc_arr| {
        if (tc_arr == .array) {
            for (tc_arr.array.items) |tc| {
                const o2 = tc.object;
                const id = if (o2.get("id")) |x| (if (x == .string) x.string else "") else "";
                const fnobj = o2.get("function").?.object;
                const name = if (fnobj.get("name")) |x| (if (x == .string) x.string else "") else "";
                const args = if (fnobj.get("arguments")) |x| (if (x == .string) x.string else "{}") else "{}";
                try tcs.append(.{
                    .id = try allocator.dupe(u8, id),
                    .name = try allocator.dupe(u8, name),
                    .arguments = try allocator.dupe(u8, args),
                });
            }
        }
    }
    return .{ .content = content, .tool_calls = try tcs.toOwnedSlice() };
}

// Anthropic
pub fn chatAnthropic(allocator: std.mem.Allocator, cfg: config.Config, messages: []const types.Message, tools_json: []const u8) !Response {
    const key = cfg.anthropic_key orelse return error.MissingApiKey;
    _ = tools_json;
    const url = "https://api.anthropic.com/v1/messages";
    // Build request: separate system
    var system_text = std.ArrayList(u8).init(allocator);
    defer system_text.deinit();
    var body = std.ArrayList(u8).init(allocator);
    const w = body.writer();
    try w.writeAll("{\"model\":\"");
    try w.writeAll(cfg.model);
    try w.writeAll("\",\"max_tokens\":4096,\"messages\":[");
    var first = true;
    for (messages) |m| {
        if (m.role == .system) {
            if (system_text.items.len > 0) try system_text.append('\n');
            if (m.content) |c| try system_text.appendSlice(c);
            continue;
        }
        if (!first) try w.writeByte(',');
        first = false;
        const role = if (m.role == .assistant) "assistant" else "user";
        try w.print("{{\"role\":\"{s}\",\"content\":\"", .{role});
        const esc = try escapeJson(allocator, m.content orelse "");
        defer allocator.free(esc);
        try w.writeAll(esc);
        try w.writeAll("\"}");
    }
    try w.writeAll("]}");
    // inject system if any
    // rebuild with system field is complex; append by inserting not easy. We'll just prepend system into first user? Instead add "system" field before messages via separate construction: redo simpler: build full body again with system.
    // Redo properly:
    body.clearRetainingCapacity();
    const w2 = body.writer();
    try w2.writeAll("{\"model\":\"");
    try w2.writeAll(cfg.model);
    try w2.writeAll("\",\"max_tokens\":4096");
    if (system_text.items.len > 0) {
        const esc = try escapeJson(allocator, system_text.items);
        defer allocator.free(esc);
        try w2.writeAll(",\"system\":\"");
        try w2.writeAll(esc);
        try w2.writeAll("\"");
    }
    try w2.writeAll(",\"messages\":[");
    first = true;
    for (messages) |m| {
        if (m.role == .system) continue;
        if (!first) try w2.writeByte(',');
        first = false;
        const role = if (m.role == .assistant) "assistant" else "user";
        try w2.print("{{\"role\":\"{s}\",\"content\":\"", .{role});
        const esc = try escapeJson(allocator, m.content orelse "");
        defer allocator.free(esc);
        try w2.writeAll(esc);
        try w2.writeAll("\"}");
    }
    try w2.writeAll("]}");

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const uri = try std.Uri.parse(url);
    var header_buf2: [16384]u8 = undefined;
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = &header_buf2,
        .extra_headers = &.{
            .{ .name = "x-api-key", .value = key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.items.len };
    try req.send();
    try req.writeAll(body.items);
    try req.finish();
    try req.wait();
    const resp_body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(resp_body);
    if (req.response.status != .ok) {
        return .{ .content = try allocator.dupe(u8, resp_body), .tool_calls = &.{} };
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp_body, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    const content_arr = o.get("content").?.array;
    var text = std.ArrayList(u8).init(allocator);
    defer text.deinit();
    for (content_arr.items) |c| {
        if (c.object.get("type")) |t| {
            if (t == .string and std.mem.eql(u8, t.string, "text")) {
                if (c.object.get("text")) |tx| if (tx == .string) try text.appendSlice(tx.string);
            }
        }
    }
    // Anthropic tool calls not wired in v1 (text only)
    return .{ .content = try allocator.dupe(u8, text.items), .tool_calls = &.{} };
}

// Google Gemini
pub fn chatGoogle(allocator: std.mem.Allocator, cfg: config.Config, messages: []const types.Message, tools_json: []const u8) !Response {
    const key = cfg.google_key orelse return error.MissingApiKey;
    _ = tools_json;
    const url = try std.fmt.allocPrint(allocator, "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent?key={s}", .{ cfg.model, key });
    defer allocator.free(url);

    var body = std.ArrayList(u8).init(allocator);
    const w = body.writer();
    try w.writeAll("{\"contents\":[");
    var first = true;
    for (messages) |m| {
        if (m.role == .system) continue;
        if (!first) try w.writeByte(',');
        first = false;
        const role = if (m.role == .assistant) "model" else "user";
        try w.print("{{\"role\":\"{s}\",\"parts\":[{{\"text\":\"", .{role});
        const esc = try escapeJson(allocator, m.content orelse "");
        defer allocator.free(esc);
        try w.writeAll(esc);
        try w.writeAll("\"}]}}");
    }
    try w.writeAll("]}");

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const uri = try std.Uri.parse(url);
    var header_buf3: [16384]u8 = undefined;
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = &header_buf3,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.items.len };
    try req.send();
    try req.writeAll(body.items);
    try req.finish();
    try req.wait();
    const resp_body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(resp_body);
    if (req.response.status != .ok) {
        return .{ .content = try allocator.dupe(u8, resp_body), .tool_calls = &.{} };
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp_body, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    const cands = o.get("candidates").?.array;
    const firstc = cands.items[0].object;
    const content = firstc.get("content").?.object;
    const parts = content.get("parts").?.array;
    var text = std.ArrayList(u8).init(allocator);
    defer text.deinit();
    for (parts.items) |p| {
        if (p.object.get("text")) |t| if (t == .string) try text.appendSlice(t.string);
    }
    return .{ .content = try allocator.dupe(u8, text.items), .tool_calls = &.{} };
}

// Kilo gateway (OpenAI-compatible)
pub fn chatKilo(allocator: std.mem.Allocator, cfg: config.Config, messages: []const types.Message, tools_json: []const u8) !Response {
    // reuse openai with kilo base url + key
    var c = cfg;
    if (c.kilo_key) |k| c.openai_key = k;
    if (c.base_url_override == null) c.base_url_override = "https://api.kilo.ai/api/gateway";
    // need openai_key set; if kilo_key present use it
    if (cfg.kilo_key) |k| c.openai_key = k;
    return chatOpenAI(allocator, c, messages, tools_json);
}

pub fn chat(allocator: std.mem.Allocator, cfg: config.Config, messages: []const types.Message, tools_json: []const u8) !Response {
    if (std.mem.eql(u8, cfg.provider, "anthropic")) return chatAnthropic(allocator, cfg, messages, tools_json);
    if (std.mem.eql(u8, cfg.provider, "google")) return chatGoogle(allocator, cfg, messages, tools_json);
    if (std.mem.eql(u8, cfg.provider, "kilo")) return chatKilo(allocator, cfg, messages, tools_json);
    return chatOpenAI(allocator, cfg, messages, tools_json);
}
