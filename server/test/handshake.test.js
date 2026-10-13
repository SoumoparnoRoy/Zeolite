import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { after, before, test } from "node:test";
import { createApp } from "../src/index.js";
import { createSessionStore } from "../src/sessions.js";

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

// Never answers, and gives up only when the caller's deadline aborts it.
function stalled(options) {
  return new Promise((_resolve, reject) => {
    options.signal.addEventListener("abort", () => reject(options.signal.reason));
  });
}
async function fetchStub(_url, options) {
  if (upstreamMode === "stalled") {
    return stalled(options);
  }
  if (upstreamMode === "failure") {
    return new Response("provider-private-error", { status: 400 });
  }
  if (upstreamMode === "tokenless") {
    return new Response(JSON.stringify({ workspace_name: "generic" }), { status: 200 });
  }
  // Answers, but only after the session it was asked for has run out.
  if (upstreamMode === "outlived") {
    currentTime += 5 * 60 * 1000;
  }
  const body = JSON.parse(options.body);
  const payload =
    body.grant_type === "refresh_token"
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
  const app = createApp({
    fetchImpl: fetchStub,
    now: () => currentTime,
    timeouts: { notion: 50 },
  });
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

test("pressing Cancel on Notion says so, and the pages carry a policy", async () => {
  const response = await fetch(`${baseUrl}/notion/callback?error=access_denied&state=anything`);
  assert.equal(response.status, 400);
  assert.match(await response.text(), /Connection cancelled/);
  assert.match(response.headers.get("content-security-policy"), /frame-ancestors 'none'/);
  assert.equal(response.headers.get("x-powered-by"), null);
});

test("a reply from Notion without a token is not a connection", async () => {
  upstreamMode = "tokenless";
  const started = await startSession();
  const response = await fetch(
    `${baseUrl}/notion/callback?code=generic-code&state=${encodeURIComponent(started.state)}`,
  );
  upstreamMode = "success";
  assert.equal(response.status, 502);
  assert.doesNotMatch(await response.text(), /Connection ready/);
});

test("a stalled Notion gives up instead of holding the request open", async () => {
  upstreamMode = "stalled";
  const started = await startSession();
  const callback = await fetch(
    `${baseUrl}/notion/callback?code=generic-code&state=${encodeURIComponent(started.state)}`,
  );
  assert.equal(callback.status, 502);

  const refresh = await fetch(`${baseUrl}/notion/refresh`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ refresh_token: "generic-refresh-token" }),
  });
  assert.equal(refresh.status, 502);
  assert.deepEqual(await refresh.json(), { error: "Unable to refresh the connection." });
  upstreamMode = "success";
  // The extra session spends a start from the per-minute allowance the later
  // tests are counting on.
  currentTime += 61_000;
});

test("reloading the ready page shows it again, and the session stays claimable", async () => {
  upstreamMode = "success";
  const started = await startSession();
  const callbackUrl = `${baseUrl}/notion/callback?code=generic-code&state=${encodeURIComponent(started.state)}`;
  const first = await (await fetch(callbackUrl)).text();

  // Notion refuses a code it has already exchanged.
  upstreamMode = "failure";
  const reload = await fetch(callbackUrl);
  upstreamMode = "success";
  assert.equal(reload.status, 200);
  assert.equal(await reload.text(), first);

  const session = first.match(/session=([A-Za-z0-9_-]+)/)[1];
  const claim = await fetch(`${baseUrl}/notion/claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ session, verifier }),
  });
  assert.deepEqual(await claim.json(), tokenPayload);
});

test("a session that runs out during the exchange is not shown as ready", async () => {
  upstreamMode = "outlived";
  const started = await startSession();
  const response = await fetch(
    `${baseUrl}/notion/callback?code=generic-code&state=${encodeURIComponent(started.state)}`,
  );
  upstreamMode = "success";
  assert.equal(response.status, 400);
  assert.match(await response.text(), /This link expired/);
  currentTime += 61_000;
});

test("the session store refuses new sessions once full, until some expire", () => {
  let time = 0;
  const store = createSessionStore({ now: () => time });
  for (let index = 0; index < 5000; index += 1) {
    assert.ok(store.create(challenge));
  }
  assert.equal(store.create(challenge), undefined);
  time += 5 * 60 * 1000;
  const fresh = store.create(challenge);
  assert.equal(store.getByState(fresh.state), fresh);
  assert.equal(store.getByPairingCode(fresh.pairingCode.toLowerCase()), fresh);
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
  const request = () =>
    fetch(`${baseUrl}/notion/claim`, {
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

test("a body that is not JSON is refused in JSON, counted, and kept out of the log", async () => {
  currentTime += 61_000;
  let stderr = "";
  const originalWrite = process.stderr.write;
  process.stderr.write = (chunk) => {
    stderr += String(chunk);
    return true;
  };
  const statuses = [];
  try {
    for (let attempt = 0; attempt < 11; attempt += 1) {
      const response = await fetch(`${baseUrl}/notion/refresh`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: '{"refresh_token": "generic-refresh-fragment',
      });
      statuses.push(response.status);
      if (attempt === 0) {
        assert.deepEqual(await response.json(), { error: "Invalid request." });
      }
    }
  } finally {
    process.stderr.write = originalWrite;
  }
  assert.deepEqual(statuses, [...Array(10).fill(400), 429]);
  assert.doesNotMatch(stderr, /generic-refresh-fragment/);

  const unknown = await fetch(`${baseUrl}/notion/nowhere`);
  assert.equal(unknown.status, 404);
  assert.deepEqual(await unknown.json(), { error: "Not found." });
  currentTime += 61_000;
});

test("a mistyped number in the config stops the start", () => {
  try {
    process.env.AI_DAILY_CALLS = "18O";
    assert.throws(() => createApp(), /AI_DAILY_CALLS/);
    process.env.AI_DAILY_CALLS = "";
    process.env.TRUST_PROXY = "true";
    assert.throws(() => createApp(), /TRUST_PROXY/);
  } finally {
    delete process.env.AI_DAILY_CALLS;
    delete process.env.TRUST_PROXY;
  }
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
