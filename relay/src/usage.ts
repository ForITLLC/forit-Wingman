/**
 * POST /api/usage — one usage report per spoken turn, kept by the relay.
 *
 * Usage sharing is on by default, disclosed in the app's panel before the first question, and the
 * person can turn it off there (.ai/decisions.md 010). When it is on, the app sends one report
 * after each turn: the question, the spoken answer, the model, which tools were called (name and,
 * for a knowledge base search, the keywords), how many model rounds it took and how long each
 * phase lasted. The app never sends the screenshot, the audio, or a tool result, and this route
 * never accepts them: the body is reduced to the fields below and everything else is dropped.
 *
 * The report is stored as one row in an Azure Table (`wingmanusage`) in the relay's own storage
 * account, attributed to the signed-in person from the token the relay verified, never from the
 * body. WINGMAN_USAGE_RECORDING=off makes the route acknowledge and store nothing.
 */
import { app, type HttpRequest, type HttpResponseInit, type InvocationContext } from "@azure/functions";
import { createHmac } from "node:crypto";
import { getRelayConfig, type RelayConfig } from "./config.js";
import type { VerifiedUser } from "./entraToken.js";
import { authenticateRequest, errorResponse, jsonResponse, readJsonBody } from "./http.js";

export const USAGE_TOOL_OUTCOMES = ["ok", "error", "refused"] as const;
export type UsageToolOutcome = (typeof USAGE_TOOL_OUTCOMES)[number];

export const USAGE_TURN_OUTCOMES = ["answered", "failed", "interrupted"] as const;
export type UsageTurnOutcome = (typeof USAGE_TURN_OUTCOMES)[number];

/** The phases the app measures, in milliseconds from the moment the transcript was final. */
export const USAGE_TIMING_KEYS = ["listeningMs", "firstModelTextMs", "firstSpeechMs", "answerCompleteMs", "totalMs"] as const;
export type UsageTimingKey = (typeof USAGE_TIMING_KEYS)[number];

export interface WingmanUsageToolCall {
  name: string;
  /** The keywords sent to the knowledge base search; absent for every other tool. */
  searchTerms?: string;
  outcome: UsageToolOutcome;
}

export type WingmanUsageTimings = Partial<Record<UsageTimingKey, number>>;

/** What the app sends. Anything not listed here is dropped by `buildUsageEntity`. */
export interface WingmanUsageReport {
  turnId: string;
  askedAt: string;
  appVersion: string;
  model: string;
  question: string;
  answer: string;
  toolCalls: WingmanUsageToolCall[];
  modelRounds: number;
  timings: WingmanUsageTimings;
  outcome: UsageTurnOutcome;
  pointed: boolean;
}

/** One row of the `wingmanusage` table. */
export interface WingmanUsageEntity {
  partitionKey: string;
  rowKey: string;
  receivedAt: string;
  askedAt: string;
  turnId: string;
  userEmail: string;
  userDisplayName: string;
  userObjectId: string;
  appVersion: string;
  model: string;
  question: string;
  answer: string;
  /** The tool calls as a JSON array, so the row stays one entity however many there were. */
  toolCalls: string;
  /** Comma-separated tool names, for a query that only needs "which tools". */
  toolNames: string;
  toolCallCount: number;
  modelRounds: number;
  outcome: UsageTurnOutcome;
  pointed: boolean;
  listeningMs?: number;
  firstModelTextMs?: number;
  firstSpeechMs?: number;
  answerCompleteMs?: number;
  totalMs?: number;
}

export const MAX_USAGE_QUESTION_CHARACTERS = 4_000;
export const MAX_USAGE_ANSWER_CHARACTERS = 16_000;
export const MAX_USAGE_TOOL_CALLS = 24;
export const MAX_USAGE_SEARCH_TERMS_CHARACTERS = 200;
export const MAX_USAGE_MODEL_ROUNDS = 10;
export const MAX_USAGE_TIMING_MS = 60 * 60 * 1000;
const TURN_ID_PATTERN = /^[A-Za-z0-9-]{1,64}$/;
const TOOL_NAME_PATTERN = /^[a-zA-Z0-9_-]{1,64}$/;
const SHORT_LABEL_PATTERN = /^[\x20-\x7E]{1,64}$/;

export class UsageReportError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UsageReportError";
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireString(value: unknown, fieldName: string, maximumCharacters: number, allowEmpty = false): string {
  if (typeof value !== "string") throw new UsageReportError(`${fieldName} must be a string`);
  if (!allowEmpty && value.length === 0) throw new UsageReportError(`${fieldName} must not be empty`);
  if (value.length > maximumCharacters) throw new UsageReportError(`${fieldName} exceeds ${maximumCharacters} characters`);
  return value;
}

