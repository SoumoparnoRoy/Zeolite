const RUN_URL = "https://api.cloudflare.com/client/v4/accounts";

// The default is 256, which truncates a full week mid-array and reads as a
// malformed reply rather than a long one.
const MAX_TOKENS = 2048;

// A week has 7 days and no sheet prints more than a few dozen periods; anything
// past this is a model that has started repeating itself.
const MOST_CLASSES = 250;

const WEEKDAYS = { min: 1, max: 7 };
const MINUTES = { min: 0, max: 24 * 60 - 1 };

const INSTRUCTION = [
  "You read a university timetable image and return only JSON.",
  'Shape: {"classes":[[subject,weekday,from,to,room]]}.',
  "subject is the code or name printed in the cell.",
  "weekday is 1 for Monday through 7 for Sunday.",
  "from and to are minutes after midnight, so 09:10 is 550.",
  "room is the room printed with the class, or null.",
  "A class spanning two periods is one entry covering both.",
  "Ignore legends, footers, lunch breaks and free slots.",
  "Return no prose, no markdown and no explanation.",
].join(" ");

// Sent alongside the image rather than instead of it. It costs a fraction of
// what the reply costs, and it settles characters the model would otherwise
// guess at — the picture carries the layout, this carries the spelling.
function withTranscript(text) {
  if (!text) {
    return "Read this timetable.";
  }
  return `Read this timetable. Text recognition on the same image found:\n${text}`;
}

// `messages` and `image` sit side by side, and the image is a base64 data URI
// rather than the byte array the schema reads as if it wants. An array of a
// hundred thousand numbers is rejected in about two seconds.
function requestBody(image, text) {
  return {
    messages: [
      { role: "system", content: INSTRUCTION },
      { role: "user", content: withTranscript(text) },
    ],
    image,
    max_tokens: MAX_TOKENS,
    // Extraction, not writing: the same sheet should read the same way twice.
    temperature: 0,
  };
}

// Models wrap JSON in prose or a fence however firmly they are told not to.
function jsonIn(text) {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) {
    return undefined;
  }
  try {
    return JSON.parse(text.slice(start, end + 1));
  } catch {
    return undefined;
  }
}

function whole(value, { min, max }) {
  return Number.isInteger(value) && value >= min && value <= max;
}

function classFrom(entry) {
  if (!Array.isArray(entry) || entry.length < 4) {
    return undefined;
  }
  const [subject, weekday, from, to, room] = entry;
  if (typeof subject !== "string" || subject.trim().length === 0 || subject.length > 60) {
    return undefined;
  }
  if (!whole(weekday, WEEKDAYS) || !whole(from, MINUTES) || !whole(to, MINUTES)) {
    return undefined;
  }
  if (to <= from) {
    return undefined;
  }
  const named = typeof room === "string" && room.trim().length > 0 && room.length <= 30;
  return { subject: subject.trim(), weekday, from, to, room: named ? room.trim() : null };
}

// Bad entries are dropped rather than failing the whole read: a model that
// fumbles one cell of forty has still saved the work of forty.
export function classesIn(text) {
  const parsed = jsonIn(text);
  const entries = Array.isArray(parsed?.classes) ? parsed.classes : undefined;
  if (!entries) {
    return undefined;
  }
  const classes = [];
  for (const entry of entries.slice(0, MOST_CLASSES)) {
    const one = classFrom(entry);
    if (one) {
      classes.push(one);
    }
  }
  return classes;
}

export async function readTimetable(
  { image, text, accountId, apiToken, model },
  fetchImpl = globalThis.fetch,
) {
  const response = await fetchImpl(
    `${RUN_URL}/${encodeURIComponent(accountId)}/ai/run/${model}`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(requestBody(image, text)),
    },
  );

  // Details stay server-side rather than being discarded: the caller learns
  // nothing, and whoever is holding the logs learns why.
  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    process.stderr.write(`Workers AI ${response.status}: ${detail.slice(0, 400)}\n`);
    throw new Error("Workers AI request failed");
  }

  const body = await response.json();
  const reply = body?.result?.response ?? "";
  const classes = classesIn(reply);
  if (!classes) {
    // Bounded on purpose. A reply that failed to parse is usually prose about
    // the image, and the opening of it is enough to see why — but it is read
    // off someone's timetable, so only the opening goes anywhere.
    process.stderr.write(
      `Workers AI reply unparseable (${reply.length} chars): ${reply.slice(0, 300)}\n`,
    );
    throw new Error("Workers AI returned no readable timetable");
  }
  return classes;
}
