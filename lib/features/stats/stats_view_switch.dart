import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../widgets/common.dart';

enum StatsView {
  overview('Overview'),
  counts('Counts');

  const StatsView(this.label);

  final String label;
}

/// The two Stats pages, as a pill at the top of each. Each page draws its own
/// with itself picked, so the pill slides across with the page under a drag
/// rather than having to follow it.
class StatsViewSwitch extends StatelessWidget {
  const StatsViewSwitch({
    super.key,
    required this.current,
    required this.onSelect,
  });

  final StatsView current;
  final ValueChanged<StatsView> onSelect;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      radius: AppSpacing.radiusLg,
      padding: const EdgeInsets.all(AppSpacing.xs),
      child: Row(
        children: <Widget>[
          for (final StatsView view in StatsView.values)
            Expanded(
              child: _Segment(
                label: view.label,
                selected: view == current,
                onTap: () => onSelect(view),
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? p.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: selected ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.bodyMedium,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: selected ? AppColors.inkOn(p.accent, p) : p.textTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
