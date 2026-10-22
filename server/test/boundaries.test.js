import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { after, before, test } from "node:test";
import { SignJWT, createLocalJWKSet, exportJWK, generateKeyPair } from "jose";
import { createApp } from "../src/index.js";

process.env.NOTION_CLIENT_ID = "test-client";
process.env.NOTION_CLIENT_SECRET = "test-secret";
process.env.REDIRECT_URI = "https://service.invalid/notion/callback";
process.env.CLOUDFLARE_ACCOUNT_ID = "test-account";
process.env.CLOUDFLARE_API_TOKEN = "test-cloudflare-token";
process.env.FIREBASE_PROJECT_NUMBER = "123456789";

const tokenPayload = { access_token: "test-access-token", refresh_token: "test-refresh-token" };
let currentTime = 1_760_000_000_000;
let lastUpstreamBody;
let signingKey;
let baseUrl;
let stingyUrl;
const servers = [];

async function fetchStub(_url, options) {
  lastUpstreamBody = String(options.body);
  const payload = lastUpstreamBody.includes("grant_type")
    ? tokenPayload
    : { result: { response: "Monday\n* 09:10-10:00: ABC1234 (R101)" } };
  return new Response(JSON.stringify(payload), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

function attestation() {
  return new SignJWT({ jti: randomUUID() })
    .setProtectedHeader({ alg: "RS256", typ: "JWT", kid: "test-key" })
    .setIssuer("https://firebaseappcheck.googleapis.com/123456789")
    .setAudience(["projects/123456789"])
    .setSubject("1:123456789:android:abc")
    .setIssuedAt()
    .setExpirationTime("1h")
    .sign(signingKey);
}

async function listen(app) {
  const server = app.listen(0);
  await new Promise((resolve) => server.once("listening", resolve));
  servers.push(server);
  return `http://127.0.0.1:${server.address().port}`;
}

// Past the limiter's one-minute window.
function nextWindow() {
  currentTime += 61_000;
}

function post(url, body, headers = {}) {
  return fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function readSheet(url, body, token) {
  nextWindow();
  return post(`${url}/timetable/read`, body, {
    "X-Firebase-AppCheck": token ?? (await attestation()),
  });
}

function pngOf(length) {
  const bytes = Buffer.alloc(length);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  return bytes.toString("base64");
}

async function readySession(verifier) {
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  const start = await fetch(`${baseUrl}/notion/start?challenge=${challenge}`, {
    redirect: "manual",
  });
  const state = new URL(start.headers.get("location")).searchParams.get("state");
  const cookie = start.headers.getSetCookie()[0].split(";")[0];
  const html = await (
    await fetch(`${baseUrl}/notion/callback?code=generic-code&state=${state}`, {
      headers: { cookie },
    })
  ).text();
  return {
    session: html.match(/session=([A-Za-z0-9_-]+)/)[1],
    code: html.match(/<div class="code">([A-Z0-9]+)<\/div>/)[1],
  };
}

// What a refusal may say: the generic message and nothing a stack, a path or
// the framework would add.
async function assertPlainRefusal(response, status) {
  assert.equal(response.status, status);
  assert.match(response.headers.get("content-type"), /application\/json/);
  const body = await response.text();
  assert.doesNotMatch(body, /stack|Error:|\bat\s|node_modules|[\\/]src[\\/]|\.js:\d+/);
  assert.equal(Object.keys(JSON.parse(body)).join(), "error");
}

before(async () => {
  const pair = await generateKeyPair("RS256");
  signingKey = pair.privateKey;
  const publicJwk = { ...(await exportJWK(pair.publicKey)), kid: "test-key", alg: "RS256" };
  const options = {
    fetchImpl: fetchStub,
    now: () => currentTime,
    appCheckKeys: createLocalJWKSet({ keys: [publicJwk] }),
  };
  baseUrl = await listen(createApp(options));
  process.env.AI_DAILY_CALLS = "1";
  stingyUrl = await listen(createApp(options));
  delete process.env.AI_DAILY_CALLS;
});

after(async () => {
  await Promise.all(servers.map((s) => new Promise((resolve) => s.close(resolve))));
});

test("unknown paths and wrong methods get the same plain 404", async () => {
  const calls = [
    fetch(`${baseUrl}/`),
    fetch(`${baseUrl}/notion/claim`),
    fetch(`${baseUrl}/timetable/read`),
    fetch(`${baseUrl}/health`, { method: "DELETE" }),
    post(`${baseUrl}/notion/start`, {}),
    fetch(`${baseUrl}/../etc/passwd`),
  ];
  for (const response of await Promise.all(calls)) {
    assert.equal(response.headers.get("x-powered-by"), null);
    await assertPlainRefusal(response, 404);
  }
});

test("image reading refuses a missing, empty or forged attestation, and spends nothing", async () => {
  const { privateKey } = await generateKeyPair("RS256");
  const forged = await new SignJWT({})
    .setProtectedHeader({ alg: "RS256", typ: "JWT", kid: "test-key" })
    .setIssuer("https://firebaseappcheck.googleapis.com/123456789")
    .setAudience(["projects/123456789"])
    .setExpirationTime("1h")
    .sign(privateKey);
  for (const token of [undefined, "", "not-a-token", forged]) {
    nextWindow();
    const headers = token === undefined ? {} : { "X-Firebase-AppCheck": token };
    const response = await post(`${stingyUrl}/timetable/read`, { image: pngOf(64) }, headers);
    await assertPlainRefusal(response, 401);
  }
  const allowed = await readSheet(stingyUrl, { image: pngOf(64) });
  assert.equal(allowed.status, 200);
});

test("a challenge is exactly 43 base64url characters", async () => {
  nextWindow();
  const ask = (challenge) =>
    fetch(`${baseUrl}/notion/start?challenge=${encodeURIComponent(challenge)}`, {
      redirect: "manual",
    });
  assert.equal((await ask("a".repeat(42))).status, 400);
  assert.equal((await ask("a".repeat(44))).status, 400);
  assert.equal((await ask(`${"a".repeat(42)}+`)).status, 400);
  assert.equal((await ask(" ".repeat(43))).status, 400);
  assert.equal((await ask("a".repeat(43))).status, 302);
});

test("one person's session cannot be claimed with another person's verifier", async () => {
  nextWindow();
  const first = await readySession("first-device-verifier");
  await readySession("second-device-verifier");

  for (const handle of [{ session: first.session }, { code: first.code }]) {
    const response = await post(`${baseUrl}/notion/claim`, {
      ...handle,
      verifier: "second-device-verifier",
    });
    await assertPlainRefusal(response, 400);
  }

  const own = await post(`${baseUrl}/notion/claim`, {
    session: first.session,
    verifier: "first-device-verifier",
  });
  assert.equal(own.status, 200);
  assert.deepEqual(await own.json(), tokenPayload);
});

test("a claim with a handle or verifier of the wrong type is refused", async () => {
  nextWindow();
  const ready = await readySession("typed-verifier");
  const bodies = [
    { session: [ready.session], verifier: "typed-verifier" },
    { session: { id: ready.session }, verifier: "typed-verifier" },
    { code: 12345678, verifier: "typed-verifier" },
    { session: ready.session, verifier: ["typed-verifier"] },
    { session: ready.session },
    { session: "   ", verifier: "typed-verifier" },
    [],
    "null",
  ];
  for (const body of bodies) {
    await assertPlainRefusal(await post(`${baseUrl}/notion/claim`, body), 400);
  }
});

async function assertRefreshRefused(values) {
  for (const value of values) {
    nextWindow();
    lastUpstreamBody = undefined;
    const response = await post(`${baseUrl}/notion/refresh`, { refresh_token: value });
    await assertPlainRefusal(response, 400);
    assert.equal(lastUpstreamBody, undefined, `${JSON.stringify(value)} reached Notion`);
  }
}

test("a refresh token that is missing, empty or not a string is refused", async () => {
  await assertRefreshRefused([undefined, "", 42, ["a"], { token: "a" }, null]);
});

test("a blank refresh token is refused without asking Notion", async () => {
  await assertRefreshRefused(["   ", "\n\t"]);
});

test("bodies past each route's limit are refused as JSON before they are read", async () => {
  nextWindow();
  const padding = "x".repeat(110 * 1024);
  await assertPlainRefusal(
    await post(`${baseUrl}/notion/claim`, { session: padding, verifier: "v" }),
    413,
  );
  await assertPlainRefusal(
    await post(`${baseUrl}/notion/refresh`, { refresh_token: padding }),
    413,
  );
  await assertPlainRefusal(await readSheet(baseUrl, { image: "A".repeat(6_400_000) }), 413);
});

test("an image of exactly 3 MiB is read and one byte more is refused", async () => {
  const most = 3 * 1024 * 1024;
  assert.equal((await readSheet(baseUrl, { image: pngOf(most) })).status, 200);
  await assertPlainRefusal(await readSheet(baseUrl, { image: pngOf(most + 1) }), 400);
});

test("an image that is blank, not a string, or not a picture is refused", async () => {
  const gif = Buffer.from("GIF89a-generic-bytes").toString("base64");
  for (const value of ["", "   ", "\n\n", 42, [pngOf(64)], { data: pngOf(64) }, gif, "%%%%"]) {
    lastUpstreamBody = undefined;
    await assertPlainRefusal(await readSheet(baseUrl, { image: value }), 400);
    assert.equal(lastUpstreamBody, undefined);
  }
});

test("recognised text past 20,000 characters is cut, not refused", async () => {
  const text = `${"x".repeat(19_990)}END-MARKER-1234`;
  const response = await readSheet(baseUrl, { image: pngOf(64), text });
  assert.equal(response.status, 200);
  assert.ok(lastUpstreamBody.includes("END-MARKE"));
  assert.ok(!lastUpstreamBody.includes("R-1234"));
});

test("a body that is not an object, or not JSON at all, is refused plainly", async () => {
  for (const body of ["[", "{'session': 1}", "\u0000", "true"]) {
    nextWindow();
    await assertPlainRefusal(await post(`${baseUrl}/notion/claim`, body), 400);
  }
  nextWindow();
  const wrongType = await fetch(`${baseUrl}/notion/refresh`, {
    method: "POST",
    headers: { "Content-Type": "text/plain" },
    body: "refresh_token=generic",
  });
  await assertPlainRefusal(wrongType, 400);
});
