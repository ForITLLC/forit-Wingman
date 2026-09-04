/**
 * POST /api/chat — authenticated passthrough to the Anthropic Messages API.
 *
 * The desktop app sends the same shape it would send to Anthropic (system, messages with text and
 * image blocks, max_tokens, stream). The relay adds the vendor key, pins the model to the
 * allow-list, and streams the SSE body straight back. It stores nothing: no prompts, no
 * screenshots, no completions. One log line per call records who, which model, and the status.
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

export interface WingmanChatTextBlock {
  type: "text";
  text: string;
}

export interface WingmanChatImageBlock {
  type: "image";
  source: { type: "base64"; media_type: string; data: string };
}

export interface WingmanChatMessage {
  role: "user" | "assistant";
  content: string | Array<WingmanChatTextBlock | WingmanChatImageBlock>;
}

export interface WingmanChatRequest {
  model?: string;
  system?: string;
  messages?: WingmanChatMessage[];
  max_tokens?: number;
  temperature?: number;
  stream?: boolean;
}

export interface AnthropicMessagesRequest {
  model: string;
  system?: string;
  messages: WingmanChatMessage[];
  max_tokens: number;
  temperature?: number;
  stream: boolean;
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

function validateContentBlock(block: WingmanChatTextBlock | WingmanChatImageBlock, messageIndex: number): void {
  if (block.type === "text") {
    if (typeof block.text !== "string") throw new ChatRequestError(`messages[${messageIndex}]: text block without text`);
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
    message.content.forEach((block) => validateContentBlock(block, messageIndex));
  });
  if (messages[messages.length - 1].role !== "user") throw new ChatRequestError("the last message must come from the user");

  if (wingmanRequest.system !== undefined && typeof wingmanRequest.system !== "string") {
    throw new ChatRequestError("system must be a string");
  }

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
  return anthropicRequest;
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

  context.log(`[chat] user=${user.email} model=${anthropicRequest.model} stream=${anthropicRequest.stream} status=${upstreamResponse.status} ms_to_first_byte=${Date.now() - startedAtMs}`);

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
