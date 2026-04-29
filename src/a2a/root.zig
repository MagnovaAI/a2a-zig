//! a2a — A2A v1 protocol types and core definitions.
//! Mirrors `a2a-rs/a2a/src/lib.rs`.
const std = @import("std");

pub const errors = @import("errors.zig");
pub const jsonrpc = @import("jsonrpc.zig");
pub const types = @import("types.zig");
pub const event = @import("event.zig");
pub const agent_card = @import("agent_card.zig");

// Re-exports
pub const A2AError = errors.A2AError;
pub const code = errors.code;
pub const JsonRpcId = jsonrpc.JsonRpcId;
pub const JsonRpcError = jsonrpc.JsonRpcError;
pub const JsonRpcRequest = jsonrpc.JsonRpcRequest;
pub const JsonRpcResponse = jsonrpc.JsonRpcResponse;
pub const methods = jsonrpc.methods;
pub const Role = types.Role;
pub const TaskState = types.TaskState;
pub const Part = types.Part;
pub const PartContent = types.PartContent;
pub const Message = types.Message;
pub const TaskStatus = types.TaskStatus;
pub const Task = types.Task;
pub const Artifact = types.Artifact;
pub const Metadata = types.Metadata;
pub const SendMessageConfiguration = types.SendMessageConfiguration;
pub const SendMessageRequest = types.SendMessageRequest;
pub const SendMessageResponse = types.SendMessageResponse;
pub const GetTaskRequest = types.GetTaskRequest;
pub const ListTasksRequest = types.ListTasksRequest;
pub const ListTasksResponse = types.ListTasksResponse;
pub const CancelTaskRequest = types.CancelTaskRequest;
pub const SubscribeToTaskRequest = types.SubscribeToTaskRequest;
pub const GetExtendedAgentCardRequest = types.GetExtendedAgentCardRequest;
pub const PushNotificationConfig = types.PushNotificationConfig;
pub const AuthenticationInfo = types.AuthenticationInfo;
pub const TaskPushNotificationConfig = types.TaskPushNotificationConfig;
pub const GetTaskPushNotificationConfigRequest = types.GetTaskPushNotificationConfigRequest;
pub const ListTaskPushNotificationConfigsRequest = types.ListTaskPushNotificationConfigsRequest;
pub const ListTaskPushNotificationConfigsResponse = types.ListTaskPushNotificationConfigsResponse;
pub const CreateTaskPushNotificationConfigRequest = types.CreateTaskPushNotificationConfigRequest;
pub const DeleteTaskPushNotificationConfigRequest = types.DeleteTaskPushNotificationConfigRequest;
pub const TRANSPORT_PROTOCOL_JSONRPC = types.TRANSPORT_PROTOCOL_JSONRPC;
pub const TRANSPORT_PROTOCOL_GRPC = types.TRANSPORT_PROTOCOL_GRPC;
pub const TRANSPORT_PROTOCOL_HTTP_JSON = types.TRANSPORT_PROTOCOL_HTTP_JSON;
pub const TRANSPORT_PROTOCOL_SLIMRPC = types.TRANSPORT_PROTOCOL_SLIMRPC;
pub const newTaskId = types.newTaskId;
pub const newContextId = types.newContextId;
pub const newMessageId = types.newMessageId;
pub const newArtifactId = types.newArtifactId;
pub const StreamResponse = event.StreamResponse;
pub const TaskStatusUpdateEvent = event.TaskStatusUpdateEvent;
pub const TaskArtifactUpdateEvent = event.TaskArtifactUpdateEvent;
pub const AgentCard = agent_card.AgentCard;
pub const AgentInterface = agent_card.AgentInterface;
pub const AgentProvider = agent_card.AgentProvider;
pub const AgentCapabilities = agent_card.AgentCapabilities;
pub const AgentExtension = agent_card.AgentExtension;
pub const AgentSkill = agent_card.AgentSkill;
pub const SecurityScheme = agent_card.SecurityScheme;
pub const SecuritySchemes = agent_card.SecuritySchemes;
pub const SecurityRequirement = agent_card.SecurityRequirement;
pub const OAuthFlows = agent_card.OAuthFlows;
pub const ApiKeySecurityScheme = agent_card.ApiKeySecurityScheme;
pub const HttpAuthSecurityScheme = agent_card.HttpAuthSecurityScheme;
pub const OAuth2SecurityScheme = agent_card.OAuth2SecurityScheme;
pub const OpenIdConnectSecurityScheme = agent_card.OpenIdConnectSecurityScheme;
pub const MutualTlsSecurityScheme = agent_card.MutualTlsSecurityScheme;
pub const AgentCardSignature = agent_card.AgentCardSignature;

/// The A2A protocol version this SDK implements.
pub const VERSION: []const u8 = "1.0";

/// Service parameter key for the A2A protocol version.
pub const SVC_PARAM_VERSION: []const u8 = "A2A-Version";

/// Service parameter key for extensions the client wants to use.
pub const SVC_PARAM_EXTENSIONS: []const u8 = "A2A-Extensions";

test {
    _ = errors;
    _ = jsonrpc;
    _ = types;
    _ = event;
    _ = agent_card;
}
