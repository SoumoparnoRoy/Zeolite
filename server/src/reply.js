// What the model says, turned into classes. Replies come back as the JSON
// asked for or as a markdown list, depending on the sheet (see vision.js),
// and both are read here.

// A week has 7 days and no sheet prints more than a few dozen periods; anything
// past this is a model that has started repeating itself.
const MOST_CLASSES = 250;

const DAYS = [
  ["monday", "mon", "mo"],
  ["tuesday", "tue", "tu"],
  ["wednesday", "wed", "we"],
  ["thursday", "thu", "th"],
  ["friday", "fri", "fr"],
  ["saturday", "sat", "sa"],
  ["sunday", "sun", "su"],
];

// A two-letter code is a day only where nothing else could be meant, as the
// first word: "FR201" is a subject and "we" is a word. Longer names count
// anywhere, as whole words.
const LEADING_DAY = new RegExp(String.raw`^(${DAYS.flat().join("|")})\b`, "i");
// Every form, for taking the day off the text before a time.
const ANY_DAY = new RegExp(String.raw`\b(${DAYS.flat().join("|")})\b`, "gi");
const NAMED_DAY = new RegExp(
  String.raw`\b(${DAYS.flatMap((names) => names.slice(0, 2)).join("|")})\b`,
  "i",
);

// The \b keeps "10:00 AMS101" from losing the start of its subject.
const MERIDIEM = String.raw`(?:\s*([ap])\.?m\b\.?)?`;
const CLOCK = new RegExp(String.raw`^\s*(\d{1,2})[:.](\d{2})${MERIDIEM}`, "i");
const SPAN = new RegExp(
  String.raw`(\d{1,2})[:.](\d{2})${MERIDIEM}\s*(?:-|–|—|to)\s*(\d{1,2})[:.](\d{2})${MERIDIEM}`,
  "i",
);
const BRACKETED = /^(.*?)[\s,]*\(([^)]*)\)[\s.]*$/;
const TRAILING = /^(.*?),\s*([^,\s]{1,12})[\s.]*$/;

function minutes(hour, minute, meridiem) {
  let h = Number(hour);
  const m = Number(minute);
  // "13:30 PM" says the same thing twice; past 12 the hour stands on its own.
  if (meridiem && h >= 1 && h <= 12) {
    h = (h % 12) + (meridiem.toLowerCase() === "p" ? 12 : 0);
  }
  return h > 23 || m > 59 ? undefined : h * 60 + m;
}

function clock(hour, minute, meridiem) {
  return meridiem ? `${hour}:${minute} ${meridiem}m` : `${hour}:${minute}`;
}

// "1:30-2:20 PM" is the afternoon: a meridiem printed once covers both ends,
// unless it would put the start after the end, as in "11:00-12:50 PM", which
// starts in the morning.
function endsOf(span) {
  const [, h1, m1, a1, h2, m2, a2] = span;
  const covers = (a) => minutes(h1, m1, a) < minutes(h2, m2, a);
  const start = a1 ?? (covers(a2) ? a2 : undefined);
  const end = a2 ?? (covers(a1) ? a1 : undefined);
  return [clock(h1, m1, start), clock(h2, m2, end)];
}

// Times come back as the printed string when asked for, and as a bare number
// when the model reverts to counting minutes itself. A bare number is taken as
// minutes after midnight, which is the only reading it can be given: 1000 is
// as plausibly 10:00 written without its colon as it is 16:40, and guessing
// between them silently would be worse than being consistent.
function timeOf(value) {
  if (typeof value === "string") {
    const found = CLOCK.exec(value);
    return found ? minutes(found[1], found[2], found[3]) : undefined;
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

function dayNamed(name) {
  return DAYS.findIndex((names) => names.includes(name.toLowerCase())) + 1;
}

// Also what moves the day on a line with no time, so "1. Monday" and "Day 2 -
// Tuesday" are headings while "Below we list the rest" stays prose.
function weekdayIn(text) {
  const found = LEADING_DAY.exec(text.trim()) ?? NAMED_DAY.exec(text);
  return found ? dayNamed(found[1]) : undefined;
}

// No sheet prints more columns than this, and nothing this small is a clock.
const MOST_PERIODS = 20;

function periodOf(value) {
  return Number.isInteger(value) && value >= 1 && value <= MOST_PERIODS ? value : undefined;
}

// A class arrives as the two times asked for or, now and then, as two column
// numbers, the shape an earlier prompt asked for and the model still falls back
// to. The app reads both. The two cannot be mistaken for each other:
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

// Entries arrive as positional tuples when the shape asked for in vision.js
// is followed, and sometimes with a sixth field for the teacher that nothing
// asked for.
//
// Undefined when there was no list at all. An empty list is an answer: the
// model looked and found no classes.
function fromJson(reply) {
  const parsed = typeof reply === "string" ? jsonIn(reply) : reply;
  const entries = Array.isArray(parsed?.classes) ? parsed.classes : undefined;
  if (!entries) {
    return undefined;
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
    const line = raw
      .replace(/[*#_`]/g, "")
      .replace(/^[\s\-•]+/, "")
      .trim();
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
      .replace(ANY_DAY, "")
      .replace(/[\s:,\-–—]+$/, "")
      .replace(/^[\s:,\-–—]+/, "")
      .trim();
    const subject = leadingName.length > 0 ? leadingName : trailingName;
    const room = leadingName.length > 0 && trailingRoom.length === 0 ? trailingName : trailingRoom;

    const [from, to] = endsOf(span);
    const one = classOf(subject, weekdayIn(before) ?? day, from, to, room);
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
  if (structured?.length > 0) {
    return structured;
  }
  const lines = typeof reply === "string" ? fromLines(reply) : [];
  return lines.length > 0 ? lines : structured;
}
