const std = @import("std");

pub const Config = struct {
    provider: []const u8,
    model: []const u8,
    // api keys per provider name
    openai_key: ?[]const u8,
    anthropic_key: ?[]const u8,
    google_key: ?[]const u8,
    kilo_key: ?[]const u8,
    base_url_override: ?[]const u8, // for kilo/custom
};

pub fn defaultConfig() Config {
    return .{
        .provider = "openai",
        .model = "gpt-4o-mini",
        .openai_key = null,
        .anthropic_key = null,
        .google_key = null,
        .kilo_key = null,
        .base_url_override = null,
    };
}

fn envOr(cfg_val: ?[]const u8, env_name: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    if (cfg_val) |v| if (v.len > 0) return v;
    const e = std.process.getEnvVarOwned(allocator, env_name) catch return null;
    if (e.len == 0) {
        allocator.free(e);
        return null;
    }
    return e;
}

fn readJsonFile(allocator: std.mem.Allocator, path: []const u8) ?std.json.Value {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const data = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    // leak parsed arena intentionally? We'll duplicate needed strings. Free parsed later impossible; accept leak for v1.
    return parsed.value;
}

fn applyJson(cfg: *Config, v: std.json.Value, allocator: std.mem.Allocator) void {
    if (v != .object) return;
    const o = v.object;
    if (o.get("provider")) |p| {
        if (p == .string) {
            const d = allocator.dupe(u8, p.string) catch return;
            cfg.provider = d;
        }
    }
    if (o.get("model")) |m| {
        if (m == .string) {
            const d = allocator.dupe(u8, m.string) catch return;
            cfg.model = d;
        }
    }
    if (o.get("api_keys")) |ak| {
        if (ak == .object) {
            if (ak.object.get("openai")) |x| if (x == .string) {
                const d = allocator.dupe(u8, x.string) catch return;
                cfg.openai_key = d;
            };
            if (ak.object.get("anthropic")) |x| if (x == .string) {
                const d = allocator.dupe(u8, x.string) catch return;
                cfg.anthropic_key = d;
            };
            if (ak.object.get("google")) |x| if (x == .string) {
                const d = allocator.dupe(u8, x.string) catch return;
                cfg.google_key = d;
            };
            if (ak.object.get("kilo")) |x| if (x == .string) {
                const d = allocator.dupe(u8, x.string) catch return;
                cfg.kilo_key = d;
            };
        }
    }
    if (o.get("base_url")) |b| {
        if (b == .string) {
            const d = allocator.dupe(u8, b.string) catch return;
            cfg.base_url_override = d;
        }
    }
}

pub fn load(allocator: std.mem.Allocator, cwd: []const u8) Config {
    var cfg = defaultConfig();
    // global
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch "/tmp";
    defer if (home.len > 0) allocator.free(home);
    // build paths
    var buf: [1024]u8 = undefined;
    // global config
    {
        const p = std.fmt.bufPrint(&buf, "{s}/.config/hello/config.json", .{home}) catch null;
        if (p) |path| {
            if (readJsonFile(allocator, path)) |v| applyJson(&cfg, v, allocator);
        }
    }
    // project config
    {
        const p = std.fmt.bufPrint(&buf, "{s}/.hello/config.json", .{cwd}) catch null;
        if (p) |path| {
            if (readJsonFile(allocator, path)) |v| applyJson(&cfg, v, allocator);
        }
    }
    // env overrides for keys
    cfg.openai_key = envOr(cfg.openai_key, "OPENAI_API_KEY", allocator);
    cfg.anthropic_key = envOr(cfg.anthropic_key, "ANTHROPIC_API_KEY", allocator);
    cfg.google_key = envOr(cfg.google_key, "GOOGLE_API_KEY", allocator);
    cfg.kilo_key = envOr(cfg.kilo_key, "KILO_API_KEY", allocator);
    return cfg;
}

pub fn configDir(allocator: std.mem.Allocator, global: bool, cwd: []const u8) ![]u8 {
    if (global) {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}/.config/hello", .{home});
    }
    return std.fmt.allocPrint(allocator, "{s}/.hello", .{cwd});
}
