import { test } from "node:test";
import assert from "node:assert/strict";
import { buildAnthropicRequest, ChatRequestError, resolveModel, withPromptCacheBreakpoint } from "./chat.js";
import { loadRelayConfig } from "./config.js";

const modelConfig = { allowedModels: ["claude-sonnet-5", "claude-opus-5"], defaultModel: "claude-sonnet-5" };

test("an allowed model is honoured and anything else falls back to the default", () => {
  assert.equal(resolveModel("claude-opus-5", modelConfig), "claude-opus-5");
  assert.equal(resolveModel("claude-3-haiku-20240307", modelConfig), "claude-sonnet-5");
  assert.equal(resolveModel(undefined, modelConfig), "claude-sonnet-5");
});

test("a text plus screenshot request is forwarded with stream on and max_tokens capped", () => {
  const anthropicRequest = buildAnthropicRequest(
    {
      model: "claude-sonnet-5",
      system: "You are Wingman.",
      max_tokens: 999_999,
      messages: [
        {
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: "image/png", data: "iVBORw0KGgo=" } },
            { type: "text", text: "What is on my screen?" },
          ],
        },
      ],
    },
    modelConfig,
  );
  assert.equal(anthropicRequest.model, "claude-sonnet-5");
  assert.deepEqual(anthropicRequest.system, [{ type: "text", text: "You are Wingman.", cache_control: { type: "ephemeral" } }]);
  const screenshotMessageContent = anthropicRequest.messages[0].content;
  assert.ok(Array.isArray(screenshotMessageContent));
  assert.deepEqual(screenshotMessageContent[0], { type: "image", source: { type: "base64", media_type: "image/png", data: "iVBORw0KGgo=" } });
  assert.deepEqual(screenshotMessageContent[1], { type: "text", text: "What is on my screen?", cache_control: { type: "ephemeral" } });
  assert.equal(anthropicRequest.max_tokens, 4096);
  assert.equal(anthropicRequest.stream, true);
});

test("the conversation must end with a user turn", () => {
  assert.throws(
    () =>
      buildAnthropicRequest(
        { messages: [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }] },
        modelConfig,
      ),
    ChatRequestError,
  );
});

test("unsupported image media types are refused before reaching the vendor", () => {
  assert.throws(
    () =>
      buildAnthropicRequest(
        {
          messages: [
            { role: "user", content: [{ type: "image", source: { type: "base64", media_type: "image/tiff", data: "AAAA" } }] },
          ],
        },
        modelConfig,
      ),
    /unsupported image media type/,
  );
});

test("an empty message list is refused", () => {
  assert.throws(() => buildAnthropicRequest({ messages: [] }, modelConfig), /non-empty/);
});

test("an unresolved Key Vault reference is treated as no key, never sent upstream", () => {
  const config = loadRelayConfig({
    ANTHROPIC_API_KEY: "@Microsoft.KeyVault(SecretUri=https://kv-forit-wingman.vault.azure.net/secrets/anthropic-api-key/)",
  } as NodeJS.ProcessEnv);
  assert.equal(config.anthropicApiKey, undefined);
  assert.deepEqual(config.allowedEmailDomains, ["forit.io"]);
  assert.equal(config.defaultModel, "claude-sonnet-5");
});

test("tool definitions and a tool round trip are forwarded unchanged", () => {
  const anthropicRequest = buildAnthropicRequest(
    {
      tools: [
        {
          name: "support_listTickets",
          description: "List tickets.",
          input_schema: { type: "object", properties: { tenant: { type: "string" } } },
        },
      ],
      tool_choice: { type: "auto" },
      messages: [
        { role: "user", content: "what is open for great north?" },
        {
          role: "assistant",
          content: [
            { type: "text", text: "let me look." },
            { type: "tool_use", id: "toolu_01", name: "support_listTickets", input: { tenant: "gna", status: "active" } },
          ],
        },
        {
          role: "user",
          content: [{ type: "tool_result", tool_use_id: "toolu_01", content: '{"tickets":[]}' }],
        },
      ],
    },
    modelConfig,
  );
  assert.equal(anthropicRequest.tools?.length, 1);
  assert.equal(anthropicRequest.tools?.[0].name, "support_listTickets");
  assert.deepEqual(anthropicRequest.tool_choice, { type: "auto" });
  assert.equal(anthropicRequest.messages.length, 3);
});

