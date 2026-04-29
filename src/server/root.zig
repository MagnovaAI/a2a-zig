//! A2A server SDK.
const std = @import("std");
pub const a2a = @import("a2a");
pub const middleware = @import("middleware.zig");
pub const executor = @import("executor.zig");
pub const agent_card = @import("agent_card.zig");
pub const execution = @import("execution.zig");
pub const handler = @import("handler.zig");
pub const task_store = struct {
    pub const store = @import("task_store/store.zig");
    pub const inmemory = @import("task_store/inmemory.zig");
    pub const TaskStore = store.TaskStore;
    pub const TaskVersion = store.TaskVersion;
    pub const InMemoryTaskStore = inmemory.InMemoryTaskStore;
};
pub const push = struct {
    pub const store = @import("push/store.zig");
    pub const sender = @import("push/sender.zig");
    pub const PushConfigStore = store.PushConfigStore;
    pub const InMemoryPushConfigStore = store.InMemoryPushConfigStore;
    pub const HttpPushSender = sender.HttpPushSender;
    pub const HttpPushSenderConfig = sender.Config;
};

pub const User = middleware.User;
pub const ServiceParams = middleware.ServiceParams;
pub const CallContext = middleware.CallContext;
pub const AgentExecutor = executor.AgentExecutor;
pub const ExecutorContext = executor.ExecutorContext;
pub const TaskStore = task_store.TaskStore;
pub const TaskVersion = task_store.TaskVersion;
pub const InMemoryTaskStore = task_store.InMemoryTaskStore;
pub const PushConfigStore = push.PushConfigStore;
pub const InMemoryPushConfigStore = push.InMemoryPushConfigStore;
pub const HttpPushSender = push.HttpPushSender;
pub const HttpPushSenderConfig = push.HttpPushSenderConfig;
pub const AgentCardProducer = agent_card.AgentCardProducer;
pub const StaticAgentCard = agent_card.StaticAgentCard;
pub const AgentCardHandler = agent_card.Handler;
pub const WELL_KNOWN_AGENT_CARD_PATH = agent_card.WELL_KNOWN_AGENT_CARD_PATH;
pub const ActiveExecution = execution.ActiveExecution;
pub const ExecutionManager = execution.ExecutionManager;
pub const ExecutionEvent = execution.ExecutionEvent;
pub const RequestHandler = handler.RequestHandler;
pub const DefaultRequestHandler = handler.DefaultRequestHandler;

test {
    _ = middleware;
    _ = executor;
    _ = task_store.store;
    _ = task_store.inmemory;
    _ = push.store;
    _ = push.sender;
    _ = agent_card;
    _ = execution;
    _ = handler;
}
