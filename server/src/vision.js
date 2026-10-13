import { classesIn } from "./reply.js";

const RUN_URL = "https://api.cloudflare.com/client/v4/accounts";

// The default is 256, which cuts a week off partway and arrives looking like a
// malformed reply rather than a long one. The ceiling also bounds how long the
// model can run: given 4096 it talked itself into Cloudflare's own timeout.
const MAX_TOKENS = 2048;

// The times this returns are not usable and asking differently does not help:
// minutes after midnight come back with no relationship to the sheet, quoted
// clocks get merged into one field, and asked instead for the numbered column a
// class sits under — a digit printed in the sheet's own header — it places only
// about five of twenty-one correctly. Position is what this model cannot do, in
// any coordinate system. What it gets right, given the transcript, is which
// classes exist: subject, room and weekday. Whoever wires this up should take
// those and get the times from the grid on the device.
//
// Whether this is answered in JSON depends on the sheet, not on the asking. A
// page carrying a legend and a footer gets a markdown list back however firmly
// JSON is demanded, and a declared JSON schema does not bind it either; the
// same page cropped to the table alone answers in the JSON asked for. Both
// shapes are parsed below, because both are what actually comes back.
//
// The wording still earns its place: put as a request for JSON the model reads
// the sheet carefully, and reworded as a format instruction it reads it worse.
const INSTRUCTION = [
  "You read a university timetable image and return only JSON.",
  'Shape: {"classes":[[subject,weekday,from,to,room]]}.',
  "subject is the code or name printed in the cell.",
  "weekday is 1 for Monday through 7 for Sunday.",
  "from and to are minutes after midnight, so 09:10 is 550.",
  "room is the room printed with the class, or null.",
  "A class spanning two periods is one entry covering both.",
  "Some cells are empty. Do not invent a class for them.",
  "Ignore legends, footers, lunch breaks and free slots.",
  "Return no prose, no markdown and no explanation.",
].join(" ");

// The transcript rides with the image rather than replacing it. It costs a
// fraction of what the reply costs, and it is what stops the model filling
// every cell of the grid: the picture carries the layout, this carries what is
// actually written in it.
function prompt(text) {
  if (!text) {
    return "Read this timetable.";
  }
  return `Read this timetable. Text recognition on the same image found:\n${text}`;
}

// `messages` and `image` sit side by side, and the image is a base64 data URI
// rather than the byte array the schema reads as if it wants. An array of a
// hundred thousand numbers is rejected in about two seconds.
//
// Both turns are required: with only a user turn, attaching the image fails
// outright with "Unable to add image when there are no user-supplied nor
// system-supplied messages".
function requestBody(image, text) {
  return {
    messages: [
      { role: "system", content: INSTRUCTION },
      { role: "user", content: prompt(text) },
    ],
    image,
    max_tokens: MAX_TOKENS,
    // Extraction, not writing: the same sheet should read the same way twice.
    temperature: 0,
  };
}

// The app waits 120 seconds and a dense sheet takes up to about 115, so this
// sits just under the app's limit: the student gets the server's answer rather
// than a timeout of their own while the model is still working.
export const VISION_TIMEOUT_MS = 110_000;

export async function readTimetable(
  { image, text, accountId, apiToken, model, timeoutMs = VISION_TIMEOUT_MS },
  fetchImpl = globalThis.fetch,
) {
  const response = await fetchImpl(`${RUN_URL}/${encodeURIComponent(accountId)}/ai/run/${model}`, {
    method: "POST",
    signal: AbortSignal.timeout(timeoutMs),
    headers: {
      Authorization: `Bearer ${apiToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(requestBody(image, text)),
  });

  if (!response.ok) {
    process.stderr.write(`Workers AI request failed (${response.status})\n`);
    const error = new Error("Workers AI request failed");
    error.upstreamStatus = response.status;
    throw error;
  }

  // Nothing from upstream is logged, and a parse error would quote the reply.
  const body = await response.json().catch(() => {
    throw new Error(`Workers AI sent a reply that is not JSON (${response.status})`);
  });
  const reply = body?.result?.response;
  if (reply === undefined || reply === null) {
    process.stderr.write("Workers AI reply has no response field\n");
    throw new Error("Workers AI reply has no response field");
  }
  const classes = classesIn(reply);
  if (!classes) {
    const length = typeof reply === "string" ? reply.length : JSON.stringify(reply).length;
    process.stderr.write(`Workers AI reply unparseable (${length} chars)\n`);
    throw new Error("Workers AI returned no readable timetable");
  }
  return classes;
}
