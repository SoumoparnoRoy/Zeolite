import { pathToFileURL } from "node:url";
import express from "express";
import { createAppCheckVerifier } from "./appcheck.js";
import { createDailyBudget } from "./budget.js";
import { createRateLimiter } from "./limit.js";
import { createNotionRouter } from "./routes.js";
import { createSessionStore } from "./sessions.js";
import { createTimetableRouter } from "./timetable.js";

const VISION_MODEL = "@cf/meta/llama-3.2-11b-vision-instruct";

// Workers AI gives the account 10,000 neurons a day and stops rather than
// bills. A read costs roughly fifty, so this sits under the ceiling and leaves
// room for the reply to run long on a dense sheet.
const DAILY_CALLS = 180;

// Render waits 30 seconds after SIGTERM before it kills the process.
const SHUTDOWN_GRACE_MS = 30_000;

// Optional on purpose: the service exists for the Notion handshake, and a
// deployment without a Cloudflare token still does that job in full. The
// project number is required alongside it, so a deployment that forgot App
// Check stays switched off rather than open to anyone with the URL.
function readVisionConfig() {
  const names = ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_API_TOKEN", "FIREBASE_PROJECT_NUMBER"];
  const missing = names.filter((name) => !process.env[name]);
  if (missing.length > 0) {
    // Leaving out all three is a choice; leaving out some is a mistake, and
    // the feature going quiet is the only other sign of it.
    if (missing.length < names.length) {
      process.stderr.write(`Image reading is off, missing: ${missing.join(", ")}\n`);
    }
    return null;
  }
  return {
    accountId: process.env.CLOUDFLARE_ACCOUNT_ID,
    apiToken: process.env.CLOUDFLARE_API_TOKEN,
    projectNumber: process.env.FIREBASE_PROJECT_NUMBER,
    model: process.env.CLOUDFLARE_MODEL || VISION_MODEL,
  };
}

// Number() reads a typo as NaN, which no comparison is ever true of, so a
// mistyped cap used to switch the cap off; and it reads a blank line as 0.
function wholeNumber(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") {
    return fallback;
  }
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0) {
    throw new Error(`${name} must be a whole number, got "${raw}"`);
  }
  return value;
}

function readConfig() {
  const required = ["NOTION_CLIENT_ID", "NOTION_CLIENT_SECRET", "REDIRECT_URI"];
  const missing = required.filter((name) => !process.env[name]);
  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(", ")}`);
  }
  return {
    clientId: process.env.NOTION_CLIENT_ID,
    clientSecret: process.env.NOTION_CLIENT_SECRET,
    redirectUri: process.env.REDIRECT_URI,
    appScheme: process.env.APP_SCHEME || "zeolite",
    // Hosting puts a load balancer in front, and without this every caller
    // arrives as the balancer's address and shares one rate-limit bucket.
    // Counts hops rather than trusting blindly: a client that could set its
    // own X-Forwarded-For would step around the limiter entirely.
    trustProxy: wholeNumber("TRUST_PROXY", 0),
    vision: readVisionConfig(),
    dailyCalls: wholeNumber("AI_DAILY_CALLS", DAILY_CALLS),
  };
}

export function createApp({
  fetchImpl = globalThis.fetch,
  now = Date.now,
  appCheckKeys,
  timeouts = {},
} = {}) {
  const app = express();
  const config = readConfig();
  config.notionTimeoutMs = timeouts.notion;
  if (config.vision) {
    config.vision.timeoutMs = timeouts.vision;
  }
  const sessions = createSessionStore({ now });
  const limit = createRateLimiter({ now });
  const budget = createDailyBudget({ maximum: config.dailyCalls, now });
  const verifyAppCheck = config.vision
    ? createAppCheckVerifier({
        projectNumber: config.vision.projectNumber,
        keys: appCheckKeys,
        now,
      })
    : null;

  app.set("trust proxy", config.trustProxy);
  app.disable("x-powered-by");

  // Called when the connect screen opens, so a host that has spun the service
  // down is awake before anyone taps Connect. Unmetered on purpose: throttling
  // a wake-up call defeats it. It reports nothing worth reconnoitring.
  app.get("/health", (_request, response) => {
    response.status(200).type("text/plain").send("ok");
  });

  // Each route parses its own body, after its rate limit, so a caller already
  // refused costs nothing to turn away.
  app.use("/notion", createNotionRouter({ config, sessions, limit, fetchImpl }));
  app.use(
    "/timetable",
    createTimetableRouter({ config, limit, budget, verifyAppCheck, fetchImpl }),
  );

  app.use((_request, response) => {
    response.status(404).json({ error: "Not found." });
  });

  // Express's own handler answers in HTML, with the stack outside production,
  // and logs the stack everywhere; for a body that is not JSON the stack
  // quotes the body, which on /notion/refresh is a refresh token.
  app.use((error, _request, response, next) => {
    if (response.headersSent) {
      next(error);
      return;
    }
    const status = Number.isInteger(error.status) ? error.status : 500;
    process.stderr.write(`Request refused (${status}): ${error.type ?? error.name}\n`);
    response.status(status).json({ error: "Invalid request." });
  });
  return app;
}

function start() {
  const port = process.env.PORT || 8080;
  const app = createApp();
  // A bind failure arrives here, not as a throw. Ignored, the process printed
  // that it was listening and then exited, since every timer is unref'd.
  const server = app.listen(port, (error) => {
    if (error) {
      process.stderr.write(`Cannot listen on port ${port}: ${error.code}\n`);
      process.exit(1);
    }
    process.stdout.write(`Zeolite server listening on port ${port}\n`);
  });

  // Every deploy ends the old instance with SIGTERM. A read already with the
  // model gets a bounded chance to answer; a session waiting to be claimed is
  // lost either way, which a single instance in memory accepts.
  process.once("SIGTERM", () => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), SHUTDOWN_GRACE_MS).unref();
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  start();
}
