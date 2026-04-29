//! a2a-client — A2A protocol client.
const std = @import("std");
pub const a2a = @import("a2a");
pub const transport = @import("transport.zig");

pub const Transport = transport.Transport;
pub const TransportFactory = transport.TransportFactory;
pub const StreamIterator = transport.StreamIterator;
pub const ServiceParams = transport.ServiceParams;

test {
    _ = transport;
}
