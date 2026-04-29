//! sysclock — wall-clock and monotonic time helpers.
//!
//! Zig 0.16 dropped `std.time.milliTimestamp` / `nanoTimestamp` in favor of
//! routing all I/O (including time) through an `Io` instance. For places where
//! we just need a UTC timestamp without plumbing an `Io` through (UUIDv7,
//! event timestamps, RFC3339 stamping), this lib calls `clock_gettime` via
//! libc directly.
const std = @import("std");
const c = std.c;
const builtin = @import("builtin");

/// Unix wall-clock nanoseconds since 1970-01-01 UTC.
pub fn nowNanos() i128 {
    var ts: c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = c.clock_gettime(c.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// Unix wall-clock milliseconds.
pub fn nowMillis() i64 {
    return @intCast(@divTrunc(nowNanos(), std.time.ns_per_ms));
}

/// Unix wall-clock seconds.
pub fn nowSeconds() i64 {
    return @intCast(@divTrunc(nowNanos(), std.time.ns_per_s));
}

const testing = std.testing;

test "nowMillis is positive and recent" {
    const ms = nowMillis();
    // Some time after 2024-01-01.
    try testing.expect(ms > 1_704_067_200_000);
    // Before 2100-01-01.
    try testing.expect(ms < 4_102_444_800_000);
}

test "nowNanos > nowMillis * 1e6" {
    const ns = nowNanos();
    const ms = nowMillis();
    try testing.expect(ns >= @as(i128, ms) * std.time.ns_per_ms);
}
