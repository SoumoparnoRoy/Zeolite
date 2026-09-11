const RUN_URL = "https://api.cloudflare.com/client/v4/accounts";

// The default is 256, which cuts a week off partway and arrives looking like a
// malformed reply rather than a long one. The ceiling also bounds how long the
// model can run: given 4096 it talked itself into Cloudflare's own timeout.
const MAX_TOKENS = 2048;

// A week has 7 days and no sheet prints more than a few dozen periods; anything
// past this is a model that has started repeating itself.
const MOST_CLASSES = 250;

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

const DAYS = [
  ["monday", "mon", "mo"],
  ["tuesday", "tue", "tu"],
  ["wednesday", "wed", "we"],
  ["thursday", "thu", "th"],
  ["friday", "fri", "fr"],
  ["saturday", "sat", "sa"],
  ["sunday", "sun", "su"],
];

const CLOCK = /^\s*(\d{1,2})[:.](\d{2})/;
const SPAN = /(\d{1,2})[:.](\d{2})\s*(?:-|–|—|to)\s*(\d{1,2})[:.](\d{2})/;
const BRACKETED = /^(.*?)[\s,]*\(([^)]*)\)[\s.]*$/;
const TRAILING = /^(.*?),\s*([^,\s]{1,12})[\s.]*$/;

function minutes(hour, minute) {
  const h = Number(hour);
  const m = Number(minute);
  return h > 23 || m > 59 ? undefined : h * 60 + m;
}

// Times come back as the printed string when asked for, and as a bare number
// when the model reverts to counting minutes itself. A bare number is taken as
// minutes after midnight, which is the only reading it can be given: 1000 is
// as plausibly 10:00 written without its colon as it is 16:40, and guessing
// between them silently would be worse than being consistent.
function timeOf(value) {
  if (typeof value === "string") {
    const clock = CLOCK.exec(value);
    return clock ? minutes(clock[1], clock[2]) : undefined;
  }
  if (Number.isInteger(value) && value >= 0 && value <= 24 * 60 - 1) {
    return value;
  }
  return undefined;
}

function weekdayOf(value) {
  if (Number.isInteger(value) && value >= 1 && value <= 7) {
    return value;
  }
  return typeof value === "string" ? weekdayIn(value) : undefined;
}

function weekdayIn(line) {
  const words = line.toLowerCase().match(/[a-z]+/g) ?? [];
  for (let day = 0; day < DAYS.length; day++) {
    if (words.some((word) => DAYS[day].includes(word))) {
      return day + 1;
    }
  }
  return undefined;
}

// No sheet prints more columns than this, and nothing this small is a clock.
const MOST_PERIODS = 20;

function periodOf(value) {
  return Number.isInteger(value) && value >= 1 && value <= MOST_PERIODS
    ? value
    : undefined;
}

