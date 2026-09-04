/**
 * Shared HTTP helpers: JSON responses, the bearer-token gate every authenticated route uses, and
 * one log line per request that names the user (never the token).
 */
import type { HttpRequest, HttpResponseInit, InvocationContext } from "@azure/functions";
import { getRelayConfig } from "./config.js";
import { EntraTokenError, verifyEntraToken, type VerifiedUser } from "./entraToken.js";

export function jsonResponse(status: number, body: unknown, extraHeaders: Record<string, string> = {}): HttpResponseInit {
  return {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...extraHeaders },
    body: JSON.stringify(body),
  };
}

export function errorResponse(status: number, errorCode: string, message: string): HttpResponseInit {
  return jsonResponse(status, { error: errorCode, message });
}

export type AuthenticationOutcome = { user: VerifiedUser } | { response: HttpResponseInit };

/**
 * Resolves the signed-in user from `Authorization: Bearer <Entra id_token>`, or returns the 401
 * the route should send. The 401 body names a stable reason so the app can decide between
 * "sign in again" (expired, wrong_audience) and "this account cannot use Wingman"
 * (domain_not_allowed).
 */
export async function authenticateRequest(request: HttpRequest, context: InvocationContext): Promise<AuthenticationOutcome> {
  const config = getRelayConfig();
  const authorizationHeader = request.headers.get("authorization") ?? "";
  if (!authorizationHeader.toLowerCase().startsWith("bearer ")) {
    return { response: errorResponse(401, "missing_bearer_token", "Sign in to Wingman and retry.") };
  }
  const token = authorizationHeader.slice("bearer ".length).trim();
  try {
    const user = await verifyEntraToken(token, {
      tenantId: config.entraTenantId,
      clientId: config.entraClientId,
      allowedEmailDomains: config.allowedEmailDomains,
    });
    return { user };
  } catch (error) {
    if (error instanceof EntraTokenError) {
      context.warn(`[auth] rejected route=${new URL(request.url).pathname} reason=${error.reason}: ${error.message}`);
      return { response: errorResponse(401, error.reason, error.message) };
    }
    context.error(`[auth] verification failed unexpectedly: ${error instanceof Error ? error.message : String(error)}`);
    return { response: errorResponse(503, "auth_unavailable", "Could not verify the sign-in token right now.") };
  }
}

export async function readJsonBody<T>(request: HttpRequest): Promise<T | undefined> {
  try {
    return (await request.json()) as T;
  } catch {
    return undefined;
  }
}
