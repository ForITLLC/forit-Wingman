import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { loadRelayConfig } from "./config.js";
import type { VerifiedUser } from "./entraToken.js";
import {
  buildUsageEntity,
  MAX_USAGE_ANSWER_CHARACTERS,
  MAX_USAGE_TOOL_CALLS,
  parseStorageConnectionString,
  processUsageReport,
  tableSharedKeyLiteAuthorization,
  TableUsageStore,
  UsageReportError,
  type UsageStore,
  type WingmanUsageEntity,
} from "./usage.js";

const signedInPerson: VerifiedUser = { email: "c.example@forit.io", displayName: "Christine Example", entraObjectId: "0b1d-oid" };
const receivedAt = new Date("2026-09-05T19:45:12.345Z");

const spokenTurn = {
  turnId: "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
  askedAt: "2026-09-05T19:45:03.000Z",
  appVersion: "0.1.58",
  model: "claude-sonnet-5",
  question: "how do I add a crew member to a flight in FL3XX",
  answer: "open the flight, then the crew tab, and pick the person from the roster.",
  toolCalls: [
    { name: "support_searchKbArticles", searchTerms: "crew member flight", outcome: "ok" },
    { name: "support_getKbArticle", outcome: "ok" },
  ],
  modelRounds: 3,
  timings: { listeningMs: 2100, firstModelTextMs: 3020, firstSpeechMs: 5610, answerCompleteMs: 9800, totalMs: 14400.4 },
  outcome: "answered",
  pointed: true,
};

const silentLog = { log() {}, warn() {}, error() {} };

class RecordingStore implements UsageStore {
  saved: WingmanUsageEntity[] = [];
  async save(entity: WingmanUsageEntity): Promise<void> {
    this.saved.push(entity);
  }
}

test("a spoken turn becomes one row keyed by day and arrival time, attributed from the token", () => {
  const entity = buildUsageEntity(spokenTurn, signedInPerson, receivedAt);
  assert.equal(entity.partitionKey, "2026-09-05");
  assert.equal(entity.rowKey, "2026-09-05T19:45:12.345Z_3F2504E0-4F89-11D3-9A0C-0305E82C3301");
  assert.equal(entity.userEmail, "c.example@forit.io");
  assert.equal(entity.userDisplayName, "Christine Example");
  assert.equal(entity.userObjectId, "0b1d-oid");
  assert.equal(entity.askedAt, "2026-09-05T19:45:03.000Z");
  assert.equal(entity.question, spokenTurn.question);
  assert.equal(entity.answer, spokenTurn.answer);
  assert.equal(entity.toolNames, "support_searchKbArticles,support_getKbArticle");
  assert.equal(entity.toolCallCount, 2);
  assert.deepEqual(JSON.parse(entity.toolCalls), spokenTurn.toolCalls);
  assert.equal(entity.modelRounds, 3);
  assert.equal(entity.outcome, "answered");
  assert.equal(entity.pointed, true);
  assert.equal(entity.totalMs, 14400);
  assert.equal(entity.firstSpeechMs, 5610);
});

test("identity in the body is ignored and unknown fields are dropped", () => {
  const entity = buildUsageEntity(
    { ...spokenTurn, userEmail: "someone.else@forit.io", screenshot: "iVBORw0KGgo=", timings: { totalMs: 10, cpuTemperature: 99 } },
    signedInPerson,
    receivedAt,
  );
  assert.equal(entity.userEmail, "c.example@forit.io");
  assert.equal("screenshot" in entity, false);
  assert.equal("cpuTemperature" in entity, false);
  assert.equal(entity.totalMs, 10);
});

test("a report without tool calls, timings or an answer is still a row", () => {
  const entity = buildUsageEntity(
    { turnId: "t-1", askedAt: "2026-09-05T19:45:03Z", appVersion: "0.1.58", model: "claude-sonnet-5", question: "hello", answer: "", outcome: "interrupted" },
    signedInPerson,
    receivedAt,
  );
  assert.equal(entity.toolCalls, "[]");
  assert.equal(entity.toolNames, "");
  assert.equal(entity.modelRounds, 0);
  assert.equal(entity.pointed, false);
  assert.equal(entity.totalMs, undefined);
});

