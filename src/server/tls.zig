//! TLS configuration for the A2A server.
//!
//! This module wraps the upstream `tls.zig` (ianic/tls.zig) types so callers
//! don't have to learn the upstream API just to point the server at a
//! certificate file.
//!
//! `Config` carries the cert/key paths plus the live materials needed to
//! drive a TLS 1.3 handshake on accepted sockets. After loading, callers
//! can hand `serverOptions(now)` directly to `tls.serverFromStream` for
//! every accepted connection.
//!
//! `httpz` doesn't yet ship native TLS support; deployments that need TLS
//! today are expected to either terminate at a reverse proxy and proxy
//! plain HTTP to the A2A server, or build a custom accept loop on top of
//! `std.Io.net` and use `Config` to upgrade each connection.
const std = @import("std");
const tls = @import("tls");

const log = std.log.scoped(.a2a_server);

/// Inputs the loader needs to build a TLS server `Config`.
pub const Source = union(enum) {
    /// Read PEM-encoded files at the given absolute paths.
    files: struct {
        cert_path: []const u8,
        key_path: []const u8,
    },
    /// Use an in-memory PEM byte slice (handy for embedded credentials and tests).
    slices: struct {
        cert_pem: []const u8,
        key_pem: []const u8,
    },
};

/// Tunables controlling which TLS 1.3 features the server advertises.
pub const Tunables = struct {
    /// ALPN protocols offered to the client, in preference order. Default is
    /// `http/1.1` because that's what httpz speaks.
    alpn_protocols: []const []const u8 = &.{"http/1.1"},
    /// Cipher suites the server is willing to negotiate. Default is the full
    /// TLS 1.3 set shipped by upstream.
    cipher_suites: []const tls.config.CipherSuite = tls.config.cipher_suites.tls13,
    /// Optional client-certificate authentication. When null the server
    /// doesn't request one. Type is the upstream `ClientAuth` struct.
    client_auth: ?@TypeOf(@as(tls.config.Server, undefined).client_auth) = null,
};

/// Loaded TLS material plus tunables. Owns its allocator-backed memory; call
/// `deinit` to release it.
pub const Config = struct {
    allocator: std.mem.Allocator,
    auth: tls.config.CertKeyPair,
    tunables: Tunables,

    /// Load credentials from `source` into a fresh `Config`. The `io`
    /// instance is used for filesystem reads.
    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        source: Source,
        tunables: Tunables,
    ) !Config {
        const auth = switch (source) {
            .files => |f| try tls.config.CertKeyPair.fromFilePathAbsolute(
                allocator,
                io,
                f.cert_path,
                f.key_path,
            ),
            .slices => |s| try tls.config.CertKeyPair.fromSlice(
                allocator,
                io,
                s.cert_pem,
                s.key_pem,
            ),
        };
        return .{ .allocator = allocator, .auth = auth, .tunables = tunables };
    }

    pub fn deinit(self: *Config) void {
        self.auth.deinit(self.allocator);
        self.* = undefined;
    }

    /// Build a `tls.config.Server` ready to hand to `tls.serverFromStream`.
    /// `now` is the current wall-clock used to validate certificate
    /// expiration; `rng` is a CSPRNG source (typically `std.crypto.random`).
    pub fn serverOptions(
        self: *Config,
        now: std.Io.Timestamp,
        rng: std.Random,
    ) tls.config.Server {
        return .{
            .rng = rng,
            .auth = &self.auth,
            .client_auth = self.tunables.client_auth,
            .cipher_suites = self.tunables.cipher_suites,
            .alpn_protocols = self.tunables.alpn_protocols,
            .now = now,
        };
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Tunables defaults to http/1.1 ALPN and TLS 1.3 ciphers" {
    const t: Tunables = .{};
    try testing.expectEqual(@as(usize, 1), t.alpn_protocols.len);
    try testing.expectEqualStrings("http/1.1", t.alpn_protocols[0]);
    try testing.expect(t.cipher_suites.len > 0);
}

test "Source variants compile" {
    const s1: Source = .{ .files = .{ .cert_path = "/tmp/c", .key_path = "/tmp/k" } };
    const s2: Source = .{ .slices = .{ .cert_pem = "", .key_pem = "" } };
    _ = s1;
    _ = s2;
}
