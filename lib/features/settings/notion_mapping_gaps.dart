import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/class_category.dart';
import '../../domain/notion/notion_mapping.dart';
import '../../state/notion_providers.dart';
import '../../state/providers.dart';
import 'notion_mapping_screen.dart';

/// Whether the stored mapping still has anything worth asking about. Adopting
/// is gated on three columns, so a drifted schema saves with the rest unset.
bool notionMappingHasGaps(WidgetRef ref) {
  final NotionMapping? mapping = ref.read(notionMappingProvider).value;
  if (mapping == null) return false;

  final List<ClassCategory> categories =
      ref.read(timetableProvider).value?.categories ?? const <ClassCategory>[];
  return mapping.unmapped(
    categoryNames: <String>[
      for (final ClassCategory category in categories) category.name,
    ],
  ).isNotEmpty;
}

MaterialPageRoute<void> notionMappingGapsRoute() => MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'notion_mapping'),
      builder: (BuildContext context) =>
          const NotionMappingScreen(onlyUnmapped: true),
    );