function requireLabel(value: unknown, fieldName: string): string {
  const label = requireString(value, fieldName, 64);
  if (!SHORT_LABEL_PATTERN.test(label)) throw new UsageReportError(`${fieldName} must be short printable ASCII`);
  return label;
}

function validateToolCalls(value: unknown): WingmanUsageToolCall[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new UsageReportError("toolCalls must be an array");
  if (value.length > MAX_USAGE_TOOL_CALLS) throw new UsageReportError(`toolCalls is limited to ${MAX_USAGE_TOOL_CALLS} entries`);
  return value.map((toolCall, toolCallIndex) => {
    if (!isPlainObject(toolCall)) throw new UsageReportError(`toolCalls[${toolCallIndex}] must be an object`);
    if (typeof toolCall.name !== "string" || !TOOL_NAME_PATTERN.test(toolCall.name)) {
      throw new UsageReportError(`toolCalls[${toolCallIndex}].name must match ${TOOL_NAME_PATTERN}`);
    }
    if (!USAGE_TOOL_OUTCOMES.includes(toolCall.outcome as UsageToolOutcome)) {
      throw new UsageReportError(`toolCalls[${toolCallIndex}].outcome must be one of ${USAGE_TOOL_OUTCOMES.join(", ")}`);
    }
    const validatedToolCall: WingmanUsageToolCall = { name: toolCall.name, outcome: toolCall.outcome as UsageToolOutcome };
    if (toolCall.searchTerms !== undefined) {
      validatedToolCall.searchTerms = requireString(toolCall.searchTerms, `toolCalls[${toolCallIndex}].searchTerms`, MAX_USAGE_SEARCH_TERMS_CHARACTERS, true);
    }
    return validatedToolCall;
  });
}

/** Keeps the known timing keys with sane values; an unknown key is dropped, a bad value rejected. */
function validateTimings(value: unknown): WingmanUsageTimings {
  if (value === undefined) return {};
  if (!isPlainObject(value)) throw new UsageReportError("timings must be an object");
  const timings: WingmanUsageTimings = {};
  for (const timingKey of USAGE_TIMING_KEYS) {
    const timingValue = value[timingKey];
    if (timingValue === undefined || timingValue === null) continue;
    if (typeof timingValue !== "number" || !Number.isFinite(timingValue) || timingValue < 0 || timingValue > MAX_USAGE_TIMING_MS) {
      throw new UsageReportError(`timings.${timingKey} must be a number of milliseconds between 0 and ${MAX_USAGE_TIMING_MS}`);
    }
    timings[timingKey] = Math.round(timingValue);
  }
  return timings;
}

/**
 * Validates the app's report and produces the row to store. Pure, so the rules are unit-tested.
 * The person is taken from the verified token, never from the body. Throws UsageReportError with
 * a message safe to return to the app.
 */
export function buildUsageEntity(body: unknown, user: VerifiedUser, receivedAt: Date): WingmanUsageEntity {
  if (!isPlainObject(body)) throw new UsageReportError("the report must be a JSON object");

  const turnId = requireString(body.turnId, "turnId", 64);
  if (!TURN_ID_PATTERN.test(turnId)) throw new UsageReportError(`turnId must match ${TURN_ID_PATTERN}`);

  const askedAtText = requireString(body.askedAt, "askedAt", 40);
  const askedAt = new Date(askedAtText);
  if (Number.isNaN(askedAt.getTime())) throw new UsageReportError("askedAt must be an ISO 8601 date");

  if (!USAGE_TURN_OUTCOMES.includes(body.outcome as UsageTurnOutcome)) {
    throw new UsageReportError(`outcome must be one of ${USAGE_TURN_OUTCOMES.join(", ")}`);
  }
  const modelRounds = body.modelRounds === undefined ? 0 : body.modelRounds;
  if (typeof modelRounds !== "number" || !Number.isInteger(modelRounds) || modelRounds < 0 || modelRounds > MAX_USAGE_MODEL_ROUNDS) {
    throw new UsageReportError(`modelRounds must be an integer between 0 and ${MAX_USAGE_MODEL_ROUNDS}`);
  }
  if (body.pointed !== undefined && typeof body.pointed !== "boolean") throw new UsageReportError("pointed must be a boolean");

  const toolCalls = validateToolCalls(body.toolCalls);
  const timings = validateTimings(body.timings);
  const receivedAtIso = receivedAt.toISOString();

  return {
    partitionKey: receivedAtIso.slice(0, 10),
    rowKey: `${receivedAtIso}_${turnId}`,
    receivedAt: receivedAtIso,
    askedAt: askedAt.toISOString(),
    turnId,
    userEmail: user.email,
    userDisplayName: user.displayName,
    userObjectId: user.entraObjectId,
    appVersion: requireLabel(body.appVersion, "appVersion"),
    model: requireLabel(body.model, "model"),
    question: requireString(body.question, "question", MAX_USAGE_QUESTION_CHARACTERS),
    answer: requireString(body.answer, "answer", MAX_USAGE_ANSWER_CHARACTERS, true),
    toolCalls: JSON.stringify(toolCalls),
    toolNames: toolCalls.map((toolCall) => toolCall.name).join(","),
    toolCallCount: toolCalls.length,
    modelRounds,
    outcome: body.outcome as UsageTurnOutcome,
    pointed: body.pointed === true,
    ...timings,
  };
}

