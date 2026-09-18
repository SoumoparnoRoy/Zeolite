import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../domain/attendance_stats.dart';
import '../../widgets/common.dart';

Future<void> showSimulateSheet(BuildContext context, SubjectStats stats) {
  return showAppSheet<void>(
    context: context,
    title: 'Simulate',
    child: SimulateSheet(stats: stats),
  );
}

/// Classes that have not happened yet, tried out against a subject's real
/// figures. Nothing here is saved; closing the sheet forgets it.
class SimulateSheet extends StatefulWidget {
  const SimulateSheet({super.key, required this.stats});

  final SubjectStats stats;

  @override
  State<SimulateSheet> createState() => _SimulateSheetState();
}

class _SimulateSheetState extends State<SimulateSheet> {
  int _attended = 0;
  int _missed = 0;

  /// What the term still holds, when the app knows. With no term dates and no
  /// declared total there is nothing honest to stop at.
  int? get _cap {
    final int left = widget.stats.remainingPlanned;
    return left > 0 ? left : null;
  }

  bool get _atCap => _cap != null && _attended + _missed >= _cap!;

  void _set({int? attended, int? missed}) {
    setState(() {
      _attended = attended ?? _attended;
      _missed = missed ?? _missed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final SubjectStats now = widget.stats;
    final SubjectStats then = now.after(attended: _attended, missed: _missed);
    final String units = now.weighted ? 'periods' : 'classes';
    final bool touched = _attended + _missed > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Try out the $units ahead. Nothing here is saved.',
          style: TextStyle(fontSize: 12, height: 1.4, color: p.textTertiary),
        ),
        const SizedBox(height: AppSpacing.xl),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Text(
              then.hasData ? '${then.percent.toStringAsFixed(0)}%' : '—',
              style: TextStyle(
                fontSize: 40,
                height: 1,
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
                color: healthColor(then.health, p),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                now.hasData
                    ? 'Now ${now.percent.toStringAsFixed(0)}%'
                    : 'Nothing marked yet',
                style: monoStyle(color: p.textTertiary, size: 11),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        TargetBar(
          value: then.ratio,
          color: healthFill(then.health, p),
          target: then.target,
        ),
        const SizedBox(height: AppSpacing.xl),
        _StepperRow(
          label: 'Attend',
          count: _attended,
          color: p.present,
          canAdd: !_atCap,
          onChanged: (int value) => _set(attended: value),
        ),
        const SizedBox(height: AppSpacing.sm),
        _StepperRow(
          label: 'Miss',
          count: _missed,
          color: p.absent,
          canAdd: !_atCap,
          onChanged: (int value) => _set(missed: value),
        ),
        if (_atCap) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Text(
            'That is every ${now.weighted ? 'period' : 'class'} left this '
            'term.',
            style:
                TextStyle(fontSize: 11.5, height: 1.4, color: p.textTertiary),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        SurfaceCard(
          elevated: false,
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                then.meetsTarget
                    ? Icons.check_circle_outline_rounded
                    : Icons.error_outline_rounded,
                size: 17,
                color: healthColor(then.health, p),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  then.headline,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: touched ? () => _set(attended: 0, missed: 0) : null,
            child: const Text('Reset'),
          ),
        ),
      ],
    );
  }
}

class _StepperRow extends StatelessWidget {
  const _StepperRow({
    required this.label,
    required this.count,
    required this.color,
    required this.canAdd,
    required this.onChanged,
  });

  final String label;
  final int count;
  final Color color;
  final bool canAdd;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    // The row groups its controls, so it takes the raised fill and the buttons
    // drop a layer, the way the class editor's time card does.
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: p.surfaceHigher,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: p.textPrimary,
              ),
            ),
          ),
          _StepButton(
            icon: Icons.remove_rounded,
            semanticLabel: 'One fewer to $label',
            onStep: count > 0 ? () => onChanged(count - 1) : null,
          ),
          SizedBox(
            width: 44,
            child: Text(
              '$count',
              textAlign: TextAlign.center,
              style: monoStyle(
                color: p.textPrimary,
                size: 15,
                weight: FontWeight.w700,
              ),
            ),
          ),
          _StepButton(
            icon: Icons.add_rounded,
            semanticLabel: 'One more to $label',
            onStep: canAdd ? () => onChanged(count + 1) : null,
          ),
        ],
      ),
    );
  }
}

/// A square step control that repeats while held, so reaching twenty does not
/// take twenty taps.
class _StepButton extends StatefulWidget {
  const _StepButton({
    required this.icon,
    required this.semanticLabel,
    required this.onStep,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onStep;

  @override
  State<_StepButton> createState() => _StepButtonState();
}

class _StepButtonState extends State<_StepButton> {
  Timer? _repeat;

  void _start() {
    widget.onStep?.call();
    _repeat = Timer.periodic(const Duration(milliseconds: 90), (_) {
      // Read fresh each tick: the parent turns this off at zero or the cap,
      // and the old callback would step straight through it.
      final VoidCallback? step = widget.onStep;
      if (step == null) return _stop();
      step();
    });
  }

  void _stop() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  void didUpdateWidget(_StepButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onStep == null) _stop();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool enabled = widget.onStep != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      excludeSemantics: true,
      child: GestureDetector(
        onLongPressStart: enabled ? (_) => _start() : null,
        onLongPressEnd: (_) => _stop(),
        onLongPressCancel: _stop,
        child: Material(
          color: p.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            side: BorderSide(color: p.outline),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onStep,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(
                widget.icon,
                size: 20,
                color: enabled ? p.textPrimary : p.textFaint,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
