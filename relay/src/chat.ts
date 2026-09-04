/**
 * POST /api/chat — authenticated passthrough to the Anthropic Messages API.
 *
 * The desktop app sends the same shape it would send to Anthropic (system, messages with text,
 * image, tool_use and tool_result blocks, tool definitions, max_tokens, stream). The relay adds the
 * vendor key, pins the model to the allow-list, and streams the SSE body straight back. It stores
 * nothing: no prompts, no screenshots, no completions, no tool results. It never executes a tool:
 * the app runs gateway tools itself with the user's own token (docs/PERMISSIONS.md). One log line
 * per call records who, which model, how many tools were offered, and the status.
 */
import { app, type HttpRequest, type HttpResponseInit, type InvocationContext } from "@azure/functions";
import { getRelayConfig, type RelayConfig } from "./config.js";
import { authenticateRequest, errorResponse, readJsonBody } from "./http.js";

const ANTHROPIC_MESSAGES_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_API_VERSION = "2023-06-01";
const MAX_OUTPUT_TOKENS_CAP = 4096;
const MAX_HISTORY_MESSAGES = 40;
const MAX_IMAGE_BYTES_BASE64 = 8 * 1024 * 1024; // 8 MB of base64 per image, roughly a 6 MB PNG
const SUPPORTED_IMAGE_MEDIA_TYPES = new Set(["image/png", "image/jpeg", "image/webp", "image/gif"]);
// Tool use (docs/PERMISSIONS.md 3): the app describes a handful of for-mcp gateway tools to the
// model and executes the calls itself with the user's own gateway token. The relay only forwards
// the definitions and the tool_use / tool_result blocks; it never calls a tool.
const MAX_TOOL_DEFINITIONS = 16;
const MAX_TOOL_RESULT_CHARACTERS = 64 * 1024;
const TOOL_NAME_PATTERN = /^[a-zA-Z0-9_-]{1,64}$/;

export interface WingmanChatTextBlock {
  type: "text";
  text: string;
}

export interface WingmanChatImageBlock {
  type: "image";
  source: { type: "base64"; media_type: string; data: string };
}

/** The model asking the app to run a tool. Appears only in assistant turns. */
export interface WingmanChatToolUseBlock {
  type: "tool_use";
  id: string;
  name: string;
  input: Record<string, unknown>;
}

/** The app's answer to a tool_use block. Appears only in user turns. */
export interface WingmanChatToolResultBlock {
  type: "tool_result";
  tool_use_id: string;
  content: string | WingmanChatTextBlock[];
  is_error?: boolean;
}

export type WingmanChatContentBlock =
  | WingmanChatTextBlock
  | WingmanChatImageBlock
  | WingmanChatToolUseBlock
  | WingmanChatToolResultBlock;

export interface WingmanChatMessage {
  role: "user" | "assistant";
  content: string | WingmanChatContentBlock[];
}

export interface WingmanToolDefinition {
  name: string;
  description?: string;
  input_schema: { type: "object"; [key: string]: unknown };
}

export type WingmanToolChoice = { type: "auto" } | { type: "any" } | { type: "none" } | { type: "tool"; name: string };

export interface WingmanChatRequest {
  model?: string;
  system?: string;
  messages?: WingmanChatMessage[];
  max_tokens?: number;
  temperature?: number;
  stream?: boolean;
  tools?: WingmanToolDefinition[];
  tool_choice?: WingmanToolChoice;
}

export interface AnthropicMessagesRequest {
  model: string;
  system?: string;
  messages: WingmanChatMessage[];
  max_tokens: number;
  temperature?: number;
  stream: boolean;
  tools?: WingmanToolDefinition[];
  tool_choice?: WingmanToolChoice;
}

export class ChatRequestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ChatRequestError";
  }
}

