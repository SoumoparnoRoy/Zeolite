import express, { Router } from "express";
import { failureOf } from "./failure.js";
import { readTimetable } from "./vision.js";

const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;

// A phone camera will happily hand over something far larger than any sheet
// needs to be. Cost rises with resolution, so the app downscales before it
// sends and this is the backstop for when it does not.
const MOST_IMAGE_BYTES = 3 * 1024 * 1024;

// The recognised text of one page. Generous, and still bounded.
const MOST_TEXT_LENGTH = 20_000;

const INVALID = { error: "Invalid request." };

// Read off the bytes rather than taken from the caller, which also refuses
// anything that is base64 of something other than an image.
function typeOf(bytes) {
  if (bytes.length > 8 && bytes[0] === 0x89 && bytes[1] === 0x50) {
    return "image/png";
  }
  if (bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    return "image/jpeg";
  }
  return undefined;
}

// One 400 for every refusal, since the app only sends downscaled PNG or JPEG;
// the reason is for the log, which is where anything else calling shows up.
function imageIn(value) {
  if (typeof value !== "string" || value.length === 0) {
    return { refused: "no image" };
  }
  const cleaned = value.replace(/\s+/g, "");
  if (!BASE64_PATTERN.test(cleaned)) {
    return { refused: "not base64" };
  }
  const bytes = Buffer.from(cleaned, "base64");
  if (bytes.length === 0 || bytes.length > MOST_IMAGE_BYTES) {
    return { refused: `size ${bytes.length} bytes` };
  }
  const type = typeOf(bytes);
  return type ? { image: `data:${type};base64,${cleaned}` } : { refused: "not PNG or JPEG" };
}

const USED_UP = "Today's image reading has been used up. It resets at midnight UTC.";

// Only "couldn't read" blames the photo. A revoked token or Cloudflare's own
// daily quota is not the sheet's fault, and retrying it spends the budget.
function answerFor(error) {
  if (error.name === "TimeoutError") {
    return [504, "Reading that image took too long."];
  }
  if (error.upstreamStatus === 401 || error.upstreamStatus === 403) {
    return [503, "Image reading is not available."];
  }
  if (error.upstreamStatus === 429) {
    return [429, USED_UP];
  }
  return [502, "Unable to read that image."];
}

export function createTimetableRouter({ config, limit, budget, verifyAppCheck, fetchImpl }) {
  const router = Router();

  // The service runs for the Notion handshake whether or not this is set up,
  // so an unconfigured deployment says so plainly instead of failing at the
  // upstream call with something that reads like an outage.
  function configured(_request, response, next) {
    if (!config.vision) {
      response.status(503).json({ error: "Image reading is not available." });
      return;
    }
    next();
  }

  // Before the budget, so a caller that is not the app cannot spend it, and
  // before the body, so it cannot make the service buffer six megabytes either.
  async function attested(request, response, next) {
    if (!(await verifyAppCheck(request.get("X-Firebase-AppCheck")))) {
      response.status(401).json(INVALID);
      return;
    }
    next();
  }

  // Three a minute per caller. Reading a timetable is something a person does
  // once a term, so anything faster is a loop rather than a student. A base64
  // image is past express's 100kb default, so only this route gets more.
  const admitted = [
    limit("/timetable/read", 3),
    configured,
    attested,
    express.json({ limit: "6mb" }),
  ];

  router.post("/read", admitted, async (request, response) => {
    const body = request.body ?? {};
    const { image, refused } = imageIn(body.image);
    const text = typeof body.text === "string" ? body.text.slice(0, MOST_TEXT_LENGTH) : undefined;
    if (!image) {
      process.stderr.write(`Image refused: ${refused}\n`);
      response.status(400).json(INVALID);
      return;
    }

    if (!budget.take()) {
      response.status(429).json({ error: USED_UP });
      return;
    }

    try {
      const classes = await readTimetable({ image, text, ...config.vision }, fetchImpl);
      response.status(200).json({ classes });
    } catch (error) {
      // Covers the paths that reach here without having said anything — a
      // fetch that threw rather than answered, most of all.
      process.stderr.write(`Timetable read failed: ${failureOf(error)}\n`);
      const [status, message] = answerFor(error);
      response.status(status).json({ error: message });
    }
  });

  return router;
}
