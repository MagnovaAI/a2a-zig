//! A2A server SDK.
const std = @import("std");
pub const a2a = @import("a2a");
pub const middleware = @import("middleware.zig");
pub const executor = @import("executor.zig");
pub const agent_card = @import("agent_card.zig");
pub const execution = @import("execution.zig");
pub const task_store = struct {
    pub const store = @import("task_store/store.zig");
    pub const inmemory = @import("task_store/inmemory.zig");
    pub const TaskStore = store.TaskStore;
    pub const TaskVersion = store.TaskVersion;
    pub const InMemoryTaskStore = inmemory.InMemoryTaskStore;
};

pub const User = middleware.User;
pub const ServiceParams = middleware.ServiceParams;
pub const CallContext = middleware.CallContext;
pub const AgentExecutor = executor.AgentExecutor;
pub const ExecutorContext = executor.ExecutorContext;
pub const TaskStore = task_store.TaskStore;
pub const TaskVersion = task_store.TaskVersion;
pub const InMemoryTaskStore = task_store.InMemoryTaskStore;
pub const AgentCardProducer = agent_card.AgentCardProducer;
pub const StaticAgentCard = agent_card.StaticAgentCard;
pub const AgentCardHandler = agent_card.Handler;
pub const WELL_KNOWN_AGENT_CARD_PATH = agent_card.WELL_KNOWN_AGENT_CARD_PATH;
pub const ActiveExecution = execution.ActiveExecution;
pub const ExecutionManager = execution.ExecutionManager;
pub const ExecutionEvent = execution.ExecutionEvent;

test {
    _ = middleware;
    _ = executor;
    _ = task_store.store;
    _ = task_store.inmemory;
    _ = agent_card;
    _ = execution;
}
