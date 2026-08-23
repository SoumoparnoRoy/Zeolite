<div align="center">

# Zeolite

**Know exactly how many classes you can afford to miss.**

A Flutter app for tracking university timetables and attendance. Add your
weekly schedule once, mark each class with one tap, and get a straight answer
before you skip a lecture.

[![Flutter](https://img.shields.io/badge/Flutter-3.38.1+-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.5+-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Riverpod](https://img.shields.io/badge/State-Riverpod%203-4B32C3)](https://riverpod.dev)
[![SQLite](https://img.shields.io/badge/DB-sqflite-003B57?logo=sqlite&logoColor=white)](https://pub.dev/packages/sqflite)
[![Platform](https://img.shields.io/badge/Platform-Android-3DDC84?logo=android&logoColor=white)](#)
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

</div>

---

Everything is stored locally on the device. No accounts, no server, no network
calls. It works on a train with no signal.

## Features

- **One-tap marking** - Present / Absent / Cancelled per class. Tapping the
  status a class already has clears it.
- **Weekly timetable that repeats** - enter a class once with several weekdays
  ticked, and every future week follows from it.
- **Forward-looking numbers** - not just your percentage, but how many classes
  you can still skip, how many you need to attend to recover, and whether the
  target is still reachable this term.
- **Per-subject targets** - override the global attendance requirement for any
  subject.
- **Attendance log** - every past class for a subject in one list, correctable
  in place.
- **Class categories** - Lab / Theory / Tutorial with default lengths, so
  picking a start time fills in the end time.
- **A day divided into blocks** - set when your day starts and ends and how long
  one lecture runs, and fill your timetable in on a grid instead of a form. A
  class takes up a whole number of blocks, so a double lab is two of them.
- **Saved rooms** - keep your room numbers once and pick them with a tap.
- **Holidays** - skipped everywhere and never counted against you.
- **Light and dark themes** - pick one or follow the device.
- **Notifications** - pre-class reminders, an evening nudge to mark what you
  forgot, and alerts when a subject nears its limit. A master switch silences
  all three.
- **JSON backup** - export to clipboard and file, import to restore.
- **Undo** - deleting a subject or a class, importing a timetable and marking a
  whole day all offer Undo until you change something else.

## Getting started

You need [Flutter](https://docs.flutter.dev/install) 3.38.1 or newer and an
Android device or emulator.

```bash
git clone https://github.com/SoumoparnoRoy/Zeolite.git
cd Zeolite
flutter pub get
flutter run
```

Android is the supported platform.

```bash
flutter analyze
flutter test
```

If the `android/` folder ever gets out of step with your Flutter version,
`tool/bootstrap.ps1` regenerates it and reapplies the two tweaks
`flutter_local_notifications` needs:

```powershell
powershell -ExecutionPolicy Bypass -File tool\bootstrap.ps1
```

## Screens

**Today** - a date strip and the day's classes as cards, each showing its time,
room, teacher and category. Past classes you never marked surface as a banner,
and "All present" marks a whole day at once. The grid button in the corner swaps
the day for the whole week laid out block by block; tapping an empty block adds a
class there, and long-pressing a class edits, cancels or removes it.

**Timetable** - the week laid out day by day. Add, edit or remove classes here.
Adding a weekly class lets you tick several weekdays at once, so "Mon/Wed/Fri
at 9" is one trip through the form.

**Attendance** - overall and per-subject percentages against your target, plus
the skip allowance, the recovery count, and whether the target is reachable.

**Settings** - semester dates, attendance target, subjects, the shape of the
teaching day, saved rooms, class categories, theme, notifications, holidays, and
JSON export/import.

### Removing a class

Long-pressing a class offers three options, because they mean different things
to your history:

| Action | Effect |
|---|---|
| Cancel just this class | One occurrence marked cancelled. Excluded from both sides of the percentage. |
| Stop repeating from this date | Sets the rule's end date. History is kept, future weeks disappear. |
| Delete this weekly class | Removes the rule and its future weeks. Attendance you already marked is kept and still counts. |

## How it works

A weekly class is stored as a **rule**, not a row per week. `ScheduleEngine`
expands rules into occurrences for whatever date range a screen asks for,
subtracting holidays and anything outside the semester, then adding one-off
classes and attaching attendance marks. Editing a rule reshapes every future
week instantly and the database stays small.

Dates are stored as `yyyymmdd` integers and times as minutes since midnight, so
neither drifts with timezones or daylight saving. Attendance marks are keyed by
`(subject, date, start time)` rather than by slot id, so a mark survives editing
the rule that produced it.

With `p` classes attended out of `h` held and a target `t`:

- **Percentage** - `p / h`, with cancelled classes excluded from both.
- **Can skip** - `⌊p / t⌋ − h`.
- **Must attend** - `⌈(t·h − p) / (1 − t)⌉`.

## Architecture

```
lib/
├── core/               design tokens, date and clock helpers
├── data/
│   ├── models/         Subject, ClassSlot, AttendanceRecord, Holiday, ...
│   ├── db/             SQLite schema and the repository
│   └── settings/       AppSettings + SharedPreferencesAsync
├── domain/             schedule engine, stats, attendance log
├── services/           notifications, JSON backup
├── state/              Riverpod providers and every mutation
├── features/           one folder per screen
└── widgets/            shared UI primitives
```

The UI never touches SQL and the domain layer never imports Flutter, so the
interesting logic is unit-testable without a device. `flutter test` runs 206
tests covering the schedule engine, the stats formulas, the attendance log, the
notification gating rules and the light palette's contrast ratios.

## Roadmap

- [ ] Home-screen widget showing today's classes
- [ ] Per-class notes and assignment deadlines
- [ ] Calendar heatmap of attendance over the term
- [ ] Optional cloud sync

## License

Released under the [MIT License](LICENSE). © 2026 Soumoparno Roy.
