import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/time_picker.dart';
import '../../data/models/room.dart';
import '../../data/models/tag.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/day_grid.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/undo_snack.dart';

/// Settings for the shape of the teaching day: when it starts, when it ends and
/// how long one lecture block runs.
///
/// Everything else about the grid follows from those three numbers, so this is
/// three controls rather than a list editor — and the preview underneath is
/// there because "50-minute blocks from 9 to 5" is easy to type and hard to
/// picture.
class DayGridSection extends ConsumerWidget {
  const DayGridSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final DayGrid grid = settings.dayGrid;
    final bool use24Hour = settings.use24HourTime;
    final SettingsController controller = ref.read(settingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('The teaching day'),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: _TimeField(
                      label: 'Day starts',
                      minutes: settings.dayStartMinutes,
                      use24Hour: use24Hour,
                      onChanged: (int value) => controller.save(
                        settings.copyWith(dayStartMinutes: value),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: _TimeField(
                      label: 'Day ends',
                      minutes: settings.dayEndMinutes,
                      use24Hour: use24Hour,
                      onChanged: (int value) => controller.save(
                        settings.copyWith(dayEndMinutes: value),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'One block is',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    settings.blockMinutes <= 0
                        ? 'Not set'
                        : Clock.formatDuration(settings.blockMinutes),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: context.palette.accent,
                      letterSpacing: -0.4,
                    ),
                  ),
                ],
              ),
              Slider(
                // Zero is a real state — "the day is not divided up" — so the
                // track starts one step below the shortest usable block and
                // that step clears the grid rather than setting a 5-minute one.
                value: settings.blockMinutes.toDouble().clamp(0, 180),
                max: 180,
                divisions: 36,
                label: settings.blockMinutes <= 0
                    ? 'Not divided'
                    : Clock.formatDuration(settings.blockMinutes),
                onChanged: (double value) {
                  final int minutes = (value / 5).round() * 5;
                  controller.save(
                    settings.copyWith(
                      blockMinutes: minutes < 15 ? 0 : minutes,
                    ),
                  );
                },
              ),
              if (grid.isConfigured) ...<Widget>[
                const SizedBox(height: AppSpacing.lg),
                _BreakField(grid: grid, settings: settings),
              ],
              _GridPreview(grid: grid, use24Hour: use24Hour),
            ],
          ),
        ),
      ],
    );
  }
}

/// A mid-day break, set as a length plus the block it follows rather than a
/// clock time, so it can only ever land on a boundary.
class _BreakField extends ConsumerWidget {
  const _BreakField({required this.grid, required this.settings});