test("a tool_use block in a user turn and a tool_result in an assistant turn are refused", () => {
  assert.throws(
    () =>
      buildAnthropicRequest(
        {
          messages: [
            { role: "user", content: [{ type: "tool_use", id: "toolu_01", name: "support_listTickets", input: {} }] },
          ],
        },
        modelConfig,
      ),
    /tool_use blocks belong to assistant turns/,
  );
  assert.throws(
    () =>
      buildAnthropicRequest(
        {
          messages: [
            { role: "user", content: "hi" },
            { role: "assistant", content: [{ type: "tool_result", tool_use_id: "toolu_01", content: "x" }] },
            { role: "user", content: "and?" },
          ],
        },
        modelConfig,
      ),
    /tool_result blocks belong to user turns/,
  );
});

test("tool definitions must be well formed and tool_choice must name a known tool", () => {
  assert.throws(
    () =>
      buildAnthropicRequest(
        { tools: [{ name: "bad name!", input_schema: { type: "object" } }], messages: [{ role: "user", content: "hi" }] },
        modelConfig,
      ),
    /name must match/,
  );
  assert.throws(
    () =>
      buildAnthropicRequest(
        { tools: [{ name: "support_listTickets", input_schema: { type: "array" } as never }], messages: [{ role: "user", content: "hi" }] },
        modelConfig,
      ),
    /input_schema must be a JSON schema of type object/,
  );
  assert.throws(
    () =>
      buildAnthropicRequest(
        {
          tools: [{ name: "support_listTickets", input_schema: { type: "object" } }],
          tool_choice: { type: "tool", name: "support_deleteTicket" },
          messages: [{ role: "user", content: "hi" }],
        },
        modelConfig,
      ),
    /not in tools/,
  );
  assert.throws(
    () => buildAnthropicRequest({ tool_choice: { type: "auto" }, messages: [{ role: "user", content: "hi" }] }, modelConfig),
    /tool_choice requires tools/,
  );
});

test("an oversized tool_result is refused before reaching the vendor", () => {
  assert.throws(
    () =>
      buildAnthropicRequest(
        {
          messages: [
            { role: "user", content: "hi" },
            { role: "assistant", content: [{ type: "tool_use", id: "toolu_01", name: "support_listTickets", input: {} }] },
            { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_01", content: "x".repeat(64 * 1024 + 1) }] },
          ],
        },
        modelConfig,
      ),
    /exceeds the relay size limit/,
  );
});

test("tool_choice none is accepted so the app can force a spoken answer after the tool cap", () => {
  const anthropicRequest = buildAnthropicRequest(
    {
      tools: [{ name: "support_listTickets", input_schema: { type: "object" } }],
      tool_choice: { type: "none" },
      messages: [{ role: "user", content: "hi" }],
    },
    modelConfig,
  );
  assert.deepEqual(anthropicRequest.tool_choice, { type: "none" });
});

test("the cache breakpoint lands on the last block of the last user turn and never mutates the caller's messages", () => {
  const toolResultTurn: Parameters<typeof withPromptCacheBreakpoint>[0][number] = {
    role: "user",
    content: [{ type: "tool_result", tool_use_id: "toolu_01", content: '{"tickets":[]}' }],
  };
  const original = [{ role: "user" as const, content: "what is open?" }, { role: "assistant" as const, content: "let me look." }, toolResultTurn];
  const marked = withPromptCacheBreakpoint(original);
  assert.deepEqual(marked[0], { role: "user", content: "what is open?" });
  assert.deepEqual(marked[1], { role: "assistant", content: "let me look." });
  assert.deepEqual(marked[2], {
    role: "user",
    content: [{ type: "tool_result", tool_use_id: "toolu_01", content: '{"tickets":[]}', cache_control: { type: "ephemeral" } }],
  });
  assert.deepEqual(toolResultTurn.content, [{ type: "tool_result", tool_use_id: "toolu_01", content: '{"tickets":[]}' }]);

  const plainString = withPromptCacheBreakpoint([{ role: "user", content: "hi" }]);
  assert.deepEqual(plainString[0], { role: "user", content: [{ type: "text", text: "hi", cache_control: { type: "ephemeral" } }] });

  const emptyText = withPromptCacheBreakpoint([{ role: "user", content: [{ type: "text", text: "   " }] }]);
  assert.deepEqual(emptyText[0], { role: "user", content: [{ type: "text", text: "   " }] });
});
