//! Client factory and transport registry. Registers `TransportFactory`
//! implementations and picks the best match for an `AgentCard`. The
//! high-level client itself lives in `client.zig`.
const std = @import("std");
const a2a = @import("a2a");
const transport = @import("transport.zig");

const log = std.log.scoped(.a2a_client);

const TransportFactoryPtr = *const transport.TransportFactory;

// ---------------------------------------------------------------------------
// TransportKey — (protocol, major version) lookup key
// ---------------------------------------------------------------------------

pub const TransportKey = struct {
    /// Owned by the parent map's allocator.
    protocol: []const u8,
    major_version: u64,

    pub fn fromInterface(iface: *const a2a.AgentInterface) TransportKey {
        return .{
            .protocol = iface.protocol_binding,
            .major_version = parseMajor(iface.protocol_version),
        };
    }

    pub fn fromProtocol(protocol: []const u8, version: []const u8) TransportKey {
        return .{
            .protocol = protocol,
            .major_version = parseMajor(version),
        };
    }

    fn parseMajor(version: []const u8) u64 {
        const dot_idx = std.mem.indexOfScalar(u8, version, '.') orelse version.len;
        const head = version[0..dot_idx];
        return std.fmt.parseInt(u64, head, 10) catch 1;
    }
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, key: TransportKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.protocol);
        hasher.update(std.mem.asBytes(&key.major_version));
        return hasher.final();
    }
    pub fn eql(_: KeyContext, a: TransportKey, b: TransportKey) bool {
        return a.major_version == b.major_version and std.mem.eql(u8, a.protocol, b.protocol);
    }
};

const RegistryMap = std.HashMapUnmanaged(TransportKey, TransportFactoryPtr, KeyContext, std.hash_map.default_max_load_percentage);

// ---------------------------------------------------------------------------
// A2AClientFactory
// ---------------------------------------------------------------------------

pub const SelectError = error{
    OutOfMemory,
    NoCompatibleTransport,
    AllTransportsFailed,
};