test("oversized or malformed reports are refused with a reason", () => {
  const expectRefusal = (report: unknown, messagePart: string) => {
    assert.throws(() => buildUsageEntity(report, signedInPerson, receivedAt), (error: unknown) => error instanceof UsageReportError && error.message.includes(messagePart));
  };
  expectRefusal("not an object", "JSON object");
  expectRefusal({ ...spokenTurn, question: "" }, "question must not be empty");
  expectRefusal({ ...spokenTurn, answer: "x".repeat(MAX_USAGE_ANSWER_CHARACTERS + 1) }, "answer exceeds");
  expectRefusal({ ...spokenTurn, turnId: "has/slash" }, "turnId must match");
  expectRefusal({ ...spokenTurn, askedAt: "yesterday" }, "askedAt must be an ISO 8601 date");
  expectRefusal({ ...spokenTurn, outcome: "great" }, "outcome must be one of");
  expectRefusal({ ...spokenTurn, modelRounds: 11 }, "modelRounds must be an integer");
  expectRefusal({ ...spokenTurn, toolCalls: [{ name: "support tickets", outcome: "ok" }] }, "toolCalls[0].name");
  expectRefusal({ ...spokenTurn, toolCalls: [{ name: "support_listTickets", outcome: "maybe" }] }, "toolCalls[0].outcome");
  expectRefusal({ ...spokenTurn, toolCalls: Array.from({ length: MAX_USAGE_TOOL_CALLS + 1 }, () => ({ name: "support_listTickets", outcome: "ok" })) }, "toolCalls is limited");
  expectRefusal({ ...spokenTurn, timings: { totalMs: -1 } }, "timings.totalMs");
  expectRefusal({ ...spokenTurn, model: "a model name with\nnewline" }, "model must be short printable ASCII");
});

test("recording off acknowledges the report and stores nothing", async () => {
  const store = new RecordingStore();
  const response = await processUsageReport({
    body: spokenTurn,
    user: signedInPerson,
    config: { usageRecordingEnabled: false },
    store,
    receivedAt,
    log: silentLog,
  });
  assert.equal(response.status, 202);
  assert.deepEqual(JSON.parse(String(response.body)), { stored: false, reason: "recording_off" });
  assert.equal(store.saved.length, 0);
});

test("recording on stores the row and says so", async () => {
  const store = new RecordingStore();
  const response = await processUsageReport({
    body: spokenTurn,
    user: signedInPerson,
    config: { usageRecordingEnabled: true },
    store,
    receivedAt,
    log: silentLog,
  });
  assert.equal(response.status, 202);
  assert.deepEqual(JSON.parse(String(response.body)), { stored: true });
  assert.equal(store.saved.length, 1);
  assert.equal(store.saved[0].question, spokenTurn.question);
});

test("a bad report is a 400 and a failing store is a 503, neither a crash", async () => {
  const store = new RecordingStore();
  const badReport = await processUsageReport({
    body: { ...spokenTurn, question: 42 },
    user: signedInPerson,
    config: { usageRecordingEnabled: true },
    store,
    receivedAt,
    log: silentLog,
  });
  assert.equal(badReport.status, 400);
  assert.equal(JSON.parse(String(badReport.body)).error, "invalid_usage_report");
  assert.equal(store.saved.length, 0);

  const failingStore: UsageStore = {
    async save() {
      throw new Error("table unreachable");
    },
  };
  const storeDown = await processUsageReport({
    body: spokenTurn,
    user: signedInPerson,
    config: { usageRecordingEnabled: true },
    store: failingStore,
    receivedAt,
    log: silentLog,
  });
  assert.equal(storeDown.status, 503);
  assert.equal(JSON.parse(String(storeDown.body)).error, "usage_store_unavailable");

  const noStore = await processUsageReport({
    body: spokenTurn,
    user: signedInPerson,
    config: { usageRecordingEnabled: true },
    store: undefined,
    receivedAt,
    log: silentLog,
  });
  assert.equal(noStore.status, 503);
  assert.equal(JSON.parse(String(noStore.body)).error, "usage_store_not_configured");
});

