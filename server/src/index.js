import { pathToFileURL } from "node:url";
import express from "express";
import { createRateLimiter } from "./limit.js";
import { createNotionRouter } from "./routes.js";
import { createSessionStore } from "./sessions.js";

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
  };
}

export function createApp({ fetchImpl = globalThis.fetch, now = Date.now } = {}) {
  const app = express();
  const config = readConfig();
  const sessions = createSessionStore({ now });
  const limit = createRateLimiter({ now });

  app.set("trust proxy", config.trustProxy);
  app.use(express.json());
  app.use("/notion", createNotionRouter({ config, sessions, limit, fetchImpl }));
  return app;
}

function start() {
  const port = process.env.PORT || 8080;
  const app = createApp();
  app.listen(port, () => {
    process.stdout.write(`Zeolite Notion auth listening on port ${port}\n`);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  start();
}
