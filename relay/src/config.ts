/**
 * Relay configuration, read once from the Function App's environment.
 *
 * Secrets (ANTHROPIC_API_KEY, ELEVENLABS_API_KEY) arrive as Key Vault references resolved by
 * App Service before the worker starts: the values live in kv-forit-wingman and never in this
 * repo, in GitHub secrets, or in the desktop app. See ../infra/main.bicep.
 */

export interface RelayConfig {
  /** Entra tenant whose tokens the relay accepts. ForIT only. */
  entraTenantId: string;
  /** Application (client) id of the "ForIT Wingman" public client. id_tokens carry it as `aud`. */
  entraClientId: string;
  /** Lower-case email domains allowed to use the relay. Interim rule from docs/PERMISSIONS.md 5.1. */
  allowedEmailDomains: string[];
  /** Which model vendor `/api/chat` talks to. Only "anthropic" exists today. */
  modelProvider: "anthropic";
  /** Model ids the desktop app may request. Anything else is replaced by the default. */
  allowedModels: string[];
  defaultModel: string;
  anthropicApiKey: string | undefined;
  elevenLabsApiKey: string | undefined;
  elevenLabsVoiceId: string | undefined;
  /** Git sha baked in at deploy time; /api/health reports it so the pipeline can prove what is live. */
  relayVersion: string;
}

const FORIT_TENANT_ID = "c0efa09e-4bda-4a9d-a177-4c77076b7f76";

function splitCommaSeparatedList(rawValue: string | undefined, fallback: string[]): string[] {
  if (!rawValue || rawValue.trim() === "") return fallback;
  return rawValue
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

function emptyToUndefined(rawValue: string | undefined): string | undefined {
  if (!rawValue || rawValue.trim() === "") return undefined;
  // An unresolved Key Vault reference is left verbatim in the setting by App Service. Treat it as
  // "not configured" rather than sending "@Microsoft.KeyVault(...)" upstream as an API key.
  if (rawValue.startsWith("@Microsoft.KeyVault(")) return undefined;
  return rawValue;
}

export function loadRelayConfig(environment: NodeJS.ProcessEnv = process.env): RelayConfig {
  const allowedModels = splitCommaSeparatedList(environment.WINGMAN_ALLOWED_MODELS, [
    "claude-sonnet-5",
    "claude-opus-5",
  ]);
  const defaultModel = environment.WINGMAN_DEFAULT_MODEL?.trim() || allowedModels[0];
  return {
    entraTenantId: environment.WINGMAN_ENTRA_TENANT_ID?.trim() || FORIT_TENANT_ID,
    entraClientId: environment.WINGMAN_ENTRA_CLIENT_ID?.trim() || "",
    allowedEmailDomains: splitCommaSeparatedList(environment.WINGMAN_ALLOWED_EMAIL_DOMAINS, ["forit.io"]).map(
      (domain) => domain.toLowerCase(),
    ),
    modelProvider: "anthropic",
    allowedModels,
    defaultModel,
    anthropicApiKey: emptyToUndefined(environment.ANTHROPIC_API_KEY),
    elevenLabsApiKey: emptyToUndefined(environment.ELEVENLABS_API_KEY),
    elevenLabsVoiceId: emptyToUndefined(environment.ELEVENLABS_VOICE_ID),
    relayVersion: environment.RELAY_VERSION?.trim() || "unknown",
  };
}

let cachedRelayConfig: RelayConfig | undefined;

export function getRelayConfig(): RelayConfig {
  if (!cachedRelayConfig) cachedRelayConfig = loadRelayConfig();
  return cachedRelayConfig;
}
