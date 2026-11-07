const std = @import("std");
const types = @import("../types.zig");
const config = @import("../config.zig");

pub const StreamCallback = *const fn (ctx: *anyopaque, chunk: []const u8) void;

pub const ToolCall = types.ToolCall;

pub const Response = struct {
    content: ?[]const u8,
    tool_calls: []ToolCall,
};

const ToolAccum = struct {
    id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    args: std.ArrayList(u8),
    has: bool = false,
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

fn postHttp(allocator: std.mem.Allocator, url: []const u8, headers: []const std.http.Header, body: []const u8) !struct { status: std.http.Status, body: []u8 } {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const uri = try std.Uri.parse(url);
    var header_buf: [16384]u8 = undefined;
    var req = try client.open(.POST, uri, .{ .server_header_buffer = &header_buf, .extra_headers = headers });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.len };
    try req.send();
    try req.writeAll(body);
    try req.finish();
    try req.wait();
    const resp = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    return .{ .status = req.response.status, .body = resp };
}

fn buildOpenAIMessages(allocator: std.mem.Allocator, messages: []const types.Message) ![]u8 {
    var body = std.ArrayList(u8).init(allocator);
    const w = body.writer();
    try w.writeAll("[");
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
    return body.toOwnedSlice();
}

fn chatOpenAIStream(allocator: std.mem.Allocator, cfg: config.Config, messages: []const types.Message, tools_json: []const u8, on_token: ?StreamCallback, ctx: *anyopaque) !Response {
    const key = cfg.openai_key orelse return error.MissingApiKey;
    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{baseUrl(cfg, "https://api.openai.com/v1")});
    defer allocator.free(url);

    const msgs = try buildOpenAIMessages(allocator, messages);
    defer allocator.free(msgs);

    var body = std.ArrayList(u8).init(allocator);
    const w = body.writer();
    try w.writeAll("{\"model\":\"");
    try w.writeAll(cfg.model);
    try w.writeAll("\",\"messages\":");
    try w.writeAll(msgs);
    try w.writeAll(",\"stream\":true");
    if (tools_json.len > 0 and !std.mem.eql(u8, tools_json, "[]")) {
        try w.writeAll(",\"tools\":");
        try w.writeAll(tools_json);
        try w.writeAll(",\"tool_choice\":\"auto\"");
    }
    try w.writeAll("}");

    // retry loop
    var attempt: u8 = 0;
    while (true) {
        attempt += 1;
        var client = std.http.Client{ .allocator = allocator };
        const uri = try std.Uri.parse(url);
        var header_buf: [16384]u8 = undefined;
        var req = client.open(.POST, uri, .{
            .server_header_buffer = &header_buf,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key}) },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch |e| {
            client.deinit();
            if (attempt < 3) {
                const delay: u64 = switch (attempt) { 1 => 250, 2 => 1000, else => 4000 };
                std.time.sleep(delay * std.time.ns_per_ms);
                continue;
            }
            return e;
        };
        req.transfer_encoding = .{ .content_length = body.items.len };
        req.send() catch |e| {
            req.deinit();
            client.deinit();
            if (attempt < 3) {
                const delay: u64 = switch (attempt) { 1 => 250, 2 => 1000, else => 4000 };
                std.time.sleep(delay * std.time.ns_per_ms);
                continue;
            }
            return e;
        };
        req.writeAll(body.items) catch |e| {
            req.deinit();
            client.deinit();
            return e;
        };
        req.finish() catch |e| {
            req.deinit();
            client.deinit();
            return e;
        };
        req.wait() catch |e| {
            req.deinit();
            client.deinit();
            if (attempt < 3) {
                const delay: u64 = switch (attempt) { 1 => 250, 2 => 1000, else => 4000 };
                std.time.sleep(delay * std.time.ns_per_ms);
                continue;
            }
            return e;
        };

        if (req.response.status != .ok) {
            const status = req.response.status;
            const rb = req.reader().readAllAlloc(allocator, 10 * 1024 * 1024) catch "";
            req.deinit();
            client.deinit();
            if (@intFromEnum(status) >= 500 and attempt < 3) {
                const delay: u64 = switch (attempt) { 1 => 250, 2 => 1000, else => 4000 };
                std.time.sleep(delay * std.time.ns_per_ms);
                continue;
            }
            const content = if (rb.len > 0) rb else try allocator.dupe(u8, "");
            return .{ .content = content, .tool_calls = &.{} };
        }

        // stream parse
        var content_buf = std.ArrayList(u8).init(allocator);
        var accum = std.ArrayList(ToolAccum).init(allocator);
        defer {
            for (accum.items) |*a| {
                a.id.deinit();
                a.name.deinit();
                a.args.deinit();
            }
            accum.deinit();
        }

        const reader = req.reader();
        var line_buf: [65536]u8 = undefined;
        while (true) {
            const line_opt = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch break;
            if (line_opt == null) break;
            const l = std.mem.trim(u8, line_opt.?, " \r");
            if (l.len == 0) continue;
            if (!std.mem.startsWith(u8, l, "data:")) continue;
            const data = std.mem.trim(u8, l[5..], " ");
            if (std.mem.eql(u8, data, "[DONE]")) break;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
            defer parsed.deinit();
            const root_obj = parsed.value.object;
            const choices = root_obj.get("choices") orelse continue;
            if (choices != .array or choices.array.items.len == 0) continue;
            const delta = choices.array.items[0].object.get("delta") orelse continue;
            if (delta != .object) continue;
            if (delta.object.get("content")) |c| {
                if (c == .string and c.string.len > 0) {
                    try content_buf.appendSlice(c.string);
                    if (on_token) |cb| cb(ctx, c.string);
                }
            }
            if (delta.object.get("tool_calls")) |tc_arr| {
                if (tc_arr == .array) {
                    for (tc_arr.array.items) |tc| {
                        const idx: usize = if (tc.object.get("index")) |x| (if (x == .integer) @as(usize, @intCast(x.integer)) else 0) else 0;
                        while (accum.items.len <= idx) try accum.append(.{ .id = std.ArrayList(u8).init(allocator), .name = std.ArrayList(u8).init(allocator), .args = std.ArrayList(u8).init(allocator) });
                        var a = &accum.items[idx];
                        a.has = true;
                        if (tc.object.get("id")) |x| if (x == .string) {
                            a.id.clearRetainingCapacity();
                            try a.id.appendSlice(x.string);
                        };
                        if (tc.object.get("function")) |fnobj| {
                            if (fnobj == .object) {
                                if (fnobj.object.get("name")) |x| if (x == .string) {
                                    a.name.clearRetainingCapacity();
                                    try a.name.appendSlice(x.string);
                                };
                                if (fnobj.object.get("arguments")) |x| if (x == .string) {
                                    try a.args.appendSlice(x.string);
                                };
                            }
                        }
                    }
                }
            }
        }

        req.deinit();
        client.deinit();

        var tcs = std.ArrayList(ToolCall).init(allocator);
        for (accum.items) |a| {
            if (!a.has) continue;
            try tcs.append(.{
                .id = try allocator.dupe(u8, a.id.items),
                .name = try allocator.dupe(u8, a.name.items),
                .arguments = try allocator.dupe(u8, a.args.items),
            });
        }
        const content: ?[]const u8 = if (content_buf.items.len > 0) try allocator.dupe(u8, content_buf.items) else null;
        return .{ .content = content, .tool_calls = try tcs.toOwnedSlice() };
    }
}

