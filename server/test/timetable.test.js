import assert from "node:assert/strict";
import { after, before, test } from "node:test";
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

let upstreamReply = '{"classes":[["ABC1234",1,550,600,"R101"]]}';
let upstreamOk = true;
let lastRequest;
let currentTime = 1_760_000_000_000;

async function fetchStub(url, options) {
  lastRequest = { url, options };
  if (!upstreamOk) {
    return new Response("provider-private-error: token test-cloudflare-token", { status: 429 });
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
function read(baseUrl, body) {
  currentTime += 61_000;
  return fetch(`${baseUrl}/timetable/read`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

let configured;
let unconfigured;
let stingy;

before(async () => {
  process.env.CLOUDFLARE_ACCOUNT_ID = accountId;
  process.env.CLOUDFLARE_API_TOKEN = apiToken;
  process.env.AI_DAILY_CALLS = "180";
  configured = await listen(createApp({ fetchImpl: fetchStub, now: () => currentTime }));

  process.env.AI_DAILY_CALLS = "1";
  stingy = await listen(createApp({ fetchImpl: fetchStub, now: () => currentTime }));

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
  upstreamReply = '{"classes":[["ABC1234",1,550,600,"R101"],["DEF5678",3,600,700,null]]}';
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
  assert.ok(Array.isArray(sent.image) && sent.image.length > 0);
});

test("entries that are not classes are dropped, and the rest survive", async () => {
  upstreamOk = true;
  upstreamReply = JSON.stringify({
    classes: [
      ["ABC1234", 1, 550, 600, "R101"],
      ["", 1, 550, 600, "R101"],
      ["BAD", 9, 550, 600, null],
      ["BAD", 1, 600, 550, null],
      ["BAD", 1, -5, 600, null],
      ["SHORT", 1],
      "not even an array",
      ["DEF5678", 7, 0, 1439, "R102"],
    ],
  });
  const body = await read(configured, { image }).then((r) => r.json());
  assert.deepEqual(
    body.classes.map((c) => c.subject),
    ["ABC1234", "DEF5678"],
  );
});

test("json wrapped in prose is still read", async () => {
  upstreamOk = true;
  upstreamReply = 'Sure! Here is the timetable:\n```json\n{"classes":[["ABC1234",2,540,590,null]]}\n```';
  const body = await read(configured, { image }).then((r) => r.json());
  assert.equal(body.classes.length, 1);
  assert.equal(body.classes[0].subject, "ABC1234");
});

test("an upstream failure says nothing about the upstream", async () => {
  upstreamOk = false;
  const response = await read(configured, { image });
  const text = await response.text();

  assert.equal(response.status, 502);
  assert.doesNotMatch(text, /test-cloudflare-token/);
  assert.doesNotMatch(text, /provider-private-error/);
  assert.doesNotMatch(text, /429/);
});

test("something that is not an image is refused before the upstream", async () => {
  upstreamOk = true;
  lastRequest = undefined;
  const response = await read(configured, { image: "not base64 !!" });
  assert.equal(response.status, 400);
  assert.equal(lastRequest, undefined);
});

test("the day's allowance runs out, and says so", async () => {
  upstreamOk = true;
  upstreamReply = '{"classes":[["ABC1234",1,550,600,null]]}';
  assert.equal((await read(stingy, { image })).status, 200);

  const spent = await read(stingy, { image });
  assert.equal(spent.status, 429);
  assert.match((await spent.json()).error, /midnight UTC/);
});

test("without a Cloudflare token the rest of the service is unaffected", async () => {
  const response = await read(unconfigured, { image });
  assert.equal(response.status, 503);

  const health = await fetch(`${unconfigured}/health`);
  assert.equal(health.status, 200);
  assert.equal(await health.text(), "ok");
});
