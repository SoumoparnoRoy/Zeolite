import '../../services/backup_service.dart';

/// One question on Help and FAQ. [id] is what Settings search opens the
/// screen at, so it stays put when the wording changes.
class HelpQuestion {
  const HelpQuestion(this.id, this.question, this.answer, [this.words = '']);

  final String id;
  final String question;
  final String answer;

  /// Other words people search with, the same as on a Settings topic.
  final String words;
}

class HelpSection {
  const HelpSection(this.title, this.questions);

  final String title;
  final List<HelpQuestion> questions;
}

// Every answer here was checked against the code it describes. When that code
// changes, so does the answer: the store listing words it the same way.
const List<HelpSection> helpSections = <HelpSection>[
  HelpSection('Skipping classes', <HelpQuestion>[
    HelpQuestion(
      'skip-now',
      'What does "classes you can skip" mean?',
      'How many classes in a row you could miss from now and still be at '
          'your minimum. It counts the classes held so far, so it answers '
          '"can I skip the next one?". The overall figure is your tightest '
          "subject's: a good average doesn't help a subject that's on its "
          'limit.',
      'miss bunk spare absent',
    ),
    HelpQuestion(
      'skip-budget',
      'What is the skip budget?',
      'The Plan view looks ahead to the end of the term: of the classes still '
          'to come, how many you can miss and still finish on target. It needs '
          'your term dates, or a term total for the subject. Each subject has '
          "its own budget; a spare class in one can't cover a miss in another.",
      'plan term miss bunk',
    ),
    HelpQuestion(
      'skip-differ',
      "Why don't the two numbers match?",
      '"Classes you can skip" looks only at what has happened so far. The '
          'skip budget also counts the classes still ahead, so it is often '
          'larger. Both are right; they answer different questions.',
      'skip budget different wrong',
    ),
    HelpQuestion(
      'below-minimum',
      "What if I'm below my minimum?",
      'The subject tells you how many classes in a row bring it back. If '
          "attending everything left this term still can't get there, it says "
          'the target is out of reach.',
      'target recover catch up out of reach',
    ),
  ]),
  HelpSection('Targets and class categories', <HelpQuestion>[
    HelpQuestion(
      'target-scope',
      'Is the target per subject or overall?',
      'The minimum at the top of Settings applies to every subject. To give '
          'one subject a different target, edit the subject and turn on Custom '
          'attendance target.',
      'minimum percentage custom',
    ),
    HelpQuestion(
      'categories',
      'What do class categories do?',
      'A category, such as Lab, says how much each of its classes counts, '
          'from 0 (held but not counted) up to 3. Miss a class worth 2 and it '
          'counts as two missed. Where any class counts more than once, that '
          'subject counts in periods instead of classes.',
      'weight lab practical periods counts',
    ),
    HelpQuestion(
      'cancelled',
      'Do cancelled classes count?',
      "Not by default: they're left out of your percentage. If your "
          'institution counts them as attended, turn on Cancelled classes '
          'count as attended in Term.',
      'cancel',
    ),
  ]),
  HelpSection('Marking', <HelpQuestion>[
    HelpQuestion(
      'mark',
      'How do I mark a class?',
      'On Today, tap Present, Absent or Cancelled. A marked class shrinks to '
          'one line; tap it to bring the buttons back and change the mark. Tap '
          'the status it already has to clear it.',
      'present absent attendance change',
    ),
    HelpQuestion(
      'tags',
      'What are tags for?',
      'A tag, such as Proxy or Online, notes why a mark is what it is. Manage '
          'your tags in Rooms and tags.',
      'proxy online label',
    ),
    HelpQuestion(
      'undo',
      'Can I undo a mistake?',
      'Yes. Clearing a mark or using All present shows Undo for a few '
          'seconds, and so does deleting a subject or a class.',
      'mistake wrong revert',
    ),
  ]),
  HelpSection('Bringing your timetable in', <HelpQuestion>[
    HelpQuestion(
      'import',
      'What can I import?',
      'Paste a timetable as text, or read one from a photo; the photo is read '
          'on your phone. A CSV class log or a Notion export brings in what '
          "you've already attended. Both are under Add from a file.",
      'paste photo csv notion timetable',
    ),
    HelpQuestion(
      'ai-check',
      'When does the AI check ask first?',
      "Only when some times on a photographed sheet couldn't be read with "
          'confidence. It asks every time, and nothing is sent unless you tap '
          "Check with AI. The image goes to Zeolite's server, an AI reads it, "
          "and then it's deleted.",
      'photo image sent',
    ),
  ]),
  HelpSection('Sync and Notion', <HelpQuestion>[
    HelpQuestion(
      'account',
      'Do I need an account?',
      'No. Everything works offline without one. Signing in keeps two devices '
          'in step and backs your records up to your account. Nothing syncs '
          'until you tap Sync now, unless you turn on Sync automatically.',
      'sign in sync offline devices',
    ),
    HelpQuestion(
      'notion',
      'How does Notion sync work?',
      'Connect your own Notion workspace and Zeolite writes your classes to a '
          'table there when it syncs: when you tap Sync now, or on its own if '
          "you turn on Sync automatically. It's optional, and nothing goes to "
          'Notion until you connect.',
      'workspace table',
    ),
    HelpQuestion(
      'under-18',
      'Why are Account and Notion greyed out?',
      'Accounts, Notion and the AI check are for users 18 and over. Under 18, '
          'everything stays on this device. If you answered the age question '
          'yourself, you can change it in Privacy choices.',
      'age disabled unavailable',
    ),
  ]),
  HelpSection('Backups', <HelpQuestion>[
    HelpQuestion(
      'backup',
      'How do I back up?',
      'In Your data, Export backup saves a file you can keep anywhere. '
          'Automatic backup saves one each day and keeps the last '
          '${BackupService.keepAutoBackups}, in a folder you choose.',
      'export save file',
    ),
    HelpQuestion(
      'restore',
      'How do I restore a backup?',
      'Tap Import backup and pick the file. Everything in the app is replaced '
          "by what's in the backup, so export first if you want to keep what's "
          'there now.',
      'import file',
    ),
  ]),
  HelpSection('Reminders and widgets', <HelpQuestion>[
    HelpQuestion(
      'reminders',
      'Which reminders are there?',
      'One before each class, one when each class ends with Present and '
          'Absent on it, an evening reminder when something is left unmarked, '
          'and an alert when a subject nears its limit. Turn each on or off in '
          'Notifications.',
      'notifications alerts',
    ),
    HelpQuestion(
      'reminder-late',
      'Why did a reminder come late, or not at all?',
      'Open Notifications in Settings. If it says Blocked in Android settings, '
          'tap it to allow them. Turn on Exact timing for reminders on the '
          'minute.',
      'notifications missing blocked',
    ),
    HelpQuestion(
      'widgets',
      'How do I add a widget?',
      'On most phones, touch and hold the home screen, choose Widgets, then '
          'Zeolite. Today lets you mark classes there, This week shows the '
          'timetable, and Attendance shows where you stand.',
      'home screen',
    ),
  ]),
  HelpSection('Privacy', <HelpQuestion>[
    HelpQuestion(
      'shared',
      'What does Zeolite share?',
      'Usage statistics and crash reports are off until you say yes in '
          'Privacy choices, and you can change either at any time. No ads, no '
          'advertising ID. Your classes leave the device only if you sign in, '
          'connect Notion or agree to an AI check.',
      'data analytics crash reports privacy',
    ),
  ]),
];

Iterable<HelpQuestion> get helpQuestions =>
    helpSections.expand((HelpSection s) => s.questions);