// ---------- Anthropic ----------
fn chatAnthropic(allocator: std.mem.Allocator, cfg: config.Config, messages: []const types.Message, tools_json: []const u8, on_token: ?StreamCallback, ctx: *anyopaque) !Response {
    _ = tools_json;
    const key = cfg.anthropic_key orelse return error.MissingApiKey;
    const url = "https://api.anthropic.com/v1/messages";

    var system_text = std.ArrayList(u8).init(allocator);
    defer system_text.deinit();
    for (messages) |m| {
        if (m.role == .system) {
            if (system_text.items.len > 0) try system_text.append('\n');
            if (m.content) |c| try system_text.appendSlice(c);
        }
    }

    var body = std.ArrayList(u8).init(allocator);
    const w = body.writer();
    try w.writeAll("{\"model\":\"");
    try w.writeAll(cfg.model);
    try w.writeAll("\",\"max_tokens\":4096");
    if (system_text.items.len > 0) {
        const esc = try escapeJson(allocator, system_text.items);
        defer allocator.free(esc);
        try w.writeAll(",\"system\":\"");
        try w.writeAll(esc);
        try w.writeAll("\"");
    }
    try w.writeAll(",\"messages\":[");
    var first = true;
    for (messages) |m| {
        if (m.role == .system) continue;
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

    const r = try postHttp(allocator, url, &.{
        .{ .name = "x-api-key", .value = key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
        .{ .name = "Content-Type", .value = "application/json" },
    }, body.items);
    defer allocator.free(r.body);
    if (r.status != .ok) {
        return .{ .content = try allocator.dupe(u8, r.body), .tool_calls = &.{} };
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.body, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    const content_arr = o.get("content").?.array;
    var text = std.ArrayList(u8).init(allocator);
    defer text.deinit();
    var tcs = std.ArrayList(ToolCall).init(allocator);
    for (content_arr.items) |c| {
        if (c != .object) continue;
        const co = c.object;
        const ctype = if (co.get("type")) |t| (if (t == .string) t.string else "") else "";
        if (std.mem.eql(u8, ctype, "text")) {
            if (co.get("text")) |tx| if (tx == .string) try text.appendSlice(tx.string);
        } else if (std.mem.eql(u8, ctype, "tool_use")) {
            const id = if (co.get("id")) |x| (if (x == .string) x.string else "") else "";
            const name = if (co.get("name")) |x| (if (x == .string) x.string else "") else "";
            const input = co.get("input");
            const args = if (input) |inp| try std.json.stringifyAlloc(allocator, inp, .{}) else try allocator.dupe(u8, "{}");
            try tcs.append(.{ .id = try allocator.dupe(u8, id), .name = try allocator.dupe(u8, name), .arguments = args });
        }
    }
    if (on_token) |cb| if (text.items.len > 0) cb(ctx, text.items);
    const content: ?[]const u8 = if (text.items.len > 0) try allocator.dupe(u8, text.items) else null;
    return .{ .content = content, .tool_calls = try tcs.toOwnedSlice() };
}

// ---------- Google ----------
fn chatGoogle(allocator: std.mem.Allocator, cfg: config.Config, messages: []const types.Message, tools_json: []const u8, on_token: ?StreamCallback, ctx: *anyopaque) !Response {
    _ = tools_json;
    const key = cfg.google_key orelse return error.MissingApiKey;
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

    const r = try postHttp(allocator, url, &.{.{ .name = "Content-Type", .value = "application/json" }}, body.items);
    defer allocator.free(r.body);
    if (r.status != .ok) {
        return .{ .content = try allocator.dupe(u8, r.body), .tool_calls = &.{} };
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.body, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    const cands = o.get("candidates").?.array;
    const firstc = cands.items[0].object;
    const content = firstc.get("content").?.object;
    const parts = content.get("parts").?.array;
    var text = std.ArrayList(u8).init(allocator);
    defer text.deinit();
    var tcs = std.ArrayList(ToolCall).init(allocator);
    for (parts.items) |p| {
        if (p != .object) continue;
        const po = p.object;
        if (po.get("text")) |t| if (t == .string) try text.appendSlice(t.string);
        if (po.get("functionCall")) |fc| {
            if (fc == .object) {
                const name = if (fc.object.get("name")) |x| (if (x == .string) x.string else "") else "";
                const args = if (fc.object.get("args")) |a| try std.json.stringifyAlloc(allocator, a, .{}) else try allocator.dupe(u8, "{}");
                try tcs.append(.{ .id = try std.fmt.allocPrint(allocator, "call_{d}", .{tcs.items.len}), .name = try allocator.dupe(u8, name), .arguments = args });
            }
        }
    }
    if (on_token) |cb| if (text.items.len > 0) cb(ctx, text.items);
    const content_out: ?[]const u8 = if (text.items.len > 0) try allocator.dupe(u8, text.items) else null;
    return .{ .content = content_out, .tool_calls = try tcs.toOwnedSlice() };
}

// ---------- Kilo ----------
fn chatKilo(allocator: std.mem.Allocator, cfg: config.Config, messages: []const types.Message, tools_json: []const u8, on_token: ?StreamCallback, ctx: *anyopaque) !Response {
    var c = cfg;
    if (cfg.kilo_key) |k| c.openai_key = k;
    if (c.base_url_override == null) c.base_url_override = "https://api.kilo.ai/api/gateway";
    if (cfg.kilo_key) |k| c.openai_key = k;
    return chatOpenAIStream(allocator, c, messages, tools_json, on_token, ctx);
}

// ---------- Public ----------
pub fn chatStream(allocator: std.mem.Allocator, cfg: config.Config, messages: []const types.Message, tools_json: []const u8, on_token: ?StreamCallback, ctx: *anyopaque) !Response {
    if (std.mem.eql(u8, cfg.provider, "anthropic")) return chatAnthropic(allocator, cfg, messages, tools_json, on_token, ctx);
    if (std.mem.eql(u8, cfg.provider, "google")) return chatGoogle(allocator, cfg, messages, tools_json, on_token, ctx);
    if (std.mem.eql(u8, cfg.provider, "kilo")) return chatKilo(allocator, cfg, messages, tools_json, on_token, ctx);
    return chatOpenAIStream(allocator, cfg, messages, tools_json, on_token, ctx);
}

pub fn chat(allocator: std.mem.Allocator, cfg: config.Config, messages: []const types.Message, tools_json: []const u8) !Response {
    var dummy: u8 = 0;
    return chatStream(allocator, cfg, messages, tools_json, null, @ptrCast(&dummy));
}