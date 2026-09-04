/**
 * Entra ID token verification for the Wingman relay.
 *
 * The desktop app signs the user in with the "ForIT Wingman" public client (PKCE) and sends the
 * resulting id_token as `Authorization: Bearer`. The relay proves, on every request:
 *   - the token was signed by the ForIT tenant (RS256 against the tenant JWKS),
 *   - it was issued for the Wingman client (`aud` = client id),
 *   - it is inside its validity window,
 *   - the user's email domain is on the allow-list (docs/PERMISSIONS.md 5.1, interim).
 *
 * Nothing in the request other than the signed token identifies the user. Headers such as
 * X-User-Email are never read.
 *
 * `evaluateEntraClaims` is a pure function so the claim rules are unit-tested without network;
 * `verifyEntraToken` adds the signature check.
 */
import { createPublicKey, createVerify, type JsonWebKey } from "node:crypto";

export interface EntraJwtHeader {
  alg?: string;
  kid?: string;
  typ?: string;
}

export interface EntraJwtClaims {
  iss?: string;
  aud?: string | string[];
  exp?: number;
  nbf?: number;
  iat?: number;
  tid?: string;
  oid?: string;
  sub?: string;
  name?: string;
  preferred_username?: string;
  email?: string;
  upn?: string;
}

export interface VerifiedUser {
  email: string;
  entraObjectId: string;
  displayName: string;
}

export interface EntraClaimRules {
  tenantId: string;
  clientId: string;
  allowedEmailDomains: string[];
}

export class EntraTokenError extends Error {
  constructor(
    message: string,
    /** Stable machine-readable reason returned to the app in the 401 body. */
    public readonly reason: string,
  ) {
    super(message);
    this.name = "EntraTokenError";
  }
}

const CLOCK_SKEW_SECONDS = 60;

