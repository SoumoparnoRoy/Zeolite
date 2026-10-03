import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

import 'settings_rows.dart';

/// One package and every licence that names it.
class PackageLicences {
  const PackageLicences(this.package, this.entries);

  final String package;
  final List<LicenseEntry> entries;
}

/// An entry can cover several packages, and then it is listed under each.
Future<List<PackageLicences>> groupLicences(Stream<LicenseEntry> source) async {
  final Map<String, List<LicenseEntry>> byPackage =
      <String, List<LicenseEntry>>{};
  await for (final LicenseEntry entry in source) {
    for (final String package in entry.packages) {
      (byPackage[package] ??= <LicenseEntry>[]).add(entry);
    }
  }
  return <PackageLicences>[
    for (final MapEntry<String, List<LicenseEntry>> e in byPackage.entries)
      PackageLicences(e.key, e.value),
  ]..sort((PackageLicences a, PackageLicences b) =>
      a.package.toLowerCase().compareTo(b.package.toLowerCase()));
}

String _count(int n) => n == 1 ? '1 licence' : '$n licences';

/// Our own page over Flutter's registry, so it reads like the rest of
/// Settings rather than like a framework screen.
class LicencesScreen extends StatefulWidget {
  const LicencesScreen({super.key});

  @override
  State<LicencesScreen> createState() => _LicencesScreenState();
}

class _LicencesScreenState extends State<LicencesScreen> {
  final Future<List<PackageLicences>> _all =
      groupLicences(LicenseRegistry.licenses);
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PushScaffold(
      title: 'Open-source licences',
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          sliver: SliverToBoxAdapter(
            child: FutureBuilder<List<PackageLicences>>(
              future: _all,
              builder: (BuildContext context,
                  AsyncSnapshot<List<PackageLicences>> snapshot) {
                final List<PackageLicences>? all = snapshot.data;
                if (all == null) {
                  return const Padding(
                    padding: EdgeInsets.all(AppSpacing.xxl),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SettingsSearchField(
                      controller: _search,
                      hint: 'Search ${all.length} packages',
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _search,
                      builder: (BuildContext context, TextEditingValue v, _) =>
                          _PackageList(
                        packages: <PackageLicences>[
                          for (final PackageLicences p in all)
                            if (p.package
                                .toLowerCase()
                                .contains(v.text.trim().toLowerCase()))
                              p,
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _PackageList extends StatelessWidget {
  const _PackageList({required this.packages});

  final List<PackageLicences> packages;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    if (packages.isEmpty) {
      return const SurfaceCard(child: SettingsHint('No package by that name.'));
    }
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: <Widget>[
          for (int i = 0; i < packages.length; i++) ...<Widget>[
            if (i > 0) const Divider(indent: 16),
            InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: 'licence'),
                  builder: (BuildContext context) =>
                      _PackageScreen(packages[i]),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            packages[i].package,
                            style: TextStyle(
                              fontSize: AppType.bodyMedium,
                              fontWeight: FontWeight.w700,
                              color: p.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _count(packages[i].entries.length),
                            style: TextStyle(
                              fontSize: AppType.captionLarge,
                              color: p.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: p.textFaint,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PackageScreen extends StatelessWidget {
  const _PackageScreen(this.licences);

  final PackageLicences licences;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    // Flattened, so a package with dozens of licences is still built lazily.
    final List<Widget?> items = <Widget?>[
      for (int e = 0; e < licences.entries.length; e++) ...<Widget?>[
        if (e > 0) null,
        for (final LicenseParagraph para in licences.entries[e].paragraphs)
          _Paragraph(para),
      ],
    ];

    return PushScaffold(
      title: licences.package,
      subtitle: _count(licences.entries.length),
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          sliver: SliverList.builder(
            itemCount: items.length,
            itemBuilder: (BuildContext context, int i) =>
                items[i] ??
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                  child: Divider(color: p.outline),
                ),
          ),
        ),
      ],
    );
  }
}

class _Paragraph extends StatelessWidget {
  const _Paragraph(this.paragraph);

  final LicenseParagraph paragraph;

  @override
  Widget build(BuildContext context) {
    final bool centred = paragraph.indent == LicenseParagraph.centeredIndent;
    return Padding(
      padding: EdgeInsets.only(
        top: 8,
        left: centred ? 0 : 14.0 * paragraph.indent,
      ),
      child: Text(
        paragraph.text,
        textAlign: centred ? TextAlign.center : TextAlign.start,
        style: TextStyle(
          fontSize: AppType.labelLarge,
          height: 1.5,
          color: context.palette.textSecondary,
        ),
      ),
    );
  }
}
