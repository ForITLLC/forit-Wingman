/**
 * POST /api/tts — authenticated text-to-speech through ElevenLabs.
 *
 * Optional: when ELEVENLABS_API_KEY or ELEVENLABS_VOICE_ID is unset the route answers 501 and the
 * desktop app falls back to on-device speech (AVSpeechSynthesizer). The voice is fixed server-side;
 * the app cannot pick arbitrary voices or models.
 */
import { app, type HttpRequest, type HttpResponseInit, type InvocationContext } from "@azure/functions";
import { getRelayConfig } from "./config.js";
import { authenticateRequest, errorResponse, readJsonBody } from "./http.js";

const ELEVENLABS_MODEL_ID = "eleven_flash_v2_5";
const MAX_TTS_CHARACTERS = 2000;

export interface WingmanTtsRequest {
  text?: string;
}

export class TtsRequestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TtsRequestError";
  }
}

/** Returns the text ElevenLabs will speak, or throws a TtsRequestError safe to show the app. */
export function normalizeTtsText(wingmanRequest: WingmanTtsRequest): string {
  if (typeof wingmanRequest.text !== "string") throw new TtsRequestError("text must be a string");
  const text = wingmanRequest.text.trim();
  if (text.length === 0) throw new TtsRequestError("text is empty");
  if (text.length > MAX_TTS_CHARACTERS) throw new TtsRequestError(`text is limited to ${MAX_TTS_CHARACTERS} characters`);
  return text;
}

async function ttsHandler(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  const authentication = await authenticateRequest(request, context);
  if ("response" in authentication) return authentication.response;
  const { user } = authentication;

  const config = getRelayConfig();
  if (!config.elevenLabsApiKey || !config.elevenLabsVoiceId) {
    return errorResponse(501, "tts_not_configured", "Server-side speech is not configured; use on-device speech.");
  }

  const wingmanRequest = await readJsonBody<WingmanTtsRequest>(request);
  if (!wingmanRequest) return errorResponse(400, "invalid_json", "Request body must be JSON.");
  let text: string;
  try {
    text = normalizeTtsText(wingmanRequest);
  } catch (error) {
    if (error instanceof TtsRequestError) return errorResponse(400, "invalid_request", error.message);
    throw error;
  }

  const startedAtMs = Date.now();
  let upstreamResponse: Response;
  try {
    upstreamResponse = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(config.elevenLabsVoiceId)}?output_format=mp3_44100_128`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "xi-api-key": config.elevenLabsApiKey,
          accept: "audio/mpeg",
        },
        body: JSON.stringify({ text, model_id: ELEVENLABS_MODEL_ID }),
      },
    );
  } catch (error) {
    context.error(`[tts] user=${user.email} upstream unreachable: ${error instanceof Error ? error.message : String(error)}`);
    return errorResponse(502, "tts_unreachable", "Could not reach the speech provider.");
  }

  if (!upstreamResponse.ok) {
    context.warn(`[tts] user=${user.email} upstream_status=${upstreamResponse.status} ms=${Date.now() - startedAtMs}`);
    return errorResponse(502, "tts_failed", `Speech provider answered HTTP ${upstreamResponse.status}.`);
  }

  context.log(`[tts] user=${user.email} chars=${text.length} status=${upstreamResponse.status} ms_to_first_byte=${Date.now() - startedAtMs}`);
  return {
    status: 200,
    headers: { "content-type": "audio/mpeg", "cache-control": "no-store" },
    body: upstreamResponse.body ?? undefined,
  };
}

app.http("tts", {
  methods: ["POST"],
  authLevel: "anonymous", // the Entra bearer check in authenticateRequest is the gate
  route: "tts",
  handler: ttsHandler,
});
