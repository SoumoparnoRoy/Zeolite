import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { after, before, test } from "node:test";
import { createApp } from "../src/index.js";

process.env.NOTION_CLIENT_ID = "test-client";
process.env.NOTION_CLIENT_SECRET = "test-secret";
process.env.REDIRECT_URI = "https://service.invalid/notion/callback";
process.env.APP_SCHEME = "zeolite";

const verifier = "generic-verifier-value";
const challenge = createHash("sha256").update(verifier).digest("base64url");
const tokenPayload = { access_token: "test-access-token", refresh_token: "test-refresh-token" };
let upstreamMode = "success";
let currentTime = 1_000_000;
let server;
let baseUrl;

async function fetchStub(_url, options) {
  if (upstreamMode === "failure") {
    return new Response("provider-private-error", { status: 400 });
  }
  const body = JSON.parse(options.body);
  const payload = body.grant_type === "refresh_token"
    ? { access_token: "refreshed-access-token", refresh_token: body.refresh_token }
    : tokenPayload;
  return new Response(JSON.stringify(payload), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

async function startSession(value = challenge) {
  const response = await fetch(`${baseUrl}/notion/start?challenge=${encodeURIComponent(value)}`, {
    redirect: "manual",
  });
  const location = new URL(response.headers.get("location"));
  return { response, location, state: location.searchParams.get("state") };
}

async function readySession(sessionVerifier = verifier) {
  const started = await startSession(
    createHash("sha256").update(sessionVerifier).digest("base64url"),
  );
  const callback = await fetch(
    `${baseUrl}/notion/callback?code=generic-code&state=${encodeURIComponent(started.state)}`,
  );
  const html = await callback.text();
  const session = html.match(/zeolite:\/\/notion\?session=([A-Za-z0-9_-]+)/)?.[1];
  const code = html.match(/<div class="code">([A-Z0-9]+)<\/div>/)?.[1];
  return { callback, html, session, code };
}

before(async () => {
  const app = createApp({ fetchImpl: fetchStub, now: () => currentTime });
  server = app.listen(0);
  await new Promise((resolve) => server.once("listening", resolve));
  const address = server.address();
  baseUrl = `http://127.0.0.1:${address.port}`;
});

after(async () => {
  await new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
});

test("start rejects missing and malformed challenges", async () => {
  const missing = await fetch(`${baseUrl}/notion/start`);
  const malformed = await fetch(`${baseUrl}/notion/start?challenge=${"a".repeat(42)}%25`);
  assert.equal(missing.status, 400);
  assert.equal(malformed.status, 400);
});

test("start redirects with the required authorization parameters", async () => {
  const { response, location } = await startSession();
  assert.equal(response.status, 302);
  assert.equal(location.origin + location.pathname, "https://api.notion.com/v1/oauth/authorize");
  assert.equal(location.searchParams.get("client_id"), "test-client");
  assert.equal(location.searchParams.get("response_type"), "code");
  assert.equal(location.searchParams.get("owner"), "user");
  assert.equal(location.searchParams.get("redirect_uri"), process.env.REDIRECT_URI);
  assert.match(location.searchParams.get("state"), /^[A-Za-z0-9_-]{43}$/);
});

test("callback rejects an unknown state", async () => {
  const response = await fetch(`${baseUrl}/notion/callback?code=generic-code&state=unknown-state`);
  assert.equal(response.status, 400);
});

test("callback returns the pairing code and app deep link", async () => {
  upstreamMode = "success";
  const result = await readySession();
  assert.equal(result.callback.status, 200);
  assert.match(result.code, /^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{8}$/);
  assert.match(result.html, /zeolite:\/\/notion\?session=[A-Za-z0-9_-]{43}/);
});

test("callback hides an upstream failure", async () => {
  upstreamMode = "failure";
  const started = await startSession();
  const response = await fetch(
    `${baseUrl}/notion/callback?code=generic-code&state=${encodeURIComponent(started.state)}`,
  );
  const body = await response.text();
  assert.equal(response.status, 502);
  assert.doesNotMatch(body, /provider-private-error/);
  upstreamMode = "success";
});

test("claim rejects the wrong verifier", async () => {
  const ready = await readySession();
  const response = await fetch(`${baseUrl}/notion/claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ session: ready.session, verifier: "wrong-verifier" }),
  });
  assert.equal(response.status, 400);
});

test("claim returns the token payload", async () => {
  const ready = await readySession();
  const response = await fetch(`${baseUrl}/notion/claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ session: ready.session, verifier }),
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), tokenPayload);
});

test("claim prevents a second claim", async () => {
  const ready = await readySession();
  const request = () => fetch(`${baseUrl}/notion/claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ session: ready.session, verifier }),
  });
  assert.equal((await request()).status, 200);
  assert.equal((await request()).status, 400);
});

test("claim accepts a case-insensitive pairing code", async () => {
  const ready = await readySession();
  const response = await fetch(`${baseUrl}/notion/claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code: ready.code.toLowerCase(), verifier }),
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), tokenPayload);
});

test("an expired session cannot be claimed", async () => {
  const ready = await readySession();
  currentTime += 5 * 60 * 1000;
  const response = await fetch(`${baseUrl}/notion/claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ session: ready.session, verifier }),
  });
  assert.equal(response.status, 400);
  currentTime += 60 * 1000;
});

test("refresh returns a successful payload and hides a failure", async () => {
  upstreamMode = "success";
  const success = await fetch(`${baseUrl}/notion/refresh`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ refresh_token: "generic-refresh-token" }),
  });
  assert.equal(success.status, 200);
  assert.deepEqual(await success.json(), {
    access_token: "refreshed-access-token",
    refresh_token: "generic-refresh-token",
  });

  upstreamMode = "failure";
  const failure = await fetch(`${baseUrl}/notion/refresh`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ refresh_token: "generic-refresh-token" }),
  });
  const body = await failure.text();
  assert.equal(failure.status, 502);
  assert.doesNotMatch(body, /provider-private-error/);
  upstreamMode = "success";
});

test("refresh rejects a missing token without blaming the provider", async () => {
  const response = await fetch(`${baseUrl}/notion/refresh`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({}),
  });
  assert.equal(response.status, 400);
});

test("claim rate limit returns 429", async () => {
  let response;
  for (let index = 0; index < 21; index += 1) {
    response = await fetch(`${baseUrl}/notion/claim`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session: "missing-session", verifier }),
    });
  }
  assert.equal(response.status, 429);
});

test("health answers without touching the handshake", async () => {
  const response = await fetch(`${baseUrl}/health`);
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "ok");
});

test("health stays answerable when a route's rate limit is spent", async () => {
  for (let attempt = 0; attempt < 25; attempt += 1) {
    await fetch(`${baseUrl}/notion/claim`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session: "nonexistent", verifier }),
    });
  }
  const response = await fetch(`${baseUrl}/health`);
  assert.equal(response.status, 200);
});
