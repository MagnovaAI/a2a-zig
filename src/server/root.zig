//! A2A server SDK.
const std = @import("std");
pub const a2a = @import("a2a");
pub const middleware = @import("middleware.zig");
pub const executor = @import("executor.zig");

pub const User = middleware.User;
pub const ServiceParams = middleware.ServiceParams;
pub const CallContext = middleware.CallContext;
pub const AgentExecutor = executor.AgentExecutor;
pub const ExecutorContext = executor.ExecutorContext;

test {
    _ = middleware;
    _ = executor;
}