  final DayGrid grid;
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SettingsController controller = ref.read(settingsProvider.notifier);
    final int maxAfter = grid.maxBreakAfterBlock;
    if (maxAfter < 1) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Break',
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              grid.hasBreak
                  ? Clock.formatDuration(settings.breakMinutes)
                  : 'None',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: context.palette.accent,
                letterSpacing: -0.4,
              ),
            ),
          ],
        ),
        Slider(
          value: settings.breakMinutes.toDouble().clamp(0, 90),
          max: 90,
          divisions: 18,
          label: settings.breakMinutes <= 0
              ? 'None'
              : Clock.formatDuration(settings.breakMinutes),
          onChanged: (double value) {
            final int minutes = (value / 5).round() * 5;
            controller.save(
              settings.copyWith(
                breakMinutes: minutes,
                // A length on its own would do nothing, so give it a position.
                breakAfterBlock: minutes > 0 && settings.breakAfterBlock < 1
                    ? (maxAfter + 1) ~/ 2
                    : settings.breakAfterBlock,
              ),
            );
          },
        ),
        if (settings.breakMinutes > 0) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: <Widget>[
              for (int block = 1; block <= maxAfter; block++)
                ChoiceChip(
                  label: Text('After $block'),
                  selected: settings.breakAfterBlock == block,
                  onSelected: (_) => controller.save(
                    settings.copyWith(breakAfterBlock: block),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Says in words and in ticks what the three numbers add up to.
class _GridPreview extends StatelessWidget {
  const _GridPreview({required this.grid, required this.use24Hour});

  final DayGrid grid;
  final bool use24Hour;

  @override
  Widget build(BuildContext context) {
    if (!grid.isConfigured) {
      return Text(
        'Drag the slider to divide the day into equal blocks — one lecture '
        'each. A class then takes up a whole number of blocks, so a lab twice '
        'the length of a lecture is two of them.',
        style: TextStyle(
          fontSize: 12,
          height: 1.4,
          color: context.palette.textTertiary,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: <Widget>[
            for (int i = 0; i < grid.blockCount; i++) ...<Widget>[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: context.palette.surfaceHigher,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: Text(
                  '${i + 1}  '
                  '${Clock.format(grid.startOf(i), use24Hour: use24Hour)}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: context.palette.textSecondary,
                  ),
                ),
              ),
              if (grid.hasBreak && i + 1 == grid.breakAfterBlock)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                    border: Border.all(color: context.palette.hairline),
                  ),
                  child: Text(
                    'Break  '
                    '${Clock.format(grid.breakStartMinutes, use24Hour: use24Hour)}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: context.palette.textTertiary,
                    ),
                  ),
                ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          <String>[
            if (grid.tailMinutes > 0)
              '${grid.blockCount - 1} blocks of '
                  '${Clock.formatDuration(grid.blockMinutes)}'
            else
              '${grid.blockCount} blocks of '
                  '${Clock.formatDuration(grid.blockMinutes)}',
            if (grid.tailMinutes > 0)
              'a last one of ${Clock.formatDuration(grid.tailMinutes)}',
            if (grid.hasBreak)
              '${Clock.formatDuration(grid.breakMinutes)} break after '
                  '${grid.breakAfterBlock}',
          ].join(' · '),
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: context.palette.textTertiary,
          ),
        ),
      ],
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.minutes,
    required this.use24Hour,
    required this.onChanged,
  });

  final String label;
  final int minutes;
  final bool use24Hour;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.palette.surfaceHigh,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        onTap: () async {
          final TimeOfDay? picked = await showAppTimePicker(
            context,
            initialTime: TimeOfDay(
              hour: Clock.hourOf(minutes),
              minute: Clock.minuteOf(minutes),
            ),
            use24Hour: use24Hour,
            helpText: label,
          );
          if (picked == null) return;
          onChanged(Clock.toMinutes(picked.hour, picked.minute));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.palette.textTertiary,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                Clock.format(minutes, use24Hour: use24Hour),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- rooms

/// The saved list of room numbers, offered wherever a room is entered.
class RoomsSection extends ConsumerWidget {
  const RoomsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Room> rooms =
        ref.watch(timetableProvider).value?.rooms ?? <Room>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionHeader(
          'Rooms',
          trailing: TextButton.icon(
            onPressed: () => _addRoom(context, ref),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add'),
          ),
        ),
        if (rooms.isEmpty)
          SurfaceCard(
            child: Text(
              'Add the rooms you have classes in and they turn into one-tap '
              'choices on every class. Typing a room by hand still works.',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: context.palette.textTertiary,
              ),
            ),
          )
        else
          SurfaceCard(
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                for (final Room room in rooms)
                  _RoomChip(
                    room: room,
                    onRename: () => _renameRoom(context, ref, room),
                    onDelete: () =>
                        ref.read(actionsProvider).deleteRoom(room.id!),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _addRoom(BuildContext context, WidgetRef ref) async {
    final String? name = await _promptRoomName(context, title: 'Add a room');
    if (name == null) return;
    await ref.read(actionsProvider).addRoom(Room(name: name));
  }

  Future<void> _renameRoom(
    BuildContext context,
    WidgetRef ref,
    Room room,
  ) async {
    final String? name = await _promptRoomName(
      context,
      title: 'Rename room',
      initial: room.name,
    );
    if (name == null) return;
    await ref.read(actionsProvider).updateRoom(room.copyWith(name: name));
  }
}

Future<String?> _promptRoomName(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  return showAppSheet<String>(
    context: context,
    title: title,
    child: SheetTextForm(
      initial: initial,
      submitLabel: 'Save',
      labelText: 'Room',
      hintText: 'e.g. LT-3, B204, Physics Lab',
      textCapitalization: TextCapitalization.characters,
    ),
  );
}

class _RoomChip extends StatelessWidget {
  const _RoomChip({
    required this.room,
    required this.onRename,
    required this.onDelete,
  });

  final Room room;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.palette.surfaceHigher,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: InkWell(
        onTap: onRename,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Container(
          padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4, right: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.place_outlined,
                size: 15,
                color: context.palette.textTertiary,
              ),
              const SizedBox(width: 6),
              Text(
                room.name,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              IconButton(
                onPressed: onDelete,
                icon: const Icon(Icons.close_rounded, size: 15),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                color: context.palette.textTertiary,
                tooltip: 'Forget ${room.name}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The user's attendance labels, managed the same way rooms are.
///
/// Deleting one is the only place this differs: a room is copied into a class
/// as text, so forgetting it changes nothing, while a tag is referenced by id
/// and marks point at it. So a tag in use says how many marks it would strip
/// before it goes.
class TagsSection extends ConsumerWidget {
  const TagsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Tag> tags = ref.watch(timetableProvider).value?.tags ?? <Tag>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionHeader(
          'Tags',
          trailing: TextButton.icon(
            onPressed: () => _addTag(context, ref),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add'),
          ),
        ),
        if (tags.isEmpty)
          SurfaceCard(
            child: Text(
              'A tag records how a class went, next to Present or Absent — '
              '"Proxy", "Online", "Makeup". Marking works exactly as it does '
              'now; a tag is optional and added afterwards.',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: context.palette.textTertiary,
              ),
            ),
          )
        else
          SurfaceCard(
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                for (final Tag tag in tags)
                  _TagChip(
                    tag: tag,
                    onRename: () => _renameTag(context, ref, tag),
                    onDelete: () => _confirmDelete(context, ref, tag),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _addTag(BuildContext context, WidgetRef ref) async {
    final String? name = await _promptTagName(context, title: 'Add a tag');
    if (name == null) return;
    await ref.read(actionsProvider).addTag(Tag(name: name));
  }

  Future<void> _renameTag(
    BuildContext context,
    WidgetRef ref,
    Tag tag,
  ) async {
    final String? name = await _promptTagName(
      context,
      title: 'Rename tag',
      initial: tag.name,
    );
    if (name == null) return;
    await ref.read(actionsProvider).updateTag(tag.copyWith(name: name));
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Tag tag,
  ) async {
    final int id = tag.id!;
    final TimetableActions actions = ref.read(actionsProvider);
    final int inUse = await actions.countMarksWithTag(id);
    if (!context.mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    if (inUse == 0) {
      await actions.deleteTag(id);
      showUndoSnack(messenger, actions, '${tag.name} deleted');
      return;
    }

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Delete ${tag.name}?'),
        content: Text(
          inUse == 1
              ? 'One class is tagged ${tag.name}. It keeps its Present or '
                  'Absent mark and simply loses the tag.'
              : '$inUse classes are tagged ${tag.name}. They keep their '
                  'Present or Absent marks and simply lose the tag.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await actions.deleteTag(id);
    showUndoSnack(messenger, actions, '${tag.name} deleted');
  }
}

Future<String?> _promptTagName(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  return showAppSheet<String>(
    context: context,
    title: title,
    child: SheetTextForm(
      initial: initial,
      submitLabel: 'Save',
      labelText: 'Tag',
      hintText: 'e.g. Proxy, Online, Makeup',
      textCapitalization: TextCapitalization.words,
    ),
  );
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.tag,
    required this.onRename,
    required this.onDelete,
  });

  final Tag tag;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.palette.surfaceHigher,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: InkWell(
        onTap: onRename,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Container(
          padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4, right: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.sell_outlined,
                size: 15,
                color: context.palette.textTertiary,
              ),
              const SizedBox(width: 6),
              Text(
                tag.name,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              IconButton(
                onPressed: onDelete,
                icon: const Icon(Icons.close_rounded, size: 15),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                color: context.palette.textTertiary,
                tooltip: 'Delete ${tag.name}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
