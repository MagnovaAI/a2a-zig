//! a2a-client — A2A protocol client.
const std = @import("std");
pub const a2a = @import("a2a");
pub const transport = @import("transport.zig");
pub const middleware = @import("middleware.zig");
pub const auth = @import("auth.zig");
pub const agent_card = @import("agent_card.zig");

pub const Transport = transport.Transport;
pub const TransportFactory = transport.TransportFactory;
pub const StreamIterator = transport.StreamIterator;
pub const ServiceParams = transport.ServiceParams;
pub const CallInterceptor = middleware.CallInterceptor;
pub const CallResult = middleware.CallResult;
pub const LoggingInterceptor = middleware.LoggingInterceptor;
pub const CredentialsStore = auth.CredentialsStore;
pub const InMemoryCredentialsStore = auth.InMemoryCredentialsStore;
pub const AuthInterceptor = auth.AuthInterceptor;
pub const AgentCardResolver = agent_card.AgentCardResolver;

test {
    _ = transport;
    _ = middleware;
    _ = auth;
    _ = agent_card;
}
