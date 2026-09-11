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

let upstreamReply = "Monday\n* 09:10-10:00: ABC1234 (R101)";
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
    "*   DEF5678: 10:00-10:50 (R102, PRG)",
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
  assert.deepEqual(body.classes.map((c) => c.subject), ["ABC1234"]);
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
  assert.deepEqual(body.classes.map((c) => c.subject), ["ABC1234"]);
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
  assert.equal((await read(configured, { image: "not base64 !!" })).status, 400);
  assert.equal(lastRequest, undefined);

  const notAnImage = Buffer.from("PK a zip, not a picture").toString("base64");
  assert.equal((await read(configured, { image: notAnImage })).status, 400);
  assert.equal(lastRequest, undefined);
});

test("the day's allowance runs out, and says so", async () => {
  upstreamOk = true;
  upstreamReply = "**Monday**\n*   09:10-10:00: ABC1234";
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