// A class arrives either as the two column numbers asked for or, when the model
// reverts to clocks, as two times. The two cannot be mistaken for each other:
// a period is at most 20 and a time is minutes after midnight, so the smallest
// clock this would accept is still an order of magnitude larger.
function classOf(subject, weekday, first, second, room) {
  const named = typeof subject === "string" ? subject.trim() : "";
  const day = weekdayOf(weekday);
  if (named.length === 0 || named.length > 60 || day === undefined) {
    return undefined;
  }
  const where = typeof room === "string" ? room.trim() : "";
  const at = {
    subject: named,
    weekday: day,
    room: where.length > 0 && where.length <= 30 ? where : null,
  };

  const from = periodOf(first);
  const to = periodOf(second);
  if (from !== undefined && to !== undefined) {
    return to < from ? undefined : { ...at, first: from, last: to };
  }

  const start = timeOf(first);
  const end = timeOf(second);
  if (start === undefined || end === undefined || end <= start) {
    return undefined;
  }
  return { ...at, from: start, to: end };
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

// Entries arrive as positional tuples when the shape above is followed, and
// sometimes with a sixth field for the teacher that nothing asked for.
function fromJson(reply) {
  const parsed = typeof reply === "string" ? jsonIn(reply) : reply;
  const entries = Array.isArray(parsed?.classes) ? parsed.classes : undefined;
  if (!entries) {
    return [];
  }
  const classes = [];
  for (const entry of entries.slice(0, MOST_CLASSES)) {
    const one = Array.isArray(entry)
      ? classOf(entry[0], entry[1], entry[2], entry[3], entry[4])
      : classOf(
          entry?.subject,
          entry?.weekday,
          entry?.firstPeriod ?? entry?.period ?? entry?.from,
          entry?.lastPeriod ?? entry?.period ?? entry?.to,
          entry?.room,
        );
    if (one) {
      classes.push(one);
    }
  }
  return classes;
}

// The room is printed either in brackets or after a comma, depending on how the
// model feels about the sheet. A comma only counts when what follows looks like
// a room rather than the rest of a sentence, and where brackets hold both a room
// and a teacher the room comes first.
function split(rest) {
  const bracketed = BRACKETED.exec(rest);
  if (bracketed) {
    return { subject: bracketed[1].trim(), room: bracketed[2].split(",")[0].trim() };
  }
  const trailing = TRAILING.exec(rest);
  if (trailing) {
    return { subject: trailing[1].trim(), room: trailing[2].trim() };
  }
  return { subject: rest.trim(), room: "" };
}

// A line at a time, ignoring everything that is not one. A heading, an apology
// or a closing remark simply fails to be a class, which is what makes this
// tolerant of a reply that was never going to be JSON.
function fromLines(text) {
  const classes = [];
  let day;

  for (const raw of text.split("\n")) {
    const line = raw.replace(/[*#_`]/g, "").replace(/^[\s\-•]+/, "").trim();
    if (line.length === 0) {
      continue;
    }

    const span = SPAN.exec(line);
    if (!span) {
      day = weekdayIn(line) ?? day;
      continue;
    }

    // A line naming its own day beats whatever heading came before it.
    const before = line.slice(0, span.index);
    const rest = line.slice(span.index + span[0].length).replace(/^[\s:,\-–—]+/, "");
    const { subject: trailingName, room: trailingRoom } = split(rest);

    // The subject sits on whichever side of the time the model felt like:
    // "9:10-10:00: SUBJECT (room)" reading the image alone, "SUBJECT: 9:10-10:00
    // (room)" once a transcript is there to read from. A name before the time is
    // unambiguous, so it wins, and whatever trails the time is then the room.
    const leadingName = before
      .replace(new RegExp(`\\b(${DAYS.flat().join("|")})\\b`, "gi"), "")
      .replace(/[\s:,\-–—]+$/, "")
      .replace(/^[\s:,\-–—]+/, "")
      .trim();
    const subject = leadingName.length > 0 ? leadingName : trailingName;
    const room = leadingName.length > 0 && trailingRoom.length === 0
      ? trailingName
      : trailingRoom;

    const one = classOf(
      subject,
      weekdayIn(before) ?? day,
      `${span[1]}:${span[2]}`,
      `${span[3]}:${span[4]}`,
      room,
    );
    if (one) {
      classes.push(one);
    }
    if (classes.length >= MOST_CLASSES) {
      break;
    }
  }

  return classes;
}

export function classesIn(reply) {
  const structured = fromJson(reply);
  if (structured.length > 0) {
    return structured;
  }
  const lines = typeof reply === "string" ? fromLines(reply) : [];
  return lines.length > 0 ? lines : undefined;
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
    const shown = typeof reply === "string" ? reply : JSON.stringify(reply);
    process.stderr.write(
      `Workers AI reply unparseable (${shown.length} chars): ${shown.slice(0, 300)}\n`,
    );
    throw new Error("Workers AI returned no readable timetable");
  }
  return classes;
}
