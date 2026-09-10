import { Router } from "express";
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

function imageIn(value) {
  if (typeof value !== "string" || value.length === 0) {
    return undefined;
  }
  const cleaned = value.replace(/\s+/g, "");
  if (!BASE64_PATTERN.test(cleaned)) {
    return undefined;
  }
  const bytes = Buffer.from(cleaned, "base64");
  if (bytes.length === 0 || bytes.length > MOST_IMAGE_BYTES) {
    return undefined;
  }
  const type = typeOf(bytes);
  return type ? `data:${type};base64,${cleaned}` : undefined;
}

export function createTimetableRouter({ config, limit, budget, fetchImpl }) {
  const router = Router();

  // Three a minute per caller. Reading a timetable is something a person does
  // once a term, so anything faster is a loop rather than a student.
  router.post("/read", limit("/timetable/read", 3), async (request, response) => {
    // The service runs for the Notion handshake whether or not this is set up,
    // so an unconfigured deployment says so plainly instead of failing at the
    // upstream call with something that reads like an outage.
    if (!config.vision) {
      response.status(503).json({ error: "Image reading is not available." });
      return;
    }

    const body = request.body ?? {};
    const image = imageIn(body.image);
    const text = typeof body.text === "string" ? body.text.slice(0, MOST_TEXT_LENGTH) : undefined;
    if (!image) {
      response.status(400).json(INVALID);
      return;
    }

    if (!budget.take()) {
      response.status(429).json({
        error: "Today's image reading has been used up. It resets at midnight UTC.",
      });
      return;
    }

    try {
      const classes = await readTimetable(
        { image, text, ...config.vision },
        fetchImpl,
      );
      response.status(200).json({ classes });
    } catch (error) {
      // Covers the paths that reach here without having said anything — a
      // fetch that threw rather than answered, most of all.
      process.stderr.write(`Timetable read failed: ${error.message}\n`);
      response.status(502).json({ error: "Unable to read that image." });
    }
  });

  return router;
}
