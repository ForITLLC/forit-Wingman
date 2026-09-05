/**
 * Function App entry point. Importing each route module registers it with the Functions host.
 * `enableHttpStream` lets /api/chat and /api/tts hand the upstream body back as a stream instead
 * of buffering a whole completion or audio clip in memory. /api/usage keeps the per-turn usage
 * report the app sends when the person has not opted out.
 */
import { app } from "@azure/functions";

app.setup({ enableHttpStream: true });

import "./health.js";
import "./chat.js";
import "./tts.js";
import "./usage.js";
import "./keepWarm.js";