/** Picks the model the relay will actually use: the requested one if allowed, else the default. */
export function resolveModel(requestedModel: string | undefined, config: Pick<RelayConfig, "allowedModels" | "defaultModel">): string {
  if (requestedModel && config.allowedModels.includes(requestedModel)) return requestedModel;
  return config.defaultModel;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function validateContentBlock(block: WingmanChatContentBlock, messageIndex: number, role: "user" | "assistant"): void {
  if (block.type === "text") {
    if (typeof block.text !== "string") throw new ChatRequestError(`messages[${messageIndex}]: text block without text`);
    return;
  }
  if (block.type === "tool_use") {
    if (role !== "assistant") throw new ChatRequestError(`messages[${messageIndex}]: tool_use blocks belong to assistant turns`);
    if (typeof block.id !== "string" || block.id.length === 0) throw new ChatRequestError(`messages[${messageIndex}]: tool_use block without id`);
    if (typeof block.name !== "string" || !TOOL_NAME_PATTERN.test(block.name)) {
      throw new ChatRequestError(`messages[${messageIndex}]: tool_use block with an invalid tool name`);
    }
    if (!isPlainObject(block.input)) throw new ChatRequestError(`messages[${messageIndex}]: tool_use input must be an object`);
    return;
  }
  if (block.type === "tool_result") {
    if (role !== "user") throw new ChatRequestError(`messages[${messageIndex}]: tool_result blocks belong to user turns`);
    if (typeof block.tool_use_id !== "string" || block.tool_use_id.length === 0) {
      throw new ChatRequestError(`messages[${messageIndex}]: tool_result block without tool_use_id`);
    }
    if (typeof block.content === "string") {
      if (block.content.length > MAX_TOOL_RESULT_CHARACTERS) throw new ChatRequestError(`messages[${messageIndex}]: tool_result exceeds the relay size limit`);
    } else if (Array.isArray(block.content)) {
      let totalCharacters = 0;
      for (const resultBlock of block.content) {
        if (!isPlainObject(resultBlock) || resultBlock.type !== "text" || typeof resultBlock.text !== "string") {
          throw new ChatRequestError(`messages[${messageIndex}]: tool_result content may only hold text blocks`);
        }
        totalCharacters += resultBlock.text.length;
      }
      if (totalCharacters > MAX_TOOL_RESULT_CHARACTERS) throw new ChatRequestError(`messages[${messageIndex}]: tool_result exceeds the relay size limit`);
    } else {
      throw new ChatRequestError(`messages[${messageIndex}]: tool_result content must be a string or text blocks`);
    }
    if (block.is_error !== undefined && typeof block.is_error !== "boolean") {
      throw new ChatRequestError(`messages[${messageIndex}]: tool_result is_error must be a boolean`);
    }
    return;
  }
  if (block.type === "image") {
    const source = block.source;
    if (!source || source.type !== "base64" || typeof source.data !== "string") {
      throw new ChatRequestError(`messages[${messageIndex}]: image block must carry base64 source data`);
    }
    if (!SUPPORTED_IMAGE_MEDIA_TYPES.has(source.media_type)) {
      throw new ChatRequestError(`messages[${messageIndex}]: unsupported image media type ${source.media_type}`);
    }
    if (source.data.length > MAX_IMAGE_BYTES_BASE64) {
      throw new ChatRequestError(`messages[${messageIndex}]: image exceeds the relay size limit`);
    }
    return;
  }
  throw new ChatRequestError(`messages[${messageIndex}]: unknown content block type`);
}

/**
 * Validates the app's request and produces the exact body sent upstream. Pure, so the rules are
 * unit-tested. Throws ChatRequestError with a message safe to return to the app.
 */
export function buildAnthropicRequest(
  wingmanRequest: WingmanChatRequest,
  config: Pick<RelayConfig, "allowedModels" | "defaultModel">,
): AnthropicMessagesRequest {
  const messages = wingmanRequest.messages;
  if (!Array.isArray(messages) || messages.length === 0) throw new ChatRequestError("messages must be a non-empty array");
  if (messages.length > MAX_HISTORY_MESSAGES) throw new ChatRequestError(`messages is limited to ${MAX_HISTORY_MESSAGES} entries`);

  messages.forEach((message, messageIndex) => {
    if (message.role !== "user" && message.role !== "assistant") {
      throw new ChatRequestError(`messages[${messageIndex}]: role must be user or assistant`);
    }
    if (typeof message.content === "string") return;
    if (!Array.isArray(message.content) || message.content.length === 0) {
      throw new ChatRequestError(`messages[${messageIndex}]: content must be a string or a non-empty block array`);
    }
    message.content.forEach((block) => validateContentBlock(block, messageIndex, message.role));
  });
  if (messages[messages.length - 1].role !== "user") throw new ChatRequestError("the last message must come from the user");

  if (wingmanRequest.system !== undefined && typeof wingmanRequest.system !== "string") {
    throw new ChatRequestError("system must be a string");
  }

  const tools = validateToolDefinitions(wingmanRequest.tools);
  const toolChoice = validateToolChoice(wingmanRequest.tool_choice, tools);

  const requestedMaxTokens = typeof wingmanRequest.max_tokens === "number" ? Math.floor(wingmanRequest.max_tokens) : 1024;
  const maxTokens = Math.min(Math.max(requestedMaxTokens, 1), MAX_OUTPUT_TOKENS_CAP);

  const anthropicRequest: AnthropicMessagesRequest = {
    model: resolveModel(wingmanRequest.model, config),
    messages,
    max_tokens: maxTokens,
    stream: wingmanRequest.stream !== false,
  };
  if (wingmanRequest.system) anthropicRequest.system = wingmanRequest.system;
  if (typeof wingmanRequest.temperature === "number") {
    anthropicRequest.temperature = Math.min(Math.max(wingmanRequest.temperature, 0), 1);
  }
  if (tools) anthropicRequest.tools = tools;
  if (toolChoice) anthropicRequest.tool_choice = toolChoice;
  return anthropicRequest;
}

function validateToolDefinitions(tools: unknown): WingmanToolDefinition[] | undefined {
  if (tools === undefined) return undefined;
  if (!Array.isArray(tools)) throw new ChatRequestError("tools must be an array");
  if (tools.length === 0) return undefined;
  if (tools.length > MAX_TOOL_DEFINITIONS) throw new ChatRequestError(`tools is limited to ${MAX_TOOL_DEFINITIONS} entries`);
  const seenToolNames = new Set<string>();
  return tools.map((tool, toolIndex) => {
    if (!isPlainObject(tool)) throw new ChatRequestError(`tools[${toolIndex}]: must be an object`);
    if (typeof tool.name !== "string" || !TOOL_NAME_PATTERN.test(tool.name)) {
      throw new ChatRequestError(`tools[${toolIndex}]: name must match ${TOOL_NAME_PATTERN}`);
    }
    if (seenToolNames.has(tool.name)) throw new ChatRequestError(`tools[${toolIndex}]: duplicate tool name ${tool.name}`);
    seenToolNames.add(tool.name);
    if (tool.description !== undefined && typeof tool.description !== "string") {
      throw new ChatRequestError(`tools[${toolIndex}]: description must be a string`);
    }
    if (!isPlainObject(tool.input_schema) || tool.input_schema.type !== "object") {
      throw new ChatRequestError(`tools[${toolIndex}]: input_schema must be a JSON schema of type object`);
    }
    const toolDefinition: WingmanToolDefinition = {
      name: tool.name,
      input_schema: tool.input_schema as WingmanToolDefinition["input_schema"],
    };
    if (typeof tool.description === "string") toolDefinition.description = tool.description;
    return toolDefinition;
  });
}

function validateToolChoice(toolChoice: unknown, tools: WingmanToolDefinition[] | undefined): WingmanToolChoice | undefined {
  if (toolChoice === undefined) return undefined;
  if (!tools) throw new ChatRequestError("tool_choice requires tools");
  if (!isPlainObject(toolChoice)) throw new ChatRequestError("tool_choice must be an object");
  if (toolChoice.type === "auto" || toolChoice.type === "any" || toolChoice.type === "none") return { type: toolChoice.type };
  if (toolChoice.type === "tool") {
    if (typeof toolChoice.name !== "string" || !tools.some((tool) => tool.name === toolChoice.name)) {
      throw new ChatRequestError("tool_choice names a tool that is not in tools");
    }
    return { type: "tool", name: toolChoice.name };
  }
  throw new ChatRequestError("tool_choice type must be auto, any, none or tool");
}

async function chatHandler(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  const authentication = await authenticateRequest(request, context);
  if ("response" in authentication) return authentication.response;
  const { user } = authentication;

  const config = getRelayConfig();
  if (!config.anthropicApiKey) {
    context.error("[chat] ANTHROPIC_API_KEY is not configured (Key Vault reference unresolved?)");
    return errorResponse(503, "model_not_configured", "The relay has no model key configured.");
  }

  const wingmanRequest = await readJsonBody<WingmanChatRequest>(request);
  if (!wingmanRequest) return errorResponse(400, "invalid_json", "Request body must be JSON.");

  let anthropicRequest: AnthropicMessagesRequest;
  try {
    anthropicRequest = buildAnthropicRequest(wingmanRequest, config);
  } catch (error) {
    if (error instanceof ChatRequestError) return errorResponse(400, "invalid_request", error.message);
    throw error;
  }

  const startedAtMs = Date.now();
  let upstreamResponse: Response;
  try {
    upstreamResponse = await fetch(ANTHROPIC_MESSAGES_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": config.anthropicApiKey,
        "anthropic-version": ANTHROPIC_API_VERSION,
      },
      body: JSON.stringify(anthropicRequest),
    });
  } catch (error) {
    context.error(`[chat] user=${user.email} model=${anthropicRequest.model} upstream unreachable: ${error instanceof Error ? error.message : String(error)}`);
    return errorResponse(502, "model_unreachable", "Could not reach the model provider.");
  }

  if (!upstreamResponse.ok) {
    const upstreamText = await upstreamResponse.text();
    context.warn(`[chat] user=${user.email} model=${anthropicRequest.model} upstream_status=${upstreamResponse.status} ms=${Date.now() - startedAtMs}`);
    // Anthropic error bodies are JSON {type:"error", error:{type,message}} and never echo the key.
    return {
      status: upstreamResponse.status === 429 ? 429 : 502,
      headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
      body: upstreamText,
    };
  }

  context.log(`[chat] user=${user.email} model=${anthropicRequest.model} stream=${anthropicRequest.stream} tools=${anthropicRequest.tools?.length ?? 0} status=${upstreamResponse.status} ms_to_first_byte=${Date.now() - startedAtMs}`);

  if (anthropicRequest.stream) {
    return {
      status: 200,
      headers: {
        "content-type": "text/event-stream; charset=utf-8",
        "cache-control": "no-store",
        "x-wingman-model": anthropicRequest.model,
      },
      body: upstreamResponse.body ?? undefined,
    };
  }
  return {
    status: 200,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-wingman-model": anthropicRequest.model,
    },
    body: await upstreamResponse.text(),
  };
}

app.http("chat", {
  methods: ["POST"],
  authLevel: "anonymous", // the Entra bearer check in authenticateRequest is the gate, not a function key
  route: "chat",
  handler: chatHandler,
});
