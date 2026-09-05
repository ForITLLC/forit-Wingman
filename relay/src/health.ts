/**
 * GET /api/health — anonymous liveness and configuration report.
 *
 * The deploy workflow asserts `version` equals the commit it shipped and that `chatConfigured` is
 * true, so a deploy whose Key Vault reference did not resolve fails the pipeline instead of
 * failing the first user. No secret material is ever included.
 */
import { app, type HttpRequest, type HttpResponseInit, type InvocationContext } from "@azure/functions";
import { getRelayConfig } from "./config.js";
import { jsonResponse } from "./http.js";

async function healthHandler(_request: HttpRequest, _context: InvocationContext): Promise<HttpResponseInit> {
  const config = getRelayConfig();
  return jsonResponse(200, {
    ok: true,
    service: "wingman-relay",
    version: config.relayVersion,
    modelProvider: config.modelProvider,
    defaultModel: config.defaultModel,
    allowedModels: config.allowedModels,
    chatConfigured: Boolean(config.anthropicApiKey),
    ttsConfigured: Boolean(config.elevenLabsApiKey && config.elevenLabsVoiceId),
    usageRecording: config.usageRecordingEnabled && Boolean(config.usageStorageConnectionString),
    entraTenantId: config.entraTenantId,
    entraClientId: config.entraClientId,
    allowedEmailDomains: config.allowedEmailDomains,
  });
}

app.http("health", {
  methods: ["GET"],
  authLevel: "anonymous",
  route: "health",
  handler: healthHandler,
});
