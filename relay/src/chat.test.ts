import { test } from "node:test";
import assert from "node:assert/strict";
import { buildAnthropicRequest, ChatRequestError, resolveModel } from "./chat.js";
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
  assert.equal(anthropicRequest.system, "You are Wingman.");
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
