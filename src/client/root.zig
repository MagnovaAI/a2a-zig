//! a2a-client — A2A protocol client.
const std = @import("std");
pub const a2a = @import("a2a");
pub const transport = @import("transport.zig");
pub const middleware = @import("middleware.zig");
pub const auth = @import("auth.zig");
pub const agent_card = @import("agent_card.zig");
pub const factory = @import("factory.zig");
pub const rest = @import("rest.zig");

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
pub const A2AClientFactory = factory.A2AClientFactory;
pub const TransportKey = factory.TransportKey;
pub const RestTransport = rest.RestTransport;
pub const RestTransportFactory = rest.RestTransportFactory;

test {
    _ = transport;
    _ = middleware;
    _ = auth;
    _ = agent_card;
    _ = factory;
    _ = rest;
}
