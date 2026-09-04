import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizeTtsText, TtsRequestError } from "./tts.js";

test("text is trimmed and returned", () => {
  assert.equal(normalizeTtsText({ text: "  Ticket 42 is waiting on the client.  " }), "Ticket 42 is waiting on the client.");
});

test("empty and over-long text are refused", () => {
  assert.throws(() => normalizeTtsText({ text: "   " }), TtsRequestError);
  assert.throws(() => normalizeTtsText({ text: "x".repeat(2001) }), /limited to 2000/);
  assert.throws(() => normalizeTtsText({}), TtsRequestError);
});