export interface UsageStore {
  save(entity: WingmanUsageEntity): Promise<void>;
}

export interface StorageAccountCredentials {
  accountName: string;
  /** The base64 account key from the connection string. */
  accountKey: string;
  /** e.g. https://stforitwingmanrelay.table.core.windows.net (no trailing slash). */
  tableEndpoint: string;
}

/**
 * Reads the Functions host's own connection string
 * (`DefaultEndpointsProtocol=https;AccountName=…;AccountKey=…;EndpointSuffix=core.windows.net`,
 * or one carrying an explicit `TableEndpoint=` for a local emulator).
 */
export function parseStorageConnectionString(connectionString: string): StorageAccountCredentials {
  const settings = new Map<string, string>();
  for (const part of connectionString.split(";")) {
    const separatorIndex = part.indexOf("=");
    if (separatorIndex <= 0) continue;
    settings.set(part.slice(0, separatorIndex).trim(), part.slice(separatorIndex + 1).trim());
  }
  const accountName = settings.get("AccountName");
  const accountKey = settings.get("AccountKey");
  if (!accountName || !accountKey) throw new Error("storage connection string lacks AccountName or AccountKey");
  const protocol = settings.get("DefaultEndpointsProtocol") ?? "https";
  const endpointSuffix = settings.get("EndpointSuffix") ?? "core.windows.net";
  const tableEndpoint = (settings.get("TableEndpoint") ?? `${protocol}://${accountName}.table.${endpointSuffix}`).replace(/\/+$/, "");
  return { accountName, accountKey, tableEndpoint };
}

const TABLE_SERVICE_VERSION = "2019-02-02";

/**
 * The Table service's Shared Key Lite signature
 * (https://learn.microsoft.com/rest/api/storageservices/authorize-with-shared-key, "Table service
 * (Shared Key Lite)"): HMAC-SHA256 over the request date and the canonicalized resource
 * ("/<account>/<table or Tables>"), keyed with the decoded account key.
 */
export function tableSharedKeyLiteAuthorization(credentials: StorageAccountCredentials, requestDate: string, resourcePath: string): string {
  const stringToSign = `${requestDate}\n/${credentials.accountName}${resourcePath}`;
  const signature = createHmac("sha256", Buffer.from(credentials.accountKey, "base64")).update(stringToSign, "utf8").digest("base64");
  return `SharedKeyLite ${credentials.accountName}:${signature}`;
}

export type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body: string }) => Promise<{ status: number; text(): Promise<string> }>;

/**
 * Writes rows to an Azure Table over its REST API with the host storage account's own key, so the
 * relay needs neither a new secret nor another SDK. Rows are JSON entities; the service infers
 * String, Int32 and Boolean from the JSON types, which is all a usage row holds.
 */
export class TableUsageStore implements UsageStore {
  private readonly credentials: StorageAccountCredentials;
  private readonly tableName: string;
  private readonly fetchImplementation: FetchLike;
  private tableIsKnownToExist = false;

  constructor(storageConnectionString: string, tableName: string, fetchImplementation: FetchLike = fetch as unknown as FetchLike) {
    this.credentials = parseStorageConnectionString(storageConnectionString);
    this.tableName = tableName;
    this.fetchImplementation = fetchImplementation;
  }

