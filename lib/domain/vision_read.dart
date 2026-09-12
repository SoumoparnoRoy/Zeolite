/// Why a second-opinion read did not produce classes. The caller has to tell
/// "ask again later" from "this will never work here", because the two say
/// different things to the student and only one is worth a retry.
enum VisionFailure {
  /// The deployment has no Workers AI credentials. Permanent for this build.
  unavailable,

  /// The shared daily allocation is spent, or this device asked too fast.
  busy,

  /// The service or the provider failed. Nothing about which reaches here.
  failed,

  /// No network, or the host did not wake in time.
  offline,

  /// The call worked and the model found nothing readable in the image.
  unreadable,
}

/// A class the model found, before it has been placed on the grid.
///
/// Two spellings of when, because the route returns whichever the model gave:
/// [first]/[last] are period column numbers, which place exactly, and
/// [from]/[to] are minutes after midnight, which have to be snapped. Exactly
/// one pair is set.
class VisionClass {
  const VisionClass({
    required this.subject,
    required this.weekday,
    this.room,
    this.first,
    this.last,
    this.from,
    this.to,
  });

  factory VisionClass.fromJson(Map<String, Object?> json) => VisionClass(
        subject: (json['subject'] as String?)?.trim() ?? '',
        weekday: json['weekday'] as int? ?? 0,
        room: (json['room'] as String?)?.trim(),
        first: json['first'] as int?,
        last: json['last'] as int?,
        from: json['from'] as int?,
        to: json['to'] as int?,
      );

  final String subject;
  final int weekday;
  final String? room;
  final int? first;
  final int? last;
  final int? from;
  final int? to;

  bool get byColumn => first != null && last != null;

  /// The server validates all of this too. Repeated here because a reply that
  /// changes shape must not reach the grid maths as a half-built entry.
  bool get isUsable =>
      subject.isNotEmpty &&
      weekday >= 1 &&
      weekday <= 7 &&
      (byColumn || (from != null && to != null && to! > from!));
}

/// What a call produced: the classes, or the reason there are none.
class VisionRead {
  const VisionRead.done(this.classes) : failure = null;

  const VisionRead.failed(this.failure) : classes = const <VisionClass>[];

  final List<VisionClass> classes;
  final VisionFailure? failure;

  bool get ok => failure == null;
}
