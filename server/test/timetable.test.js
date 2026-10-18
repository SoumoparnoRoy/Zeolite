import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { after, before, test } from "node:test";
import { SignJWT, createLocalJWKSet, exportJWK, generateKeyPair } from "jose";
import { createApp } from "../src/index.js";

process.env.NOTION_CLIENT_ID = "test-client";
process.env.NOTION_CLIENT_SECRET = "test-secret";
process.env.REDIRECT_URI = "https://service.invalid/notion/callback";

// A one pixel PNG. Nothing here reads it; it only has to be real base64 of a
// plausible size.
const image =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

const accountId = "test-account";
const apiToken = "test-cloudflare-token";

const projectNumber = "123456789";

let signingKey;
let appCheckKeys;

// Shaped like a Firebase App Check token: the issuer and audience both name
// the project, and it is signed by whichever key is passed. Each is distinct,
// as each limited-use token is.
function attestation(key, { project = projectNumber, expiresIn = "1h" } = {}) {
  return new SignJWT({ jti: randomUUID() })
    .setProtectedHeader({ alg: "RS256", typ: "JWT", kid: "test-key" })
    .setIssuer(`https://firebaseappcheck.googleapis.com/${project}`)
    .setAudience([`projects/${project}`])
    .setSubject("1:123456789:android:abc")
    .setIssuedAt()
    .setExpirationTime(expiresIn)
    .sign(key);
}

let upstreamReply = "Monday\n* 09:10-10:00: ABC1234 (R101)";
let upstreamOk = true;
let upstreamStatus = 429;
let upstreamStalled = false;
// A 200 whose body is not the JSON Workers AI normally sends.
let upstreamRaw;
let lastRequest;
let currentTime = 1_760_000_000_000;

