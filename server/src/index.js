import { pathToFileURL } from "node:url";
import express from "express";
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

// Optional on purpose: the service exists for the Notion handshake, and a
// deployment without a Cloudflare token still does that job in full.
function readVisionConfig() {
  const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
  const apiToken = process.env.CLOUDFLARE_API_TOKEN;
  if (!accountId || !apiToken) {
    return null;
  }
  return { accountId, apiToken, model: process.env.CLOUDFLARE_MODEL || VISION_MODEL };
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
    trustProxy: Number(process.env.TRUST_PROXY ?? 0),
    vision: readVisionConfig(),
    dailyCalls: Number(process.env.AI_DAILY_CALLS ?? DAILY_CALLS),
  };
}

export function createApp({ fetchImpl = globalThis.fetch, now = Date.now } = {}) {
  const app = express();
  const config = readConfig();
  const sessions = createSessionStore({ now });
  const limit = createRateLimiter({ now });
  const budget = createDailyBudget({ maximum: config.dailyCalls, now });

  app.set("trust proxy", config.trustProxy);

  // Called when the connect screen opens, so a host that has spun the service
  // down is awake before anyone taps Connect. Unmetered on purpose: throttling
  // a wake-up call defeats it. It reports nothing worth reconnoitring.
  app.get("/health", (_request, response) => {
    response.status(200).type("text/plain").send("ok");
  });

  // Each router gets only the body it needs. The handshake exchanges small
  // JSON and keeps express's 100kb default; a base64 image passes that on the
  // way in, and nothing but the image is allowed to be large.
  app.use("/notion", express.json(), createNotionRouter({ config, sessions, limit, fetchImpl }));
  app.use(
    "/timetable",
    express.json({ limit: "6mb" }),
    createTimetableRouter({ config, limit, budget, fetchImpl }),
  );
  return app;
}

function start() {
  const port = process.env.PORT || 8080;
  const app = createApp();
  app.listen(port, () => {
    process.stdout.write(`Zeolite server listening on port ${port}\n`);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  start();
}