pub const A2AClientFactory = struct {
    allocator: std.mem.Allocator,
    factories: RegistryMap = .empty,
    /// Owned by `allocator`. Each entry is also owned (caller-passed slices
    /// are duplicated in `Builder.preferredBindings`).
    preferred_bindings: []const []const u8 = &.{},
    interceptors: []*transport.TransportFactory = &.{},

    pub fn builder(allocator: std.mem.Allocator) Builder {
        return Builder.init(allocator);
    }

    pub fn deinit(self: *A2AClientFactory) void {
        var it = self.factories.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.protocol);
        }
        self.factories.deinit(self.allocator);
        for (self.preferred_bindings) |s| self.allocator.free(s);
        self.allocator.free(self.preferred_bindings);
        self.* = undefined;
    }

    /// Pick the best matching transport for `card` and instantiate it.
    ///
    /// Selection algorithm:
    /// 1. For each interface in `card.supported_interfaces`, look up a
    ///    factory by `(protocol_binding, major_version)`.
    /// 2. Rank candidates by the client's preferred-binding order; ties
    ///    keep document order.
    /// 3. Try each candidate in rank order. First success wins.
    ///
    /// On full failure, returns `error.NoCompatibleTransport` if no factory
    /// matched any interface, otherwise `error.AllTransportsFailed`.
    pub fn createFromCard(
        self: *const A2AClientFactory,
        request_allocator: std.mem.Allocator,
        card: *const a2a.AgentCard,
    ) SelectError!*transport.Transport {
        const Candidate = struct {
            priority: usize,
            iface: *const a2a.AgentInterface,
            factory: TransportFactoryPtr,
        };

        var candidates: std.array_list.Managed(Candidate) = .init(request_allocator);
        defer candidates.deinit();

        for (card.supported_interfaces) |*iface| {
            const key = TransportKey.fromInterface(iface);
            if (self.factories.get(key)) |factory| {
                var prio: usize = std.math.maxInt(usize);
                for (self.preferred_bindings, 0..) |b, i| {
                    if (std.mem.eql(u8, b, iface.protocol_binding)) {
                        prio = i;
                        break;
                    }
                }
                try candidates.append(.{ .priority = prio, .iface = iface, .factory = factory });
            }
        }

        if (candidates.items.len == 0) {
            return error.NoCompatibleTransport;
        }

        std.sort.pdq(Candidate, candidates.items, {}, struct {
            fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                return a.priority < b.priority;
            }
        }.lessThan);

        for (candidates.items) |c| {
            return c.factory.create(request_allocator, card, c.iface) catch |err| {
                log.debug(
                    "transport creation failed: protocol={s} url={s} err={s}",
                    .{ c.iface.protocol_binding, c.iface.url, @errorName(err) },
                );
                continue;
            };
        }

        return error.AllTransportsFailed;
    }

    pub const Builder = struct {
        allocator: std.mem.Allocator,
        factories: RegistryMap = .empty,
        preferred_bindings: std.array_list.Managed([]const u8),

        pub fn init(allocator: std.mem.Allocator) Builder {
            var b: Builder = .{
                .allocator = allocator,
                .preferred_bindings = .init(allocator),
            };
            // Defaults: prefer JSON-RPC, fall back to REST.
            b.preferred_bindings.append(allocator.dupe(u8, a2a.TRANSPORT_PROTOCOL_JSONRPC) catch unreachable) catch unreachable;
            b.preferred_bindings.append(allocator.dupe(u8, a2a.TRANSPORT_PROTOCOL_HTTP_JSON) catch unreachable) catch unreachable;
            return b;
        }

        /// Discards anything the builder has accumulated. Use when bailing out.
        pub fn deinit(self: *Builder) void {
            var it = self.factories.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.protocol);
            self.factories.deinit(self.allocator);
            for (self.preferred_bindings.items) |s| self.allocator.free(s);
            self.preferred_bindings.deinit();
            self.* = undefined;
        }

        /// Register a transport factory under `(factory.protocol(), VERSION)`.
        /// `factory` must outlive the resulting `A2AClientFactory`.
        pub fn register(self: *Builder, factory: TransportFactoryPtr) !*Builder {
            const protocol = factory.protocol();
            const owned = try self.allocator.dupe(u8, protocol);
            errdefer self.allocator.free(owned);
            try self.factories.put(self.allocator, .{
                .protocol = owned,
                .major_version = TransportKey.parseMajor(a2a.VERSION),
            }, factory);
            return self;
        }

        pub fn preferredBindings(self: *Builder, bindings: []const []const u8) !*Builder {
            for (self.preferred_bindings.items) |s| self.allocator.free(s);
            self.preferred_bindings.clearRetainingCapacity();
            try self.preferred_bindings.ensureTotalCapacity(bindings.len);
            for (bindings) |b| {
                self.preferred_bindings.appendAssumeCapacity(try self.allocator.dupe(u8, b));
            }
            return self;
        }

        pub fn build(self: *Builder) !A2AClientFactory {
            const factories = self.factories;
            const bindings_owned = try self.preferred_bindings.toOwnedSlice();
            self.factories = .empty; // ownership transfers
            self.preferred_bindings = .init(self.allocator);
            return .{
                .allocator = self.allocator,
                .factories = factories,
                .preferred_bindings = bindings_owned,
                .interceptors = &.{},
            };
        }
    };
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeIface(allocator: std.mem.Allocator, url: []const u8, binding: []const u8) !a2a.AgentInterface {
    return a2a.AgentInterface.init(allocator, url, binding);
}

test "TransportKey from interface" {
    const a = testing.allocator;
    var iface = try makeIface(a, "http://localhost", "JSONRPC");
    defer iface.deinit();
    const key = TransportKey.fromInterface(&iface);
    try testing.expectEqualStrings("JSONRPC", key.protocol);
    try testing.expectEqual(@as(u64, 1), key.major_version);
}

test "TransportKey from interface with bad version defaults to 1" {
    const a = testing.allocator;
    var iface = try makeIface(a, "http://localhost", "REST");
    defer iface.deinit();
    a.free(iface.protocol_version);
    iface.protocol_version = try a.dupe(u8, "bad");
    const key = TransportKey.fromInterface(&iface);
    try testing.expectEqual(@as(u64, 1), key.major_version);
}

test "TransportKey from protocol" {
    const key = TransportKey.fromProtocol("JSONRPC", "2.3.4");
    try testing.expectEqualStrings("JSONRPC", key.protocol);
    try testing.expectEqual(@as(u64, 2), key.major_version);
}