test("usage recording is on by default, off on request, and uses the host storage account", () => {
  const defaults = loadRelayConfig({ AzureWebJobsStorage: "DefaultEndpointsProtocol=https;AccountName=stforitwingmanrelay;AccountKey=abc;EndpointSuffix=core.windows.net" });
  assert.equal(defaults.usageRecordingEnabled, true);
  assert.equal(defaults.usageTableName, "wingmanusage");
  assert.match(defaults.usageStorageConnectionString ?? "", /AccountName=stforitwingmanrelay/);

  const switchedOff = loadRelayConfig({ WINGMAN_USAGE_RECORDING: "off" });
  assert.equal(switchedOff.usageRecordingEnabled, false);
  assert.equal(switchedOff.usageStorageConnectionString, undefined);

  const ownAccount = loadRelayConfig({
    AzureWebJobsStorage: "host-account",
    WINGMAN_USAGE_STORAGE_CONNECTION_STRING: "usage-account",
    WINGMAN_USAGE_TABLE: "wingmanusagetest",
  });
  assert.equal(ownAccount.usageStorageConnectionString, "usage-account");
  assert.equal(ownAccount.usageTableName, "wingmanusagetest");
});

const hostConnectionString = "DefaultEndpointsProtocol=https;AccountName=stforitwingmanrelay;AccountKey=c2VjcmV0LWtleQ==;EndpointSuffix=core.windows.net";

test("the host connection string yields the account, its key and the table endpoint", () => {
  const credentials = parseStorageConnectionString(hostConnectionString);
  assert.deepEqual(credentials, {
    accountName: "stforitwingmanrelay",
    accountKey: "c2VjcmV0LWtleQ==",
    tableEndpoint: "https://stforitwingmanrelay.table.core.windows.net",
  });
  const emulator = parseStorageConnectionString("AccountName=devstoreaccount1;AccountKey=a2V5;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1/;");
  assert.equal(emulator.tableEndpoint, "http://127.0.0.1:10002/devstoreaccount1");
  assert.throws(() => parseStorageConnectionString("UseDevelopmentStorage=true"), /AccountName or AccountKey/);
});

test("the Shared Key Lite header signs the date and /<account>/<resource> with the decoded key", () => {
  const credentials = parseStorageConnectionString(hostConnectionString);
  const requestDate = "Sat, 05 Sep 2026 19:45:12 GMT";
  const expectedSignature = createHmac("sha256", Buffer.from("c2VjcmV0LWtleQ==", "base64"))
    .update(`${requestDate}\n/stforitwingmanrelay/wingmanusage`, "utf8")
    .digest("base64");
  assert.equal(tableSharedKeyLiteAuthorization(credentials, requestDate, "/wingmanusage"), `SharedKeyLite stforitwingmanrelay:${expectedSignature}`);
});

test("the table store creates the table once, then inserts rows with PascalCase keys", async () => {
  const requests: { url: string; headers: Record<string, string>; body: Record<string, unknown> }[] = [];
  const fakeFetch = async (url: string, init: { headers: Record<string, string>; body: string }) => {
    requests.push({ url, headers: init.headers, body: JSON.parse(init.body) });
    return { status: url.endsWith("/Tables") ? 409 : 204, async text() { return ""; } };
  };
  const store = new TableUsageStore(hostConnectionString, "wingmanusage", fakeFetch);
  const entity = buildUsageEntity(spokenTurn, signedInPerson, receivedAt);
  await store.save(entity);
  await store.save(entity);

  assert.equal(requests.length, 3);
  assert.equal(requests[0].url, "https://stforitwingmanrelay.table.core.windows.net/Tables");
  assert.deepEqual(requests[0].body, { TableName: "wingmanusage" });
  assert.equal(requests[1].url, "https://stforitwingmanrelay.table.core.windows.net/wingmanusage");
  assert.equal(requests[1].body.PartitionKey, "2026-09-05");
  assert.equal(requests[1].body.RowKey, entity.rowKey);
  assert.equal(requests[1].body.question, spokenTurn.question);
  assert.equal("partitionKey" in requests[1].body, false);
  assert.match(requests[1].headers.authorization, /^SharedKeyLite stforitwingmanrelay:[A-Za-z0-9+/=]+$/);
  assert.equal(requests[1].headers["x-ms-version"], "2019-02-02");
  assert.equal(requests[2].url, requests[1].url);
});

test("a table insert the service refuses surfaces as an error", async () => {
  const failingFetch = async () => ({ status: 403, async text() { return "{\"odata.error\":{\"code\":\"AuthenticationFailed\"}}"; } });
  const store = new TableUsageStore(hostConnectionString, "wingmanusage", failingFetch);
  await assert.rejects(store.save(buildUsageEntity(spokenTurn, signedInPerson, receivedAt)), /table create failed: HTTP 403/);
});
