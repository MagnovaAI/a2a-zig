//! Agent self-description manifest.
const std = @import("std");
const types = @import("types.zig");
const errors_mod = @import("errors.zig");

const TRANSPORT_PROTOCOL_GRPC = types.TRANSPORT_PROTOCOL_GRPC;
pub const VERSION = "1.0";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn freeStrSlice(allocator: std.mem.Allocator, slice: []const []const u8) void {
    for (slice) |s| allocator.free(s);
    allocator.free(slice);
}

fn parseStrSlice(allocator: std.mem.Allocator, v: std.json.Value) ![]const []const u8 {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.UnexpectedToken,
    };
    const out = try allocator.alloc([]const u8, arr.items.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |s| allocator.free(s);
        allocator.free(out);
    }
    while (i < arr.items.len) : (i += 1) {
        out[i] = switch (arr.items[i]) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        };
    }
    return out;
}

fn writeStrArray(jw: anytype, items: []const []const u8) !void {
    try jw.beginArray();
    for (items) |s| try jw.write(s);
    try jw.endArray();
}

/// Map of string → string (used for OAuth `scopes`).
pub const StringMap = struct {
    entries: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *StringMap) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: StringMap, jw: anytype) !void {
        try jw.beginObject();
        var it = self.entries.iterator();
        while (it.next()) |e| {
            try jw.objectField(e.key_ptr.*);
            try jw.write(e.value_ptr.*);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !StringMap {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var out: StringMap = .{ .allocator = allocator };
        errdefer out.deinit();
        var it = obj.iterator();
        while (it.next()) |e| {
            const v = switch (e.value_ptr.*) {
                .string => |s| s,
                else => return error.UnexpectedToken,
            };
            const k = try allocator.dupe(u8, e.key_ptr.*);
            errdefer allocator.free(k);
            const val = try allocator.dupe(u8, v);
            errdefer allocator.free(val);
            try out.entries.put(allocator, k, val);
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// AgentProvider
// ---------------------------------------------------------------------------

pub const AgentProvider = struct {
    organization: []const u8,
    url: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AgentProvider) void {
        self.allocator.free(self.organization);
        self.allocator.free(self.url);
        self.* = undefined;
    }

    pub fn jsonStringify(self: AgentProvider, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("organization");
        try jw.write(self.organization);
        try jw.objectField("url");
        try jw.write(self.url);
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !AgentProvider {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var p: AgentProvider = .{ .organization = "", .url = "", .allocator = allocator };
        errdefer p.deinit();
        if (obj.get("organization")) |v| switch (v) {
            .string => |s| p.organization = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("url")) |v| switch (v) {
            .string => |s| p.url = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        return p;
    }
};

// ---------------------------------------------------------------------------
// AgentInterface (URL is gRPC-normalized on serialize)
// ---------------------------------------------------------------------------

fn normalizeAgentInterfaceUrl(allocator: std.mem.Allocator, url: []const u8, binding: []const u8) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(binding, TRANSPORT_PROTOCOL_GRPC)) {
        const prefix = "http://";
        if (url.len >= prefix.len and std.ascii.eqlIgnoreCase(url[0..prefix.len], prefix)) {
            return allocator.dupe(u8, url[prefix.len..]);
        }
    }
    return allocator.dupe(u8, url);
}

pub const AgentInterface = struct {
    url: []const u8,
    protocol_binding: []const u8,
    protocol_version: []const u8,
    tenant: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        url: []const u8,
        protocol_binding: []const u8,
    ) !AgentInterface {
        const norm = try normalizeAgentInterfaceUrl(allocator, url, protocol_binding);
        errdefer allocator.free(norm);
        const binding = try allocator.dupe(u8, protocol_binding);
        errdefer allocator.free(binding);
        const ver = try allocator.dupe(u8, VERSION);
        return .{
            .url = norm,
            .protocol_binding = binding,
            .protocol_version = ver,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AgentInterface) void {
        self.allocator.free(self.url);
        self.allocator.free(self.protocol_binding);
        self.allocator.free(self.protocol_version);
        if (self.tenant) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: AgentInterface, jw: anytype) !void {
        try jw.beginObject();
        // Apply gRPC normalization on the wire form too — matches `init`.
        try jw.objectField("url");
        if (std.ascii.eqlIgnoreCase(self.protocol_binding, TRANSPORT_PROTOCOL_GRPC)) {
            const prefix = "http://";
            if (self.url.len >= prefix.len and std.ascii.eqlIgnoreCase(self.url[0..prefix.len], prefix)) {
                try jw.write(self.url[prefix.len..]);
            } else {
                try jw.write(self.url);
            }
        } else {
            try jw.write(self.url);
        }
        try jw.objectField("protocolBinding");
        try jw.write(self.protocol_binding);
        try jw.objectField("protocolVersion");
        try jw.write(self.protocol_version);
        if (self.tenant) |t| {
            try jw.objectField("tenant");
            try jw.write(t);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !AgentInterface {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var iface: AgentInterface = .{
            .url = "",
            .protocol_binding = "",
            .protocol_version = "",
            .allocator = allocator,
        };
        errdefer iface.deinit();
        const url_raw = switch (obj.get("url") orelse return error.MissingField) {
            .string => |s| s,
            else => return error.UnexpectedToken,
        };
        const binding_raw = switch (obj.get("protocolBinding") orelse return error.MissingField) {
            .string => |s| s,
            else => return error.UnexpectedToken,
        };
        const ver_raw = switch (obj.get("protocolVersion") orelse return error.MissingField) {
            .string => |s| s,
            else => return error.UnexpectedToken,
        };

        iface.url = try normalizeAgentInterfaceUrl(allocator, url_raw, binding_raw);
        iface.protocol_binding = try allocator.dupe(u8, binding_raw);
        iface.protocol_version = try allocator.dupe(u8, ver_raw);

        if (obj.get("tenant")) |v| switch (v) {
            .string => |s| iface.tenant = try allocator.dupe(u8, s),
            .null => {},
            else => return error.UnexpectedToken,
        };
        return iface;
    }
};

// ---------------------------------------------------------------------------
// AgentExtension
// ---------------------------------------------------------------------------

pub const AgentExtension = struct {
    uri: []const u8,
    description: ?[]const u8 = null,
    required: ?bool = null,
    params: ?types.Metadata = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AgentExtension) void {
        self.allocator.free(self.uri);
        if (self.description) |s| self.allocator.free(s);
        if (self.params) |*m| m.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: AgentExtension, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("uri");
        try jw.write(self.uri);
        if (self.description) |s| {
            try jw.objectField("description");
            try jw.write(s);
        }
        if (self.required) |b| {
            try jw.objectField("required");
            try jw.write(b);
        }
        if (self.params) |m| {
            try jw.objectField("params");
            try jw.write(std.json.Value{ .object = m.object });
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !AgentExtension {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var ext: AgentExtension = .{ .uri = "", .allocator = allocator };
        errdefer ext.deinit();
        if (obj.get("uri")) |v| switch (v) {
            .string => |s| ext.uri = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("description")) |v| switch (v) {
            .string => |s| ext.description = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("required")) |v| switch (v) {
            .bool => |b| ext.required = b,
            else => {},
        };
        if (obj.get("params")) |v| switch (v) {
            .object => |o| ext.params = try types.Metadata.clone(allocator, o),
            else => {},
        };
        return ext;
    }
};

// ---------------------------------------------------------------------------
// AgentCapabilities
// ---------------------------------------------------------------------------

pub const AgentCapabilities = struct {
    streaming: ?bool = null,
    push_notifications: ?bool = null,
    extensions: ?[]AgentExtension = null,
    extended_agent_card: ?bool = null,
    allocator: std.mem.Allocator,

    pub fn default(allocator: std.mem.Allocator) AgentCapabilities {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AgentCapabilities) void {
        if (self.extensions) |arr| {
            for (arr) |*e| e.deinit();
            self.allocator.free(arr);
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: AgentCapabilities, jw: anytype) !void {
        try jw.beginObject();
        if (self.streaming) |b| {
            try jw.objectField("streaming");
            try jw.write(b);
        }
        if (self.push_notifications) |b| {
            try jw.objectField("pushNotifications");
            try jw.write(b);
        }
        if (self.extensions) |arr| {
            try jw.objectField("extensions");
            try jw.beginArray();
            for (arr) |e| try jw.write(e);
            try jw.endArray();
        }
        if (self.extended_agent_card) |b| {
            try jw.objectField("extendedAgentCard");
            try jw.write(b);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !AgentCapabilities {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var caps: AgentCapabilities = .{ .allocator = allocator };
        errdefer caps.deinit();
        if (obj.get("streaming")) |v| switch (v) {
            .bool => |b| caps.streaming = b,
            else => {},
        };
        if (obj.get("pushNotifications")) |v| switch (v) {
            .bool => |b| caps.push_notifications = b,
            else => {},
        };
        if (obj.get("extensions")) |v| switch (v) {
            .array => |arr| {
                const out = try allocator.alloc(AgentExtension, arr.items.len);
                var i: usize = 0;
                errdefer {
                    for (out[0..i]) |*e| e.deinit();
                    allocator.free(out);
                }
                while (i < arr.items.len) : (i += 1) {
                    out[i] = try AgentExtension.jsonParseFromValue(allocator, arr.items[i], opts);
                }
                caps.extensions = out;
            },
            else => {},
        };
        if (obj.get("extendedAgentCard")) |v| switch (v) {
            .bool => |b| caps.extended_agent_card = b,
            else => {},
        };
        return caps;
    }
};

// ---------------------------------------------------------------------------
// SecurityRequirement: scheme name → required scopes
// ---------------------------------------------------------------------------

pub const SecurityRequirement = struct {
    entries: std.StringArrayHashMapUnmanaged([]const []const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SecurityRequirement) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            freeStrSlice(self.allocator, e.value_ptr.*);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: SecurityRequirement, jw: anytype) !void {
        try jw.beginObject();
        var it = self.entries.iterator();
        while (it.next()) |e| {
            try jw.objectField(e.key_ptr.*);
            try writeStrArray(jw, e.value_ptr.*);
        }
        try jw.endObject();
    }

    /// Accepts three legacy wire shapes for backwards compatibility:
    ///   1. `{"scheme": ["scope1", ...], ...}`
    ///   2. `{"schemes": {"scheme": [...], ...}}`
    ///   3. `{"schemes": {"scheme": {"list": [...]}, ...}}`
    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !SecurityRequirement {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };

        // Shape 1: try direct {scheme: [scopes]} first. We detect it as
        // "every value is an array" — anything else falls through to schemes.
        if (looksLikeFlat(obj)) {
            return parseFlatMap(allocator, obj);
        }

        // Shape 2/3: `schemes` wrapper.
        if (obj.get("schemes")) |inner| switch (inner) {
            .object => |inner_obj| return parseSchemesMap(allocator, inner_obj),
            else => return error.UnexpectedToken,
        };

        return error.UnexpectedToken;
    }

    fn looksLikeFlat(obj: std.json.ObjectMap) bool {
        if (obj.count() == 0) return true;
        var it = obj.iterator();
        while (it.next()) |e| {
            switch (e.value_ptr.*) {
                .array => {},
                else => return false,
            }
        }
        return true;
    }

    fn parseFlatMap(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !SecurityRequirement {
        var req: SecurityRequirement = .{ .allocator = allocator };
        errdefer req.deinit();
        var it = obj.iterator();
        while (it.next()) |e| {
            const scopes = try parseStrSlice(allocator, e.value_ptr.*);
            errdefer freeStrSlice(allocator, scopes);
            const k = try allocator.dupe(u8, e.key_ptr.*);
            errdefer allocator.free(k);
            try req.entries.put(allocator, k, scopes);
        }
        return req;
    }

    fn parseSchemesMap(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !SecurityRequirement {
        var req: SecurityRequirement = .{ .allocator = allocator };
        errdefer req.deinit();
        var it = obj.iterator();
        while (it.next()) |e| {
            const scopes = switch (e.value_ptr.*) {
                .array => try parseStrSlice(allocator, e.value_ptr.*),
                .object => |inner| blk: {
                    const list_v = inner.get("list") orelse return error.UnexpectedToken;
                    break :blk try parseStrSlice(allocator, list_v);
                },
                else => return error.UnexpectedToken,
            };
            errdefer freeStrSlice(allocator, scopes);
            const k = try allocator.dupe(u8, e.key_ptr.*);
            errdefer allocator.free(k);
            try req.entries.put(allocator, k, scopes);
        }
        return req;
    }
};

fn parseSecurityRequirements(
    allocator: std.mem.Allocator,
    v: std.json.Value,
    opts: std.json.ParseOptions,
) ![]SecurityRequirement {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.UnexpectedToken,
    };
    const out = try allocator.alloc(SecurityRequirement, arr.items.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |*r| r.deinit();
        allocator.free(out);
    }
    while (i < arr.items.len) : (i += 1) {
        out[i] = try SecurityRequirement.jsonParseFromValue(allocator, arr.items[i], opts);
    }
    return out;
}

fn writeSecurityRequirements(jw: anytype, items: []const SecurityRequirement) !void {
    try jw.beginArray();
    for (items) |r| try jw.write(r);
    try jw.endArray();
}

// ---------------------------------------------------------------------------
// AgentSkill
// ---------------------------------------------------------------------------

pub const AgentSkill = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    tags: []const []const u8 = &.{},
    examples: ?[]const []const u8 = null,
    input_modes: ?[]const []const u8 = null,
    output_modes: ?[]const []const u8 = null,
    security_requirements: ?[]SecurityRequirement = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AgentSkill) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        freeStrSlice(self.allocator, self.tags);
        if (self.examples) |s| freeStrSlice(self.allocator, s);
        if (self.input_modes) |s| freeStrSlice(self.allocator, s);
        if (self.output_modes) |s| freeStrSlice(self.allocator, s);
        if (self.security_requirements) |arr| {
            for (arr) |*r| r.deinit();
            self.allocator.free(arr);
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: AgentSkill, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("description");
        try jw.write(self.description);
        try jw.objectField("tags");
        try writeStrArray(jw, self.tags);
        if (self.examples) |arr| {
            try jw.objectField("examples");
            try writeStrArray(jw, arr);
        }
        if (self.input_modes) |arr| {
            try jw.objectField("inputModes");
            try writeStrArray(jw, arr);
        }
        if (self.output_modes) |arr| {
            try jw.objectField("outputModes");
            try writeStrArray(jw, arr);
        }
        if (self.security_requirements) |arr| {
            try jw.objectField("securityRequirements");
            try writeSecurityRequirements(jw, arr);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !AgentSkill {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var s: AgentSkill = .{
            .id = "",
            .name = "",
            .description = "",
            .allocator = allocator,
        };
        errdefer s.deinit();

        if (obj.get("id")) |v| switch (v) {
            .string => |x| s.id = try allocator.dupe(u8, x),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("name")) |v| switch (v) {
            .string => |x| s.name = try allocator.dupe(u8, x),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("description")) |v| switch (v) {
            .string => |x| s.description = try allocator.dupe(u8, x),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("tags")) |v| switch (v) {
            .array => s.tags = try parseStrSlice(allocator, v),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("examples")) |v| switch (v) {
            .array => s.examples = try parseStrSlice(allocator, v),
            .null => {},
            else => return error.UnexpectedToken,
        };
        if (obj.get("inputModes")) |v| switch (v) {
            .array => s.input_modes = try parseStrSlice(allocator, v),
            .null => {},
            else => return error.UnexpectedToken,
        };
        if (obj.get("outputModes")) |v| switch (v) {
            .array => s.output_modes = try parseStrSlice(allocator, v),
            .null => {},
            else => return error.UnexpectedToken,
        };
        if (obj.get("securityRequirements")) |v| switch (v) {
            .array => s.security_requirements = try parseSecurityRequirements(allocator, v, opts),
            .null => {},
            else => return error.UnexpectedToken,
        };
        return s;
    }
};

// ---------------------------------------------------------------------------
// Security schemes
// ---------------------------------------------------------------------------

pub const ApiKeySecurityScheme = struct {
    location: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ApiKeySecurityScheme) void {
        self.allocator.free(self.location);
        self.allocator.free(self.name);
        if (self.description) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: ApiKeySecurityScheme, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("location");
        try jw.write(self.location);
        try jw.objectField("name");
        try jw.write(self.name);
        if (self.description) |s| {
            try jw.objectField("description");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !ApiKeySecurityScheme {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var s: ApiKeySecurityScheme = .{ .location = "", .name = "", .allocator = allocator };
        errdefer s.deinit();
        if (obj.get("location")) |v| switch (v) {
            .string => |x| s.location = try allocator.dupe(u8, x),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("name")) |v| switch (v) {
            .string => |x| s.name = try allocator.dupe(u8, x),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("description")) |v| switch (v) {
            .string => |x| s.description = try allocator.dupe(u8, x),
            else => {},
        };
        return s;
    }
};

pub const HttpAuthSecurityScheme = struct {
    scheme: []const u8,
    description: ?[]const u8 = null,
    bearer_format: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HttpAuthSecurityScheme) void {
        self.allocator.free(self.scheme);
        if (self.description) |s| self.allocator.free(s);
        if (self.bearer_format) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: HttpAuthSecurityScheme, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("scheme");
        try jw.write(self.scheme);
        if (self.description) |s| {
            try jw.objectField("description");
            try jw.write(s);
        }
        if (self.bearer_format) |s| {
            try jw.objectField("bearerFormat");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !HttpAuthSecurityScheme {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var s: HttpAuthSecurityScheme = .{ .scheme = "", .allocator = allocator };
        errdefer s.deinit();
        if (obj.get("scheme")) |v| switch (v) {
            .string => |x| s.scheme = try allocator.dupe(u8, x),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("description")) |v| switch (v) {
            .string => |x| s.description = try allocator.dupe(u8, x),
            else => {},
        };
        if (obj.get("bearerFormat")) |v| switch (v) {
            .string => |x| s.bearer_format = try allocator.dupe(u8, x),
            else => {},
        };
        return s;
    }
};

pub const OpenIdConnectSecurityScheme = struct {
    open_id_connect_url: []const u8,
    description: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OpenIdConnectSecurityScheme) void {
        self.allocator.free(self.open_id_connect_url);
        if (self.description) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: OpenIdConnectSecurityScheme, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("openIdConnectUrl");
        try jw.write(self.open_id_connect_url);
        if (self.description) |s| {
            try jw.objectField("description");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !OpenIdConnectSecurityScheme {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var s: OpenIdConnectSecurityScheme = .{ .open_id_connect_url = "", .allocator = allocator };
        errdefer s.deinit();
        if (obj.get("openIdConnectUrl")) |v| switch (v) {
            .string => |x| s.open_id_connect_url = try allocator.dupe(u8, x),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("description")) |v| switch (v) {
            .string => |x| s.description = try allocator.dupe(u8, x),
            else => {},
        };
        return s;
    }
};

pub const MutualTlsSecurityScheme = struct {
    description: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MutualTlsSecurityScheme) void {
        if (self.description) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: MutualTlsSecurityScheme, jw: anytype) !void {
        try jw.beginObject();
        if (self.description) |s| {
            try jw.objectField("description");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !MutualTlsSecurityScheme {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var s: MutualTlsSecurityScheme = .{ .allocator = allocator };
        errdefer s.deinit();
        if (obj.get("description")) |v| switch (v) {
            .string => |x| s.description = try allocator.dupe(u8, x),
            else => {},
        };
        return s;
    }
};

// ---------------------------------------------------------------------------
// OAuth flow types
// ---------------------------------------------------------------------------

pub const AuthorizationCodeOAuthFlow = struct {
    authorization_url: []const u8,
    token_url: []const u8,
    scopes: StringMap,
    refresh_url: ?[]const u8 = null,
    pkce_required: ?bool = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AuthorizationCodeOAuthFlow) void {
        self.allocator.free(self.authorization_url);
        self.allocator.free(self.token_url);
        self.scopes.deinit();
        if (self.refresh_url) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: AuthorizationCodeOAuthFlow, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("authorizationUrl");
        try jw.write(self.authorization_url);
        try jw.objectField("tokenUrl");
        try jw.write(self.token_url);
        try jw.objectField("scopes");
        try jw.write(self.scopes);
        if (self.refresh_url) |s| {
            try jw.objectField("refreshUrl");
            try jw.write(s);
        }
        if (self.pkce_required) |b| {
            try jw.objectField("pkceRequired");
            try jw.write(b);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !AuthorizationCodeOAuthFlow {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var f: AuthorizationCodeOAuthFlow = .{
            .authorization_url = "",
            .token_url = "",
            .scopes = .{ .allocator = allocator },
            .allocator = allocator,
        };
        errdefer f.deinit();
        if (obj.get("authorizationUrl")) |v| switch (v) {
            .string => |s| f.authorization_url = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("tokenUrl")) |v| switch (v) {
            .string => |s| f.token_url = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("scopes")) |v| {
            f.scopes.deinit();
            f.scopes = try StringMap.jsonParseFromValue(allocator, v, opts);
        } else return error.MissingField;
        if (obj.get("refreshUrl")) |v| switch (v) {
            .string => |s| f.refresh_url = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("pkceRequired")) |v| switch (v) {
            .bool => |b| f.pkce_required = b,
            else => {},
        };
        return f;
    }
};

pub const ClientCredentialsOAuthFlow = struct {
    token_url: []const u8,
    scopes: StringMap,
    refresh_url: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ClientCredentialsOAuthFlow) void {
        self.allocator.free(self.token_url);
        self.scopes.deinit();
        if (self.refresh_url) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: ClientCredentialsOAuthFlow, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("tokenUrl");
        try jw.write(self.token_url);
        try jw.objectField("scopes");
        try jw.write(self.scopes);
        if (self.refresh_url) |s| {
            try jw.objectField("refreshUrl");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !ClientCredentialsOAuthFlow {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var f: ClientCredentialsOAuthFlow = .{
            .token_url = "",
            .scopes = .{ .allocator = allocator },
            .allocator = allocator,
        };
        errdefer f.deinit();
        if (obj.get("tokenUrl")) |v| switch (v) {
            .string => |s| f.token_url = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("scopes")) |v| {
            f.scopes.deinit();
            f.scopes = try StringMap.jsonParseFromValue(allocator, v, opts);
        } else return error.MissingField;
        if (obj.get("refreshUrl")) |v| switch (v) {
            .string => |s| f.refresh_url = try allocator.dupe(u8, s),
            else => {},
        };
        return f;
    }
};

pub const DeviceCodeOAuthFlow = struct {
    device_authorization_url: []const u8,
    token_url: []const u8,
    scopes: StringMap,
    refresh_url: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DeviceCodeOAuthFlow) void {
        self.allocator.free(self.device_authorization_url);
        self.allocator.free(self.token_url);
        self.scopes.deinit();
        if (self.refresh_url) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: DeviceCodeOAuthFlow, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("deviceAuthorizationUrl");
        try jw.write(self.device_authorization_url);
        try jw.objectField("tokenUrl");
        try jw.write(self.token_url);
        try jw.objectField("scopes");
        try jw.write(self.scopes);
        if (self.refresh_url) |s| {
            try jw.objectField("refreshUrl");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !DeviceCodeOAuthFlow {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var f: DeviceCodeOAuthFlow = .{
            .device_authorization_url = "",
            .token_url = "",
            .scopes = .{ .allocator = allocator },
            .allocator = allocator,
        };
        errdefer f.deinit();
        if (obj.get("deviceAuthorizationUrl")) |v| switch (v) {
            .string => |s| f.device_authorization_url = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("tokenUrl")) |v| switch (v) {
            .string => |s| f.token_url = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("scopes")) |v| {
            f.scopes.deinit();
            f.scopes = try StringMap.jsonParseFromValue(allocator, v, opts);
        } else return error.MissingField;
        if (obj.get("refreshUrl")) |v| switch (v) {
            .string => |s| f.refresh_url = try allocator.dupe(u8, s),
            else => {},
        };
        return f;
    }
};

pub const ImplicitOAuthFlow = struct {
    authorization_url: []const u8,
    scopes: StringMap,
    refresh_url: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ImplicitOAuthFlow) void {
        self.allocator.free(self.authorization_url);
        self.scopes.deinit();
        if (self.refresh_url) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: ImplicitOAuthFlow, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("authorizationUrl");
        try jw.write(self.authorization_url);
        try jw.objectField("scopes");
        try jw.write(self.scopes);
        if (self.refresh_url) |s| {
            try jw.objectField("refreshUrl");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !ImplicitOAuthFlow {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var f: ImplicitOAuthFlow = .{
            .authorization_url = "",
            .scopes = .{ .allocator = allocator },
            .allocator = allocator,
        };
        errdefer f.deinit();
        if (obj.get("authorizationUrl")) |v| switch (v) {
            .string => |s| f.authorization_url = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("scopes")) |v| {
            f.scopes.deinit();
            f.scopes = try StringMap.jsonParseFromValue(allocator, v, opts);
        } else return error.MissingField;
        if (obj.get("refreshUrl")) |v| switch (v) {
            .string => |s| f.refresh_url = try allocator.dupe(u8, s),
            else => {},
        };
        return f;
    }
};

pub const PasswordOAuthFlow = struct {
    token_url: []const u8,
    scopes: StringMap,
    refresh_url: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PasswordOAuthFlow) void {
        self.allocator.free(self.token_url);
        self.scopes.deinit();
        if (self.refresh_url) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: PasswordOAuthFlow, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("tokenUrl");
        try jw.write(self.token_url);
        try jw.objectField("scopes");
        try jw.write(self.scopes);
        if (self.refresh_url) |s| {
            try jw.objectField("refreshUrl");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !PasswordOAuthFlow {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var f: PasswordOAuthFlow = .{
            .token_url = "",
            .scopes = .{ .allocator = allocator },
            .allocator = allocator,
        };
        errdefer f.deinit();
        if (obj.get("tokenUrl")) |v| switch (v) {
            .string => |s| f.token_url = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("scopes")) |v| {
            f.scopes.deinit();
            f.scopes = try StringMap.jsonParseFromValue(allocator, v, opts);
        } else return error.MissingField;
        if (obj.get("refreshUrl")) |v| switch (v) {
            .string => |s| f.refresh_url = try allocator.dupe(u8, s),
            else => {},
        };
        return f;
    }
};

// ---------------------------------------------------------------------------
// OAuthFlows union
// ---------------------------------------------------------------------------

pub const OAuthFlowsTag = enum { authorization_code, client_credentials, device_code, implicit, password, unknown };

pub const OAuthFlows = union(OAuthFlowsTag) {
    authorization_code: AuthorizationCodeOAuthFlow,
    client_credentials: ClientCredentialsOAuthFlow,
    device_code: DeviceCodeOAuthFlow,
    implicit: ImplicitOAuthFlow,
    password: PasswordOAuthFlow,
    /// Forward-compat fallback for variants the local build doesn't recognize.
    unknown: types.UnknownVariant,

    pub fn deinit(self: *OAuthFlows) void {
        switch (self.*) {
            inline else => |*f| f.deinit(),
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: OAuthFlows, jw: anytype) !void {
        switch (self) {
            .unknown => |u| try jw.write(u),
            else => {
                try jw.beginObject();
                switch (self) {
                    .authorization_code => |f| {
                        try jw.objectField("authorizationCode");
                        try jw.write(f);
                    },
                    .client_credentials => |f| {
                        try jw.objectField("clientCredentials");
                        try jw.write(f);
                    },
                    .device_code => |f| {
                        try jw.objectField("deviceCode");
                        try jw.write(f);
                    },
                    .implicit => |f| {
                        try jw.objectField("implicit");
                        try jw.write(f);
                    },
                    .password => |f| {
                        try jw.objectField("password");
                        try jw.write(f);
                    },
                    .unknown => unreachable,
                }
                try jw.endObject();
            },
        }
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !OAuthFlows {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        if (obj.get("authorizationCode")) |v| {
            return .{ .authorization_code = try AuthorizationCodeOAuthFlow.jsonParseFromValue(allocator, v, opts) };
        }
        if (obj.get("clientCredentials")) |v| {
            return .{ .client_credentials = try ClientCredentialsOAuthFlow.jsonParseFromValue(allocator, v, opts) };
        }
        if (obj.get("deviceCode")) |v| {
            return .{ .device_code = try DeviceCodeOAuthFlow.jsonParseFromValue(allocator, v, opts) };
        }
        if (obj.get("implicit")) |v| {
            return .{ .implicit = try ImplicitOAuthFlow.jsonParseFromValue(allocator, v, opts) };
        }
        if (obj.get("password")) |v| {
            return .{ .password = try PasswordOAuthFlow.jsonParseFromValue(allocator, v, opts) };
        }
        var it = obj.iterator();
        if (it.next()) |entry| {
            return .{ .unknown = try types.UnknownVariant.init(allocator, entry.key_ptr.*, entry.value_ptr.*) };
        }
        return error.UnexpectedToken;
    }
};

// ---------------------------------------------------------------------------
// OAuth2SecurityScheme
// ---------------------------------------------------------------------------

pub const OAuth2SecurityScheme = struct {
    flows: OAuthFlows,
    description: ?[]const u8 = null,
    oauth2_metadata_url: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OAuth2SecurityScheme) void {
        self.flows.deinit();
        if (self.description) |s| self.allocator.free(s);
        if (self.oauth2_metadata_url) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: OAuth2SecurityScheme, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("flows");
        try jw.write(self.flows);
        if (self.description) |s| {
            try jw.objectField("description");
            try jw.write(s);
        }
        if (self.oauth2_metadata_url) |s| {
            try jw.objectField("oauth2MetadataUrl");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !OAuth2SecurityScheme {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        const flows_v = obj.get("flows") orelse return error.MissingField;
        var flows = try OAuthFlows.jsonParseFromValue(allocator, flows_v, opts);
        errdefer flows.deinit();
        var s: OAuth2SecurityScheme = .{ .flows = flows, .allocator = allocator };
        errdefer s.deinit();
        if (obj.get("description")) |v| switch (v) {
            .string => |x| s.description = try allocator.dupe(u8, x),
            else => {},
        };
        if (obj.get("oauth2MetadataUrl")) |v| switch (v) {
            .string => |x| s.oauth2_metadata_url = try allocator.dupe(u8, x),
            else => {},
        };
        return s;
    }
};

// ---------------------------------------------------------------------------
// SecurityScheme union
// ---------------------------------------------------------------------------

pub const SecuritySchemeTag = enum { api_key, http_auth, oauth2, openid_connect, mtls, unknown };

pub const SecurityScheme = union(SecuritySchemeTag) {
    api_key: ApiKeySecurityScheme,
    http_auth: HttpAuthSecurityScheme,
    oauth2: OAuth2SecurityScheme,
    openid_connect: OpenIdConnectSecurityScheme,
    mtls: MutualTlsSecurityScheme,
    /// Forward-compat fallback for variants the local build doesn't recognize.
    unknown: types.UnknownVariant,

    pub fn deinit(self: *SecurityScheme) void {
        switch (self.*) {
            inline else => |*s| s.deinit(),
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: SecurityScheme, jw: anytype) !void {
        switch (self) {
            .unknown => |u| try jw.write(u),
            else => {
                try jw.beginObject();
                switch (self) {
                    .api_key => |s| {
                        try jw.objectField("apiKeySecurityScheme");
                        try jw.write(s);
                    },
                    .http_auth => |s| {
                        try jw.objectField("httpAuthSecurityScheme");
                        try jw.write(s);
                    },
                    .oauth2 => |s| {
                        try jw.objectField("oauth2SecurityScheme");
                        try jw.write(s);
                    },
                    .openid_connect => |s| {
                        try jw.objectField("openIdConnectSecurityScheme");
                        try jw.write(s);
                    },
                    .mtls => |s| {
                        try jw.objectField("mtlsSecurityScheme");
                        try jw.write(s);
                    },
                    .unknown => unreachable,
                }
                try jw.endObject();
            },
        }
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !SecurityScheme {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        if (obj.get("apiKeySecurityScheme")) |v| {
            return .{ .api_key = try ApiKeySecurityScheme.jsonParseFromValue(allocator, v, opts) };
        }
        if (obj.get("httpAuthSecurityScheme")) |v| {
            return .{ .http_auth = try HttpAuthSecurityScheme.jsonParseFromValue(allocator, v, opts) };
        }
        if (obj.get("oauth2SecurityScheme")) |v| {
            return .{ .oauth2 = try OAuth2SecurityScheme.jsonParseFromValue(allocator, v, opts) };
        }
        if (obj.get("openIdConnectSecurityScheme")) |v| {
            return .{ .openid_connect = try OpenIdConnectSecurityScheme.jsonParseFromValue(allocator, v, opts) };
        }
        if (obj.get("mtlsSecurityScheme")) |v| {
            return .{ .mtls = try MutualTlsSecurityScheme.jsonParseFromValue(allocator, v, opts) };
        }
        var it = obj.iterator();
        if (it.next()) |entry| {
            return .{ .unknown = try types.UnknownVariant.init(allocator, entry.key_ptr.*, entry.value_ptr.*) };
        }
        return error.UnexpectedToken;
    }
};

// ---------------------------------------------------------------------------
// SecuritySchemes map
// ---------------------------------------------------------------------------

pub const SecuritySchemes = struct {
    entries: std.StringArrayHashMapUnmanaged(SecurityScheme) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SecuritySchemes) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: SecuritySchemes, jw: anytype) !void {
        try jw.beginObject();
        var it = self.entries.iterator();
        while (it.next()) |e| {
            try jw.objectField(e.key_ptr.*);
            try jw.write(e.value_ptr.*);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !SecuritySchemes {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var out: SecuritySchemes = .{ .allocator = allocator };
        errdefer out.deinit();
        var it = obj.iterator();
        while (it.next()) |e| {
            var scheme = try SecurityScheme.jsonParseFromValue(allocator, e.value_ptr.*, opts);
            errdefer scheme.deinit();
            const k = try allocator.dupe(u8, e.key_ptr.*);
            errdefer allocator.free(k);
            try out.entries.put(allocator, k, scheme);
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// AgentCardSignature
// ---------------------------------------------------------------------------

pub const AgentCardSignature = struct {
    protected: []const u8,
    signature: []const u8,
    header: ?types.Metadata = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AgentCardSignature) void {
        self.allocator.free(self.protected);
        self.allocator.free(self.signature);
        if (self.header) |*m| m.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: AgentCardSignature, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("protected");
        try jw.write(self.protected);
        try jw.objectField("signature");
        try jw.write(self.signature);
        if (self.header) |m| {
            try jw.objectField("header");
            try jw.write(std.json.Value{ .object = m.object });
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !AgentCardSignature {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var s: AgentCardSignature = .{ .protected = "", .signature = "", .allocator = allocator };
        errdefer s.deinit();
        if (obj.get("protected")) |v| switch (v) {
            .string => |x| s.protected = try allocator.dupe(u8, x),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("signature")) |v| switch (v) {
            .string => |x| s.signature = try allocator.dupe(u8, x),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("header")) |v| switch (v) {
            .object => |o| s.header = try types.Metadata.clone(allocator, o),
            else => {},
        };
        return s;
    }
};

// ---------------------------------------------------------------------------
// AgentCard
// ---------------------------------------------------------------------------

pub const AgentCard = struct {
    name: []const u8,
    description: []const u8,
    version: []const u8,
    supported_interfaces: []AgentInterface = &.{},
    capabilities: AgentCapabilities,
    default_input_modes: []const []const u8 = &.{},
    default_output_modes: []const []const u8 = &.{},
    skills: []AgentSkill = &.{},

    provider: ?AgentProvider = null,
    documentation_url: ?[]const u8 = null,
    icon_url: ?[]const u8 = null,
    security_schemes: ?SecuritySchemes = null,
    security_requirements: ?[]SecurityRequirement = null,
    signatures: ?[]AgentCardSignature = null,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *AgentCard) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.free(self.version);
        for (self.supported_interfaces) |*i| i.deinit();
        self.allocator.free(self.supported_interfaces);
        self.capabilities.deinit();
        freeStrSlice(self.allocator, self.default_input_modes);
        freeStrSlice(self.allocator, self.default_output_modes);
        for (self.skills) |*s| s.deinit();
        self.allocator.free(self.skills);
        if (self.provider) |*p| p.deinit();
        if (self.documentation_url) |s| self.allocator.free(s);
        if (self.icon_url) |s| self.allocator.free(s);
        if (self.security_schemes) |*ss| ss.deinit();
        if (self.security_requirements) |arr| {
            for (arr) |*r| r.deinit();
            self.allocator.free(arr);
        }
        if (self.signatures) |arr| {
            for (arr) |*s| s.deinit();
            self.allocator.free(arr);
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: AgentCard, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("description");
        try jw.write(self.description);
        try jw.objectField("version");
        try jw.write(self.version);
        try jw.objectField("supportedInterfaces");
        try jw.beginArray();
        for (self.supported_interfaces) |i| try jw.write(i);
        try jw.endArray();
        try jw.objectField("capabilities");
        try jw.write(self.capabilities);
        try jw.objectField("defaultInputModes");
        try writeStrArray(jw, self.default_input_modes);
        try jw.objectField("defaultOutputModes");
        try writeStrArray(jw, self.default_output_modes);
        try jw.objectField("skills");
        try jw.beginArray();
        for (self.skills) |s| try jw.write(s);
        try jw.endArray();
        if (self.provider) |p| {
            try jw.objectField("provider");
            try jw.write(p);
        }
        if (self.documentation_url) |s| {
            try jw.objectField("documentationUrl");
            try jw.write(s);
        }
        if (self.icon_url) |s| {
            try jw.objectField("iconUrl");
            try jw.write(s);
        }
        if (self.security_schemes) |ss| {
            try jw.objectField("securitySchemes");
            try jw.write(ss);
        }
        if (self.security_requirements) |arr| {
            try jw.objectField("securityRequirements");
            try writeSecurityRequirements(jw, arr);
        }
        if (self.signatures) |arr| {
            try jw.objectField("signatures");
            try jw.beginArray();
            for (arr) |s| try jw.write(s);
            try jw.endArray();
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !AgentCard {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var card: AgentCard = .{
            .name = "",
            .description = "",
            .version = "",
            .capabilities = .{ .allocator = allocator },
            .allocator = allocator,
        };
        errdefer card.deinit();

        if (obj.get("name")) |v| switch (v) {
            .string => |s| card.name = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("description")) |v| switch (v) {
            .string => |s| card.description = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("version")) |v| switch (v) {
            .string => |s| card.version = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;

        if (obj.get("supportedInterfaces")) |v| switch (v) {
            .array => |arr| {
                const out = try allocator.alloc(AgentInterface, arr.items.len);
                var i: usize = 0;
                errdefer {
                    for (out[0..i]) |*x| x.deinit();
                    allocator.free(out);
                }
                while (i < arr.items.len) : (i += 1) {
                    out[i] = try AgentInterface.jsonParseFromValue(allocator, arr.items[i], opts);
                }
                card.supported_interfaces = out;
            },
            else => return error.UnexpectedToken,
        } else return error.MissingField;

        if (obj.get("capabilities")) |v| {
            card.capabilities.deinit();
            card.capabilities = try AgentCapabilities.jsonParseFromValue(allocator, v, opts);
        }

        if (obj.get("defaultInputModes")) |v| switch (v) {
            .array => card.default_input_modes = try parseStrSlice(allocator, v),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("defaultOutputModes")) |v| switch (v) {
            .array => card.default_output_modes = try parseStrSlice(allocator, v),
            else => return error.UnexpectedToken,
        } else return error.MissingField;

        // skills: missing OR null both default to empty.
        if (obj.get("skills")) |v| switch (v) {
            .array => |arr| {
                const out = try allocator.alloc(AgentSkill, arr.items.len);
                var i: usize = 0;
                errdefer {
                    for (out[0..i]) |*s| s.deinit();
                    allocator.free(out);
                }
                while (i < arr.items.len) : (i += 1) {
                    out[i] = try AgentSkill.jsonParseFromValue(allocator, arr.items[i], opts);
                }
                card.skills = out;
            },
            .null => {},
            else => return error.UnexpectedToken,
        };

        if (obj.get("provider")) |v| switch (v) {
            .object => card.provider = try AgentProvider.jsonParseFromValue(allocator, v, opts),
            .null => {},
            else => {},
        };
        if (obj.get("documentationUrl")) |v| switch (v) {
            .string => |s| card.documentation_url = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("iconUrl")) |v| switch (v) {
            .string => |s| card.icon_url = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("securitySchemes")) |v| switch (v) {
            .object => card.security_schemes = try SecuritySchemes.jsonParseFromValue(allocator, v, opts),
            else => {},
        };
        if (obj.get("securityRequirements")) |v| switch (v) {
            .array => card.security_requirements = try parseSecurityRequirements(allocator, v, opts),
            .null => {},
            else => {},
        };
        if (obj.get("signatures")) |v| switch (v) {
            .array => |arr| {
                const out = try allocator.alloc(AgentCardSignature, arr.items.len);
                var i: usize = 0;
                errdefer {
                    for (out[0..i]) |*s| s.deinit();
                    allocator.free(out);
                }
                while (i < arr.items.len) : (i += 1) {
                    out[i] = try AgentCardSignature.jsonParseFromValue(allocator, arr.items[i], opts);
                }
                card.signatures = out;
            },
            .null => {},
            else => {},
        };
        return card;
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseValueOwned(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "agent_interface init basic" {
    const a = testing.allocator;
    var iface = try AgentInterface.init(a, "http://localhost:3000", "JSONRPC");
    defer iface.deinit();
    try testing.expectEqualStrings("http://localhost:3000", iface.url);
    try testing.expectEqualStrings("JSONRPC", iface.protocol_binding);
    try testing.expect(iface.protocol_version.len > 0);
}

test "agent_interface init normalizes grpc http" {
    const a = testing.allocator;
    var iface = try AgentInterface.init(a, "http://localhost:50051", TRANSPORT_PROTOCOL_GRPC);
    defer iface.deinit();
    try testing.expectEqualStrings("localhost:50051", iface.url);
    try testing.expectEqualStrings(TRANSPORT_PROTOCOL_GRPC, iface.protocol_binding);
}

test "agent_interface init preserves grpc https" {
    const a = testing.allocator;
    var iface = try AgentInterface.init(a, "https://localhost:50051", TRANSPORT_PROTOCOL_GRPC);
    defer iface.deinit();
    try testing.expectEqualStrings("https://localhost:50051", iface.url);
}

test "agent_interface normalizes grpc http with tenant" {
    const a = testing.allocator;
    var iface = AgentInterface{
        .url = try a.dupe(u8, "http://localhost:50051"),
        .protocol_binding = try a.dupe(u8, TRANSPORT_PROTOCOL_GRPC),
        .protocol_version = try a.dupe(u8, VERSION),
        .tenant = try a.dupe(u8, "tenant-a"),
        .allocator = a,
    };
    defer iface.deinit();

    const json = try std.json.Stringify.valueAlloc(a, iface, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"url\":\"localhost:50051\"") != null);

    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try AgentInterface.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expectEqualStrings("localhost:50051", back.url);
    try testing.expectEqualStrings(TRANSPORT_PROTOCOL_GRPC, back.protocol_binding);
    try testing.expectEqualStrings("tenant-a", back.tenant.?);
}

test "agent_capabilities default" {
    const a = testing.allocator;
    var caps = AgentCapabilities.default(a);
    defer caps.deinit();
    try testing.expect(caps.streaming == null);
    try testing.expect(caps.push_notifications == null);
    try testing.expect(caps.extensions == null);
    try testing.expect(caps.extended_agent_card == null);
}

test "security_scheme apikey roundtrip" {
    const a = testing.allocator;
    var ss = SecurityScheme{ .api_key = .{
        .location = try a.dupe(u8, "header"),
        .name = try a.dupe(u8, "X-API-Key"),
        .allocator = a,
    } };
    defer ss.deinit();
    const json = try std.json.Stringify.valueAlloc(a, ss, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "apiKeySecurityScheme") != null);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try SecurityScheme.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back == .api_key);
}

test "security_scheme httpauth roundtrip" {
    const a = testing.allocator;
    var ss = SecurityScheme{ .http_auth = .{
        .scheme = try a.dupe(u8, "Bearer"),
        .bearer_format = try a.dupe(u8, "JWT"),
        .allocator = a,
    } };
    defer ss.deinit();
    const json = try std.json.Stringify.valueAlloc(a, ss, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "httpAuthSecurityScheme") != null);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try SecurityScheme.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back == .http_auth);
}

test "security_scheme oauth2 with client credentials" {
    const a = testing.allocator;
    var scopes: StringMap = .{ .allocator = a };
    try scopes.entries.put(a, try a.dupe(u8, "read"), try a.dupe(u8, "Read access"));

    var ss = SecurityScheme{ .oauth2 = .{
        .flows = .{ .client_credentials = .{
            .token_url = try a.dupe(u8, "https://auth.example.com/token"),
            .scopes = scopes,
            .allocator = a,
        } },
        .allocator = a,
    } };
    defer ss.deinit();
    const json = try std.json.Stringify.valueAlloc(a, ss, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try SecurityScheme.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back == .oauth2);
    try testing.expect(back.oauth2.flows == .client_credentials);
}

test "security_scheme openidconnect roundtrip" {
    const a = testing.allocator;
    var ss = SecurityScheme{ .openid_connect = .{
        .open_id_connect_url = try a.dupe(u8, "https://example.com/.well-known/openid-configuration"),
        .allocator = a,
    } };
    defer ss.deinit();
    const json = try std.json.Stringify.valueAlloc(a, ss, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try SecurityScheme.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back == .openid_connect);
}

test "security_scheme mtls roundtrip" {
    const a = testing.allocator;
    var ss = SecurityScheme{ .mtls = .{
        .description = try a.dupe(u8, "mTLS auth"),
        .allocator = a,
    } };
    defer ss.deinit();
    const json = try std.json.Stringify.valueAlloc(a, ss, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try SecurityScheme.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back == .mtls);
}

test "security_scheme unknown variant captured for forward compat" {
    const a = testing.allocator;
    const parsed = try parseValueOwned(a, "{\"futureScheme\":{\"value\":true}}");
    defer parsed.deinit();
    var ss = try SecurityScheme.jsonParseFromValue(a, parsed.value, .{});
    defer ss.deinit();
    try testing.expect(ss == .unknown);
    try testing.expectEqualStrings("futureScheme", ss.unknown.key);

    // Round-trip preserves the unknown payload.
    const json = try std.json.Stringify.valueAlloc(a, ss, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "futureScheme") != null);
}

test "oauth_flows unknown variant captured for forward compat" {
    const a = testing.allocator;
    const parsed = try parseValueOwned(a, "{\"deviceFlow2\":{\"tokenUrl\":\"https://example.com/token\"}}");
    defer parsed.deinit();
    var fl = try OAuthFlows.jsonParseFromValue(a, parsed.value, .{});
    defer fl.deinit();
    try testing.expect(fl == .unknown);
    try testing.expectEqualStrings("deviceFlow2", fl.unknown.key);
}

test "oauth_flows authorization_code roundtrip" {
    const a = testing.allocator;
    var scopes: StringMap = .{ .allocator = a };
    try scopes.entries.put(a, try a.dupe(u8, "read"), try a.dupe(u8, "Read"));

    var flows = OAuthFlows{ .authorization_code = .{
        .authorization_url = try a.dupe(u8, "https://auth.example.com/authorize"),
        .token_url = try a.dupe(u8, "https://auth.example.com/token"),
        .scopes = scopes,
        .pkce_required = true,
        .allocator = a,
    } };
    defer flows.deinit();

    const json = try std.json.Stringify.valueAlloc(a, flows, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try OAuthFlows.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back == .authorization_code);
    try testing.expectEqual(@as(?bool, true), back.authorization_code.pkce_required);
}

test "agent_card minimal roundtrip" {
    const a = testing.allocator;
    const ifaces = try a.alloc(AgentInterface, 1);
    ifaces[0] = try AgentInterface.init(a, "http://localhost:3000", "JSONRPC");

    const input_modes = try a.alloc([]const u8, 1);
    input_modes[0] = try a.dupe(u8, "text/plain");
    const output_modes = try a.alloc([]const u8, 1);
    output_modes[0] = try a.dupe(u8, "text/plain");

    const tags = try a.alloc([]const u8, 1);
    tags[0] = try a.dupe(u8, "test");
    const examples = try a.alloc([]const u8, 1);
    examples[0] = try a.dupe(u8, "hello");

    const skills = try a.alloc(AgentSkill, 1);
    skills[0] = .{
        .id = try a.dupe(u8, "echo"),
        .name = try a.dupe(u8, "Echo"),
        .description = try a.dupe(u8, "Echoes input"),
        .tags = tags,
        .examples = examples,
        .allocator = a,
    };

    var card = AgentCard{
        .name = try a.dupe(u8, "Test Agent"),
        .description = try a.dupe(u8, "A test agent"),
        .version = try a.dupe(u8, "1.0.0"),
        .supported_interfaces = ifaces,
        .capabilities = .{ .streaming = true, .push_notifications = false, .allocator = a },
        .default_input_modes = input_modes,
        .default_output_modes = output_modes,
        .skills = skills,
        .provider = .{
            .organization = try a.dupe(u8, "Test Corp"),
            .url = try a.dupe(u8, "https://test.com"),
            .allocator = a,
        },
        .allocator = a,
    };
    defer card.deinit();

    const json = try std.json.Stringify.valueAlloc(a, card, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try AgentCard.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expectEqualStrings(card.name, back.name);
    try testing.expectEqual(@as(usize, 1), back.skills.len);
    try testing.expect(back.provider != null);
}

test "agent_card null skills decodes as empty" {
    const a = testing.allocator;
    const json =
        \\{"name":"Test","description":"d","version":"1.0.0",
        \\ "supportedInterfaces":[{"url":"http://localhost:3000","protocolBinding":"JSONRPC","protocolVersion":"1.0"}],
        \\ "capabilities":{"streaming":true},
        \\ "defaultInputModes":["text/plain"],"defaultOutputModes":["text/plain"],
        \\ "skills":null}
    ;
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var card = try AgentCard.jsonParseFromValue(a, parsed.value, .{});
    defer card.deinit();
    try testing.expectEqual(@as(usize, 0), card.skills.len);
}

test "agent_card missing skills decodes as empty" {
    const a = testing.allocator;
    const json =
        \\{"name":"Test","description":"d","version":"1.0.0",
        \\ "supportedInterfaces":[{"url":"http://localhost:3000","protocolBinding":"JSONRPC","protocolVersion":"1.0"}],
        \\ "capabilities":{"streaming":true},
        \\ "defaultInputModes":["text/plain"],"defaultOutputModes":["text/plain"]}
    ;
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var card = try AgentCard.jsonParseFromValue(a, parsed.value, .{});
    defer card.deinit();
    try testing.expectEqual(@as(usize, 0), card.skills.len);
}

test "agent_card wrapped security requirements" {
    const a = testing.allocator;
    const json =
        \\{"name":"Spec","description":"d","version":"1.0.0",
        \\ "supportedInterfaces":[{"url":"https://example.com","protocolBinding":"JSONRPC","protocolVersion":"1.0"}],
        \\ "capabilities":{"streaming":true},
        \\ "defaultInputModes":["text/plain"],"defaultOutputModes":["text/plain"],
        \\ "skills":[],
        \\ "securityRequirements":[{"schemes":{"bearer_token":{"list":[]}}}]}
    ;
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var card = try AgentCard.jsonParseFromValue(a, parsed.value, .{});
    defer card.deinit();
    const reqs = card.security_requirements.?;
    try testing.expectEqual(@as(usize, 1), reqs.len);
    const scopes = reqs[0].entries.get("bearer_token").?;
    try testing.expectEqual(@as(usize, 0), scopes.len);
}

test "agent_card with security schemes flat" {
    const a = testing.allocator;
    var schemes: SecuritySchemes = .{ .allocator = a };
    try schemes.entries.put(
        a,
        try a.dupe(u8, "bearer"),
        .{ .http_auth = .{ .scheme = try a.dupe(u8, "Bearer"), .allocator = a } },
    );

    var req: SecurityRequirement = .{ .allocator = a };
    const empty_scopes = try a.alloc([]const u8, 0);
    try req.entries.put(a, try a.dupe(u8, "bearer"), empty_scopes);

    const reqs = try a.alloc(SecurityRequirement, 1);
    reqs[0] = req;

    var card = AgentCard{
        .name = try a.dupe(u8, "Secure"),
        .description = try a.dupe(u8, "auth"),
        .version = try a.dupe(u8, "1.0.0"),
        .supported_interfaces = try a.alloc(AgentInterface, 0),
        .capabilities = AgentCapabilities.default(a),
        .default_input_modes = try a.alloc([]const u8, 0),
        .default_output_modes = try a.alloc([]const u8, 0),
        .skills = try a.alloc(AgentSkill, 0),
        .security_schemes = schemes,
        .security_requirements = reqs,
        .allocator = a,
    };
    defer card.deinit();

    const json = try std.json.Stringify.valueAlloc(a, card, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try AgentCard.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back.security_schemes != null);
    try testing.expect(back.security_requirements != null);
    try testing.expectEqual(@as(usize, 1), back.security_requirements.?.len);
}