  async save(entity: WingmanUsageEntity): Promise<void> {
    await this.ensureTableExists();
    // The Table service wants the two keys in PascalCase; every other property keeps its name.
    const { partitionKey, rowKey, ...properties } = entity;
    const response = await this.request(`/${this.tableName}`, { PartitionKey: partitionKey, RowKey: rowKey, ...properties });
    if (response.status !== 201 && response.status !== 204) {
      throw new Error(`table insert failed: HTTP ${response.status} ${(await response.text()).slice(0, 200)}`);
    }
  }

  /** The Bicep declares the table; this covers a store pointed at a fresh account. 409 = exists. */
  private async ensureTableExists(): Promise<void> {
    if (this.tableIsKnownToExist) return;
    const response = await this.request("/Tables", { TableName: this.tableName });
    if (response.status !== 201 && response.status !== 204 && response.status !== 409) {
      throw new Error(`table create failed: HTTP ${response.status} ${(await response.text()).slice(0, 200)}`);
    }
    this.tableIsKnownToExist = true;
  }

  private request(resourcePath: string, body: Record<string, unknown>): ReturnType<FetchLike> {
    const requestDate = new Date().toUTCString();
    return this.fetchImplementation(`${this.credentials.tableEndpoint}${resourcePath}`, {
      method: "POST",
      headers: {
        authorization: tableSharedKeyLiteAuthorization(this.credentials, requestDate, resourcePath),
        "x-ms-date": requestDate,
        "x-ms-version": TABLE_SERVICE_VERSION,
        "content-type": "application/json",
        accept: "application/json;odata=nometadata",
        dataserviceversion: "3.0;NetFx",
        maxdataserviceversion: "3.0;NetFx;NetFx",
        prefer: "return-no-content",
      },
      body: JSON.stringify(body),
    });
  }
}

export interface ProcessUsageReportInput {
  body: unknown;
  user: VerifiedUser;
  config: Pick<RelayConfig, "usageRecordingEnabled">;
  store: UsageStore | undefined;
  receivedAt: Date;
  log: Pick<InvocationContext, "log" | "warn" | "error">;
}

/** The route's decision, separated from HTTP so it is unit-tested with a fake store. */
export async function processUsageReport(input: ProcessUsageReportInput): Promise<HttpResponseInit> {
  const { body, user, config, store, receivedAt, log } = input;
  if (!config.usageRecordingEnabled) {
    return jsonResponse(202, { stored: false, reason: "recording_off" });
  }
  if (!store) {
    log.error("[usage] no storage connection string configured");
    return errorResponse(503, "usage_store_not_configured", "The relay has nowhere to keep usage reports.");
  }

  let entity: WingmanUsageEntity;
  try {
    entity = buildUsageEntity(body, user, receivedAt);
  } catch (error) {
    if (error instanceof UsageReportError) return errorResponse(400, "invalid_usage_report", error.message);
    throw error;
  }

  const startedAtMs = Date.now();
  try {
    await store.save(entity);
  } catch (error) {
    log.error(`[usage] user=${user.email} turn=${entity.turnId} store failed: ${error instanceof Error ? error.message : String(error)}`);
    return errorResponse(503, "usage_store_unavailable", "The relay could not keep the usage report right now.");
  }
  // One line per report: who, which turn, how big, never the content.
  log.log(`[usage] user=${user.email} turn=${entity.turnId} outcome=${entity.outcome} tools=${entity.toolCallCount} rounds=${entity.modelRounds} question_chars=${entity.question.length} answer_chars=${entity.answer.length} ms=${Date.now() - startedAtMs}`);
  return jsonResponse(202, { stored: true });
}

let cachedUsageStore: UsageStore | undefined;

function getUsageStore(config: RelayConfig): UsageStore | undefined {
  if (!config.usageStorageConnectionString) return undefined;
  if (!cachedUsageStore) cachedUsageStore = new TableUsageStore(config.usageStorageConnectionString, config.usageTableName);
  return cachedUsageStore;
}

async function usageHandler(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  const authentication = await authenticateRequest(request, context);
  if ("response" in authentication) return authentication.response;

  const body = await readJsonBody<unknown>(request);
  if (body === undefined) return errorResponse(400, "invalid_json", "Request body must be JSON.");

  const config = getRelayConfig();
  return processUsageReport({
    body,
    user: authentication.user,
    config,
    store: getUsageStore(config),
    receivedAt: new Date(),
    log: context,
  });
}

app.http("usage", {
  methods: ["POST"],
  authLevel: "anonymous", // the Entra bearer check in authenticateRequest is the gate, not a function key
  route: "usage",
  handler: usageHandler,
});
