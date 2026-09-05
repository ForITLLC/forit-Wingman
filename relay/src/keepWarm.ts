import { app, InvocationContext, Timer } from "@azure/functions";

/**
 * Keeps a relay worker warm. The relay runs on a consumption plan (infra/main.bicep), which
 * deallocates idle workers; the first spoken question after a quiet spell then paid a cold start
 * of several seconds before the model was even asked. A timer every four minutes keeps the host
 * loaded. It calls nothing upstream and stores nothing.
 */
export async function keepWarmHandler(timer: Timer, context: InvocationContext): Promise<void> {
  context.log(`[keepwarm] tick pastDue=${timer.isPastDue}`);
}

app.timer("keepWarm", {
  schedule: "0 */4 * * * *",
  runOnStartup: false,
  handler: keepWarmHandler,
});