function base64UrlDecode(segment: string): Buffer {
  const padding = "=".repeat((4 - (segment.length % 4)) % 4);
  return Buffer.from((segment + padding).replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

export function decodeEntraTokenUnverified(token: string): {
  header: EntraJwtHeader;
  claims: EntraJwtClaims;
  signedPortion: string;
  signature: Buffer;
} {
  const segments = token.split(".");
  if (segments.length !== 3) throw new EntraTokenError("token is not a compact JWS", "malformed_token");
  let header: EntraJwtHeader;
  let claims: EntraJwtClaims;
  try {
    header = JSON.parse(base64UrlDecode(segments[0]).toString("utf8")) as EntraJwtHeader;
    claims = JSON.parse(base64UrlDecode(segments[1]).toString("utf8")) as EntraJwtClaims;
  } catch {
    throw new EntraTokenError("token segments are not JSON", "malformed_token");
  }
  return {
    header,
    claims,
    signedPortion: `${segments[0]}.${segments[1]}`,
    signature: base64UrlDecode(segments[2]),
  };
}

/**
 * Applies every rule that does not need the signature. Throws EntraTokenError on the first
 * violation so callers get one precise reason.
 */
export function evaluateEntraClaims(
  claims: EntraJwtClaims,
  rules: EntraClaimRules,
  nowEpochSeconds: number = Math.floor(Date.now() / 1000),
): VerifiedUser {
  const expectedIssuers = [
    `https://login.microsoftonline.com/${rules.tenantId}/v2.0`,
    `https://sts.windows.net/${rules.tenantId}/`,
  ];
  if (!claims.iss || !expectedIssuers.includes(claims.iss)) {
    throw new EntraTokenError(`issuer ${claims.iss ?? "(none)"} is not the ForIT tenant`, "wrong_issuer");
  }
  if (claims.tid && claims.tid !== rules.tenantId) {
    throw new EntraTokenError(`tenant ${claims.tid} is not the ForIT tenant`, "wrong_tenant");
  }

  const audiences = Array.isArray(claims.aud) ? claims.aud : claims.aud ? [claims.aud] : [];
  if (!rules.clientId || !audiences.includes(rules.clientId)) {
    throw new EntraTokenError("token was not issued for the Wingman client", "wrong_audience");
  }

  if (typeof claims.exp !== "number") throw new EntraTokenError("token has no expiry", "malformed_token");
  if (claims.exp < nowEpochSeconds - CLOCK_SKEW_SECONDS) throw new EntraTokenError("token expired", "expired");
  if (typeof claims.nbf === "number" && claims.nbf > nowEpochSeconds + CLOCK_SKEW_SECONDS) {
    throw new EntraTokenError("token not yet valid", "not_yet_valid");
  }

  const rawEmail = claims.preferred_username || claims.email || claims.upn;
  if (!rawEmail || !rawEmail.includes("@")) {
    throw new EntraTokenError("token carries no email claim", "no_email_claim");
  }
  const email = rawEmail.toLowerCase();
  const emailDomain = email.slice(email.lastIndexOf("@") + 1);
  if (!rules.allowedEmailDomains.includes(emailDomain)) {
    throw new EntraTokenError(`${emailDomain} is not an allowed domain`, "domain_not_allowed");
  }
  if (!claims.oid) throw new EntraTokenError("token carries no object id", "no_object_id");

  return { email, entraObjectId: claims.oid, displayName: claims.name || email };
}

// --- JWKS -----------------------------------------------------------------------------------

interface JwksCacheEntry {
  keysByKeyId: Map<string, JsonWebKey>;
  fetchedAtMs: number;
}

const JWKS_CACHE_TTL_MS = 60 * 60 * 1000;
const jwksCacheByTenant = new Map<string, JwksCacheEntry>();

async function fetchTenantSigningKeys(tenantId: string, forceRefresh: boolean): Promise<Map<string, JsonWebKey>> {
  const cached = jwksCacheByTenant.get(tenantId);
  if (cached && !forceRefresh && Date.now() - cached.fetchedAtMs < JWKS_CACHE_TTL_MS) {
    return cached.keysByKeyId;
  }
  const response = await fetch(`https://login.microsoftonline.com/${tenantId}/discovery/v2.0/keys`);
  if (!response.ok) throw new Error(`JWKS fetch failed: HTTP ${response.status}`);
  const body = (await response.json()) as { keys: Array<JsonWebKey & { kid?: string }> };
  const keysByKeyId = new Map<string, JsonWebKey>();
  for (const key of body.keys) {
    if (key.kid) keysByKeyId.set(key.kid, key);
  }
  jwksCacheByTenant.set(tenantId, { keysByKeyId, fetchedAtMs: Date.now() });
  return keysByKeyId;
}

/** Full verification: signature against the tenant JWKS, then every claim rule. */
export async function verifyEntraToken(token: string, rules: EntraClaimRules): Promise<VerifiedUser> {
  const decoded = decodeEntraTokenUnverified(token);
  if (decoded.header.alg !== "RS256") {
    throw new EntraTokenError(`unsupported signing algorithm ${decoded.header.alg}`, "unsupported_algorithm");
  }
  if (!decoded.header.kid) throw new EntraTokenError("token header has no kid", "malformed_token");

  // Claims first: a cheap reject (wrong audience, expired) never costs a JWKS fetch.
  const user = evaluateEntraClaims(decoded.claims, rules);

  let signingKeys = await fetchTenantSigningKeys(rules.tenantId, false);
  let jwk = signingKeys.get(decoded.header.kid);
  if (!jwk) {
    // Entra rotates keys; one forced refresh covers a kid we have not seen yet.
    signingKeys = await fetchTenantSigningKeys(rules.tenantId, true);
    jwk = signingKeys.get(decoded.header.kid);
  }
  if (!jwk) throw new EntraTokenError("token signed by an unknown key", "unknown_signing_key");

  const publicKey = createPublicKey({ key: jwk, format: "jwk" });
  const verifier = createVerify("RSA-SHA256");
  verifier.update(decoded.signedPortion);
  verifier.end();
  if (!verifier.verify(publicKey, decoded.signature)) {
    throw new EntraTokenError("signature verification failed", "bad_signature");
  }
  return user;
}