test "builder defaults preferred bindings" {
    const a = testing.allocator;
    var b = A2AClientFactory.Builder.init(a);
    var f = try b.build();
    defer f.deinit();
    try testing.expectEqual(@as(usize, 2), f.preferred_bindings.len);
    try testing.expectEqualStrings(a2a.TRANSPORT_PROTOCOL_JSONRPC, f.preferred_bindings[0]);
    try testing.expectEqualStrings(a2a.TRANSPORT_PROTOCOL_HTTP_JSON, f.preferred_bindings[1]);
}

test "builder override preferred bindings" {
    const a = testing.allocator;
    var b = A2AClientFactory.Builder.init(a);
    _ = try b.preferredBindings(&.{"GRPC"});
    var f = try b.build();
    defer f.deinit();
    try testing.expectEqual(@as(usize, 1), f.preferred_bindings.len);
    try testing.expectEqualStrings("GRPC", f.preferred_bindings[0]);
}

// Stub factory used to test the registry without a real transport.
const StubFactoryState = struct { protocol_name: []const u8 };

fn stubProtocol(ctx: *anyopaque) []const u8 {
    const s: *StubFactoryState = @ptrCast(@alignCast(ctx));
    return s.protocol_name;
}

fn stubCreate(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: *const a2a.AgentCard,
    _: *const a2a.AgentInterface,
) transport.TransportFactory.Error!*transport.Transport {
    return error.UnsupportedProtocol;
}

const stub_vtable: transport.TransportFactory.VTable = .{
    .protocol = stubProtocol,
    .create = stubCreate,
};

test "registry rejects card with no compatible transport" {
    const a = testing.allocator;
    var b = A2AClientFactory.Builder.init(a);
    var f = try b.build();
    defer f.deinit();

    const empty_ifaces = try a.alloc(a2a.AgentInterface, 1);
    empty_ifaces[0] = try makeIface(a, "http://localhost", "FUTURE_PROTO");

    const empty_modes = try a.alloc([]const u8, 0);
    const empty_modes2 = try a.alloc([]const u8, 0);
    const empty_skills = try a.alloc(a2a.AgentSkill, 0);

    var card = a2a.AgentCard{
        .name = try a.dupe(u8, "test"),
        .description = try a.dupe(u8, "test agent"),
        .version = try a.dupe(u8, "1.0"),
        .supported_interfaces = empty_ifaces,
        .capabilities = a2a.AgentCapabilities.default(a),
        .default_input_modes = empty_modes,
        .default_output_modes = empty_modes2,
        .skills = empty_skills,
        .allocator = a,
    };
    defer card.deinit();

    const result = f.createFromCard(a, &card);
    try testing.expectError(error.NoCompatibleTransport, result);
}

test "registry picks registered transport, propagates create error" {
    const a = testing.allocator;
    var b = A2AClientFactory.Builder.init(a);

    var stub_state: StubFactoryState = .{ .protocol_name = "JSONRPC" };
    const stub_factory: transport.TransportFactory = .{ .ctx = @ptrCast(&stub_state), .vtable = &stub_vtable };
    _ = try b.register(&stub_factory);

    var f = try b.build();
    defer f.deinit();

    const ifaces = try a.alloc(a2a.AgentInterface, 1);
    ifaces[0] = try makeIface(a, "http://localhost", "JSONRPC");

    const empty_modes = try a.alloc([]const u8, 0);
    const empty_modes2 = try a.alloc([]const u8, 0);
    const empty_skills = try a.alloc(a2a.AgentSkill, 0);

    var card = a2a.AgentCard{
        .name = try a.dupe(u8, "test"),
        .description = try a.dupe(u8, "test agent"),
        .version = try a.dupe(u8, "1.0"),
        .supported_interfaces = ifaces,
        .capabilities = a2a.AgentCapabilities.default(a),
        .default_input_modes = empty_modes,
        .default_output_modes = empty_modes2,
        .skills = empty_skills,
        .allocator = a,
    };
    defer card.deinit();

    // Stub returns UnsupportedProtocol for every create — factory should
    // surface AllTransportsFailed once every candidate has been tried.
    const result = f.createFromCard(a, &card);
    try testing.expectError(error.AllTransportsFailed, result);
}
