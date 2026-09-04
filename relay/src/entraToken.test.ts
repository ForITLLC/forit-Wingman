import { test } from "node:test";
import assert from "node:assert/strict";
import { evaluateEntraClaims, EntraTokenError, type EntraJwtClaims } from "./entraToken.js";

const rules = {
  tenantId: "c0efa09e-4bda-4a9d-a177-4c77076b7f76",
  clientId: "36021471-d468-4f12-9c83-e5a73f957752",
  allowedEmailDomains: ["forit.io"],
};
const now = 1_800_000_000;

function validClaims(overrides: Partial<EntraJwtClaims> = {}): EntraJwtClaims {
  return {
    iss: `https://login.microsoftonline.com/${rules.tenantId}/v2.0`,
    aud: rules.clientId,
    tid: rules.tenantId,
    oid: "11111111-2222-3333-4444-555555555555",
    exp: now + 600,
    nbf: now - 60,
    name: "Support Person",
    preferred_username: "Support.Person@forit.io",
    ...overrides,
  };
}

function reasonOf(claims: EntraJwtClaims): string {
  try {
    evaluateEntraClaims(claims, rules, now);
    return "accepted";
  } catch (error) {
    if (error instanceof EntraTokenError) return error.reason;
    throw error;
  }
}

test("a ForIT id_token for the Wingman client is accepted with a lower-cased email", () => {
  const user = evaluateEntraClaims(validClaims(), rules, now);
  assert.equal(user.email, "support.person@forit.io");
  assert.equal(user.entraObjectId, "11111111-2222-3333-4444-555555555555");
  assert.equal(user.displayName, "Support Person");
});

test("a token issued for another application is rejected", () => {
  assert.equal(reasonOf(validClaims({ aud: "00000000-0000-0000-0000-000000000000" })), "wrong_audience");
});

test("a token from another tenant is rejected on issuer before anything else", () => {
  assert.equal(reasonOf(validClaims({ iss: "https://login.microsoftonline.com/other-tenant/v2.0" })), "wrong_issuer");
});

test("an expired token is rejected", () => {
  assert.equal(reasonOf(validClaims({ exp: now - 120 })), "expired");
});

test("a non-forit.io account is rejected even with a valid ForIT token", () => {
  assert.equal(reasonOf(validClaims({ preferred_username: "someone@greatnorthairlines.com" })), "domain_not_allowed");
});

test("a look-alike domain is not accepted by suffix matching", () => {
  assert.equal(reasonOf(validClaims({ preferred_username: "someone@notforit.io" })), "domain_not_allowed");
});

test("a token with no email-bearing claim is rejected", () => {
  assert.equal(reasonOf(validClaims({ preferred_username: undefined })), "no_email_claim");
});

test("the email claim is used when preferred_username is absent", () => {
  const user = evaluateEntraClaims(validClaims({ preferred_username: undefined, email: "b.thomas@forit.io" }), rules, now);
  assert.equal(user.email, "b.thomas@forit.io");
});