function stalled(options) {
  return new Promise((_resolve, reject) => {
    options.signal.addEventListener("abort", () => reject(options.signal.reason));
  });
}
async function fetchStub(url, options) {
  lastRequest = { url, options };
  if (upstreamStalled) {
    return stalled(options);
  }
  if (upstreamRaw !== undefined) {
    return new Response(upstreamRaw, { status: 200 });
  }
  if (!upstreamOk) {
    return new Response("provider-private-error: token test-cloudflare-token", {
      status: upstreamStatus,
    });
  }
  return new Response(JSON.stringify({ result: { response: upstreamReply } }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

const servers = [];

async function listen(app) {
  const server = app.listen(0);
  await new Promise((resolve) => server.once("listening", resolve));
  servers.push(server);
  return `http://127.0.0.1:${server.address().port}`;
}

// Each call moves past the per-caller window, so the limiter does not decide
// the outcome of a test that is about something else.
async function read(baseUrl, body, attested) {
  currentTime += 61_000;
  if (attested === undefined) {
    attested = await attestation(signingKey);
  }
  const headers = { "Content-Type": "application/json" };
  if (attested !== null) {
    headers["X-Firebase-AppCheck"] = attested;
  }
  return fetch(`${baseUrl}/timetable/read`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

let configured;
let unconfigured;
let stingy;
let unattested;

before(async () => {
  const pair = await generateKeyPair("RS256");
  signingKey = pair.privateKey;
  const publicJwk = { ...(await exportJWK(pair.publicKey)), kid: "test-key", alg: "RS256" };
  appCheckKeys = createLocalJWKSet({ keys: [publicJwk] });

  const options = {
    fetchImpl: fetchStub,
    now: () => currentTime,
    appCheckKeys,
    timeouts: { vision: 50 },
  };
  process.env.CLOUDFLARE_ACCOUNT_ID = accountId;
  process.env.CLOUDFLARE_API_TOKEN = apiToken;
  process.env.FIREBASE_PROJECT_NUMBER = projectNumber;
  process.env.AI_DAILY_CALLS = "180";
  configured = await listen(createApp(options));

  process.env.AI_DAILY_CALLS = "1";
  stingy = await listen(createApp(options));

  delete process.env.AI_DAILY_CALLS;
  delete process.env.FIREBASE_PROJECT_NUMBER;
  unattested = await listen(createApp(options));

  delete process.env.CLOUDFLARE_ACCOUNT_ID;
  delete process.env.CLOUDFLARE_API_TOKEN;
  delete process.env.AI_DAILY_CALLS;
  unconfigured = await listen(createApp({ fetchImpl: fetchStub, now: () => currentTime }));
});

after(async () => {
  await Promise.all(servers.map((s) => new Promise((resolve) => s.close(resolve))));
});

test("a read comes back as classes, and the token stays here", async () => {
  upstreamOk = true;
  upstreamReply = [
    "**Monday**",
    "*   09:10-10:00: ABC1234 (R101)",
    "**Wednesday**",
    "*   10:00-11:40: DEF5678",
  ].join("\n");
  const response = await read(configured, { image, text: "ABC1234 09:10" });

  assert.equal(response.status, 200);
  const body = await response.json();
  assert.deepEqual(body.classes, [
    { subject: "ABC1234", weekday: 1, from: 550, to: 600, room: "R101" },
    { subject: "DEF5678", weekday: 3, from: 600, to: 700, room: null },
  ]);

  assert.match(lastRequest.url, /\/accounts\/test-account\/ai\/run\/@cf\//);
  assert.equal(lastRequest.options.headers.Authorization, `Bearer ${apiToken}`);
  assert.doesNotMatch(JSON.stringify(body), /test-cloudflare-token/);
});

test("the recognised text rides along with the image", async () => {
  upstreamOk = true;
  await read(configured, { image, text: "GHI9012 at 11:40" });
  const sent = JSON.parse(lastRequest.options.body);
  assert.match(sent.messages[1].content, /GHI9012 at 11:40/);
  assert.match(sent.image, /^data:image\/png;base64,iVBOR/);
});

// The model writes the subject on either side of the time depending on whether
// it had a transcript to read from, and puts the room in brackets or after a
// comma. All of it is one reply shape as far as the sheet is concerned.
test("the subject is found on either side of the time", async () => {
  upstreamOk = true;
  upstreamReply = [
    "**Monday**",
    "*   09:10-10:00: ABC1234 (R101)",
    "*   DEF5678: 10:00-10:50 (R102, RKM)",
    "*   GHI9012, 11:00-11:50, R103",
  ].join("\n");
  const body = await read(configured, { image }).then((r) => r.json());
  assert.deepEqual(
    body.classes.map((c) => `${c.subject}@${c.room}`),
    ["ABC1234@R101", "DEF5678@R102", "GHI9012@R103"],
  );
});

test("prose around the list is not mistaken for classes", async () => {
  upstreamOk = true;
  upstreamReply = [
    "Here is the timetable I read from the image:",
    "**Monday**",
    "*   09:10-10:00: ABC1234",
    "Let me know if you would like it in another format.",
  ].join("\n");
  const body = await read(configured, { image }).then((r) => r.json());
  assert.deepEqual(
    body.classes.map((c) => c.subject),
    ["ABC1234"],
  );
});

test("a line that cannot be a class is dropped", async () => {
  upstreamOk = true;
  upstreamReply = [
    "*   14:00-15:00: BEFORE ANY DAY IS NAMED",
    "**Monday**",
    "*   09:10-10:00: ABC1234",
    "*   11:00-10:00: BACKWARDS",
    "*   25:00-26:00: NOTATIME",
    "*   12:00-13:00: ",
  ].join("\n");
  const body = await read(configured, { image }).then((r) => r.json());
  assert.deepEqual(
    body.classes.map((c) => c.subject),
    ["ABC1234"],
  );
});

test("only a heading moves the day, and a subject code is never one", async () => {
  upstreamOk = true;
  upstreamReply = [
    "**Monday**",
    "*   FR201: 09:10-10:00 (B204)",
    "Below we list the rest.",
    "*   10:10-11:00: ABC1234",
    "Thu",
    "*   09:10-10:00: DEF5678",
    "5. Friday",
    "*   09:10-10:00: GHI9012",
  ].join("\n");
  const body = await read(configured, { image }).then((r) => r.json());
  assert.deepEqual(
    body.classes.map((c) => `${c.subject}@${c.weekday}`),
    ["FR201@1", "ABC1234@1", "DEF5678@4", "GHI9012@5"],
  );
});

test("a sheet in 12-hour time keeps its afternoon", async () => {
  upstreamOk = true;
  upstreamReply = [
    "**Monday**",
    "*   1:30-2:20 PM: ABC1234",
    "*   11:00-12:50 PM: DEF5678",
    "*   9:00 a.m. - 9:50 a.m.: GHI9012",
    "*   10:00-11:00 AMS101",
    "*   2:30 PM-3:20: JKL3456",
    "*   13:30 PM-14:20 PM: MNO7890",
  ].join("\n");
  const body = await read(configured, { image }).then((r) => r.json());
  assert.deepEqual(
    body.classes.map((c) => `${c.subject} ${c.from}-${c.to}`),
    [
      "ABC1234 810-860",
      "DEF5678 660-770",
      "GHI9012 540-590",
      "AMS101 600-660",
      "JKL3456 870-920",
      "MNO7890 810-860",
    ],
  );
});

test("a reply that found no classes is an answer, not a failure", async () => {
  upstreamOk = true;
  upstreamReply = '{"classes":[]}';
  const response = await read(configured, { image });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { classes: [] });
});

test("an upstream failure says nothing about the upstream", async () => {
  upstreamOk = false;
  let stderr = "";
  const originalWrite = process.stderr.write;
  process.stderr.write = (chunk) => {
    stderr += String(chunk);
    return true;
  };
  const response = await read(configured, { image }).finally(() => {
    process.stderr.write = originalWrite;
  });
  const text = await response.text();

  assert.equal(response.status, 429);
  assert.doesNotMatch(text, /test-cloudflare-token/);
  assert.doesNotMatch(text, /provider-private-error/);
  assert.doesNotMatch(text, /429/);
  assert.doesNotMatch(stderr, /test-cloudflare-token/);
  assert.doesNotMatch(stderr, /provider-private-error/);
  assert.match(stderr, /Workers AI request failed \(429\)/);
});

// Only an unreadable reply blames the photo; the rest land on what the app
// already tells the student for "not available" and "used up today".
test("an upstream refusal is not reported as an unreadable sheet", async () => {
  upstreamOk = false;
  const answers = [];
  for (const status of [401, 403, 429, 500]) {
    upstreamStatus = status;
    answers.push((await read(configured, { image })).status);
  }
  upstreamStatus = 429;
  upstreamOk = true;
  assert.deepEqual(answers, [503, 503, 429, 502]);
});

test("a reply that is not JSON is logged without its body", async () => {
  upstreamOk = true;
  let stderr = "";
  const originalWrite = process.stderr.write;
  process.stderr.write = (chunk) => {
    stderr += String(chunk);
    return true;
  };
  upstreamRaw = "provider-private-error: token test-cloudflare-token";
  const response = await read(configured, { image }).finally(() => {
    process.stderr.write = originalWrite;
    upstreamRaw = undefined;
  });

  assert.equal(response.status, 502);
  assert.doesNotMatch(stderr, /provider-private-error|test-cloudflare-token/);
  assert.match(stderr, /not JSON \(200\)/);
});

test("a stalled model gives up before the app does", async () => {
  upstreamOk = true;
  upstreamStalled = true;
  const response = await read(configured, { image }).finally(() => {
    upstreamStalled = false;
  });

  assert.equal(response.status, 504);
  assert.ok(lastRequest.options.signal instanceof AbortSignal);
});

test("something that is not an image is refused before the upstream", async () => {
  upstreamOk = true;
  lastRequest = undefined;
  assert.equal((await read(configured, { image: "not base64 !!" })).status, 400);
  assert.equal(lastRequest, undefined);

  const notAnImage = Buffer.from("PK a zip, not a picture").toString("base64");
  assert.equal((await read(configured, { image: notAnImage })).status, 400);
  assert.equal(lastRequest, undefined);
});

test("only a read attested for this project reaches the upstream", async () => {
  upstreamOk = true;
  lastRequest = undefined;
  const forged = await attestation((await generateKeyPair("RS256")).privateKey);
  const otherProject = await attestation(signingKey, { project: "987654321" });
  const expired = await attestation(signingKey, { expiresIn: "-1m" });

  let stderr = "";
  const originalWrite = process.stderr.write;
  process.stderr.write = (chunk) => {
    stderr += String(chunk);
    return true;
  };
  try {
    for (const attested of [null, "", "not.a.token", forged, otherProject, expired]) {
      const response = await read(configured, { image }, attested);
      assert.equal(response.status, 401);
      assert.deepEqual(await response.json(), { error: "Invalid request." });
    }
  } finally {
    process.stderr.write = originalWrite;
  }
  assert.equal(lastRequest, undefined);

  // A genuine token for another project is what a wrong project number looks
  // like, so it alone is logged; a forged or expired one stays quiet.
  const logged = stderr.split("\n").filter((line) => line.startsWith("App Check not verified"));
  assert.equal(logged.length, 1);
  assert.match(logged[0], /ERR_JWT_CLAIM_VALIDATION_FAILED|claim/);
  assert.ok(!stderr.includes(otherProject));
});

test("a token reads once, and a replay spends nothing", async () => {
  upstreamOk = true;
  upstreamReply = "**Monday**\n*   09:10-10:00: ABC1234";
  const once = await attestation(signingKey);
  assert.equal((await read(configured, { image }, once)).status, 200);

  lastRequest = undefined;
  let stderr = "";
  const originalWrite = process.stderr.write;
  process.stderr.write = (chunk) => {
    stderr += String(chunk);
    return true;
  };
  let replay;
  try {
    replay = await read(configured, { image }, once);
  } finally {
    process.stderr.write = originalWrite;
  }
  assert.equal(replay.status, 401);
  assert.equal(lastRequest, undefined);
  assert.match(stderr, /App Check token used twice/);
  assert.ok(!stderr.includes(once));
  assert.equal((await read(configured, { image })).status, 200);
});

// The signature's last character carries spare bits and a space inside it is
// skipped when decoding, so the same token can be spelled many ways.
test("a token spelled differently is still a replay", async () => {
  upstreamOk = true;
  upstreamReply = "**Monday**\n*   09:10-10:00: ABC1234";
  const once = await attestation(signingKey);
  assert.equal((await read(configured, { image }, once)).status, 200);

  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  const last = alphabet.indexOf(once.at(-1));
  const spareBits = once.slice(0, -1) + alphabet[last ^ 1];
  const dot = once.lastIndexOf(".");
  const spaced = `${once.slice(0, dot + 5)} ${once.slice(dot + 5)}`;

  const originalWrite = process.stderr.write;
  process.stderr.write = () => true;
  try {
    for (const respelled of [spareBits, spaced]) {
      lastRequest = undefined;
      assert.equal((await read(configured, { image }, respelled)).status, 401);
      assert.equal(lastRequest, undefined);
    }
  } finally {
    process.stderr.write = originalWrite;
  }
});

test("an unattested body is turned away before it is read", async () => {
  currentTime += 61_000;
  const response = await fetch(`${configured}/timetable/read`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: '{"image": "not finished',
  });
  assert.equal(response.status, 401);
});

test("a refused attestation leaves the day's allowance alone", async () => {
  upstreamOk = true;
  upstreamReply = "**Monday**\n*   09:10-10:00: ABC1234";
  assert.equal((await read(stingy, { image }, "not.a.token")).status, 401);
  assert.equal((await read(stingy, { image })).status, 200);
});

test("the day's allowance runs out, and says so", async () => {
  upstreamOk = true;
  upstreamReply = "**Monday**\n*   09:10-10:00: ABC1234";

  const forged = await attestation((await generateKeyPair("RS256")).privateKey);
  assert.equal((await read(stingy, { image }, forged)).status, 401);

  const spent = await read(stingy, { image });
  assert.equal(spent.status, 429);
  assert.match((await spent.json()).error, /midnight UTC/);
});

test("without a Firebase project image reading stays off", async () => {
  lastRequest = undefined;
  assert.equal((await read(unattested, { image })).status, 503);
  assert.equal(lastRequest, undefined);
});

test("without a Cloudflare token the rest of the service is unaffected", async () => {
  const response = await read(unconfigured, { image });
  assert.equal(response.status, 503);

  const health = await fetch(`${unconfigured}/health`);
  assert.equal(health.status, 200);
  assert.equal(await health.text(), "ok");
});
