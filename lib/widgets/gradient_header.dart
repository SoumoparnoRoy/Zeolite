import 'package:flutter/material.dart';

import '../core/app_theme.dart';

/// A gradient block bleeding from the top edge carrying the screen's headline,
/// with content on a rounded sheet lifted over it.
///
/// The gradient scrolls away with the header. Only a strip of it behind the
/// status bar is fixed, so the status bar icons never have to flip contrast
/// mid-scroll.
class GradientScaffold extends StatelessWidget {
  const GradientScaffold({
    super.key,
    required this.header,
    this.slivers = const <Widget>[],
    this.floatingActionButton,
    this.onRefresh,
    this.bottom,
    this.headerGap = 20,
    this.bottomInset = 24,
    this.maxContentWidth,
    this.body,
  });

  /// Drawn on the gradient, below the status bar.
  final Widget header;

  /// Drawn on the sheet. Horizontal padding is the caller's, since a grid
  /// wants less of it than a list.
  final List<Widget> slivers;

  final Widget? floatingActionButton;
  final Future<void> Function()? onRefresh;

  /// Pinned above the bottom edge — a primary action that must stay reachable.
  final Widget? bottom;

  /// Space between the header and the sheet edge.
  final double headerGap;

  /// Trailing space under the last sliver, so a FAB never covers the final row.
  final double bottomInset;

  /// The widest the content column gets. The gradient and the sheet still
  /// bleed to the edges on a tablet, but a headline and a row of day pills
  /// stretched across the full width stop being a design and start being a
  /// stretched phone. Defaults to [AppScale.contentWidth].
  final double? maxContentWidth;

  /// Fills the sheet instead of [slivers], with the header pinned above it.
  /// For content that moves sideways: a header that scrolled away would carry
  /// its own controls across with the page.
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final double statusBar = MediaQuery.paddingOf(context).top;
    final Size size = MediaQuery.sizeOf(context);
    final double width = size.width;
    final double cap = maxContentWidth ?? AppScale.contentWidth(size);
    final double gutter = width > cap ? (width - cap) / 2 : 0;
    final EdgeInsets inset = EdgeInsets.symmetric(horizontal: gutter);

    final Widget headerBlock = DecoratedBox(
      decoration: BoxDecoration(gradient: p.headerGradient),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(height: statusBar),
          Padding(padding: inset, child: header),
          SizedBox(height: headerGap),
          // The sheet's top lip has to be painted over the gradient, not
          // over the scaffold, or its rounded corners would cut through
          // to the canvas and be invisible.
          Container(
            height: AppSpacing.radiusSheet,
            decoration: BoxDecoration(
              color: p.canvas,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppSpacing.radiusSheet),
              ),
            ),
          ),
        ],
      ),
    );

    final Widget scroller = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: <Widget>[
        SliverToBoxAdapter(child: headerBlock),
        if (gutter == 0)
          ...slivers
        else
          for (final Widget sliver in slivers)
            SliverPadding(padding: inset, sliver: sliver),
        SliverToBoxAdapter(child: SizedBox(height: bottomInset)),
      ],
    );

    final Future<void> Function()? refresh = onRefresh;
    final Widget? pinned = body;

    return Scaffold(
      body: Stack(
        children: <Widget>[
          if (pinned != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[headerBlock, Expanded(child: pinned)],
            )
          else if (refresh == null)
            scroller
          else
            RefreshIndicator(
              color: p.accent,
              backgroundColor: p.surface,
              onRefresh: refresh,
              child: scroller,
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: statusBar,
            child: ColoredBox(color: p.gradientTop),
          ),
        ],
      ),
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottom == null
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: inset + const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: bottom,
              ),
            ),
    );
  }
}

/// The small uppercase line above a header's headline — what the screen is,
/// and over what period.
class HeaderEyebrow extends StatelessWidget {
  const HeaderEyebrow(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 10.5,
        height: 1,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.3,
        color: Color(0x99FFFFFF),
      ),
    );
  }
}

/// The headline itself: the one sentence or number the screen exists to say.
class HeaderTitle extends StatelessWidget {
  const HeaderTitle(this.text, {super.key, this.size = 23});

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: size,
        height: 1.1,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6,
        color: Colors.white,
      ),
    );
  }
}

/// Explanatory text on the gradient, beside or under a headline number.
class HeaderCaption extends StatelessWidget {
  const HeaderCaption(this.text, {super.key, this.emphasis = 0.9});

  final String text;

  /// How strongly the line reads. Drops for anything that is context rather
  /// than the number itself.
  final double emphasis;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        height: 1.35,
        fontWeight: FontWeight.w600,
        color: Colors.white.withValues(alpha: emphasis),
      ),
    );
  }
}

/// A big number set in white on the gradient — the thing the screen is *for*.
/// The per cent sign rides at roughly half the size so the digits stay the
/// object and the unit stays a label.
class HeaderNumber extends StatelessWidget {
  const HeaderNumber(
    this.value, {
    super.key,
    this.size = 44,
    this.unit = '%',
  });

  final String value;
  final double size;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        text: value,
        children: <InlineSpan>[
          TextSpan(
            text: unit,
            style: TextStyle(
              fontSize: size * 0.45,
              letterSpacing: -size * 0.02,
            ),
          ),
        ],
      ),
      style: TextStyle(
        fontSize: size,
        height: 1,
        fontWeight: FontWeight.w800,
        letterSpacing: -size * 0.045,
        color: Colors.white,
      ),
    );
  }
}

/// The 36px translucent square that carries a header's one action.
class HeaderIconButton extends StatelessWidget {
  const HeaderIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  /// A pressed-in look for a toggle that is currently on.
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: active ? 0.3 : 0.16),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, size: 19, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// The `‹ This week ›` stepper that sits on the gradient under a header.
class HeaderStepper extends StatelessWidget {
  const HeaderStepper({
    super.key,
    required this.label,
    required this.onBack,
    required this.onForward,
    this.onTapLabel,
  });

  final String label;
  final VoidCallback onBack;
  final VoidCallback onForward;

  /// Optional shortcut back to the present.
  final VoidCallback? onTapLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: <Widget>[
          _Arrow(icon: Icons.chevron_left_rounded, onTap: onBack),
          Expanded(
            child: InkWell(
              onTap: onTapLabel,
              borderRadius: BorderRadius.circular(13),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
          _Arrow(icon: Icons.chevron_right_rounded, onTap: onForward),
        ],
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(13),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Icon(icon, size: 18, color: Colors.white),
      ),
    );
  }
}

/// The thin white bar under a header showing how far through something you
/// are — the term, the target.
class HeaderMeter extends StatelessWidget {
  const HeaderMeter({super.key, required this.value, this.thumb = false});

  /// 0..1
  final double value;

  /// Draws a grab handle, for a meter that is actually a setting.
  final bool thumb;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double clamped = value.clamp(0.0, 1.0);
        return SizedBox(
          height: thumb ? 16 : 5,
          child: Stack(
            alignment: Alignment.centerLeft,
            clipBehavior: Clip.none,
            children: <Widget>[
              Container(
                height: thumb ? 4 : 5,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.24),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Container(
                height: thumb ? 4 : 5,
                width: width * clamped,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              if (thumb)
                Positioned(
                  left: (width * clamped - 8).clamp(0.0, width - 16),
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The back row on a page pushed over a tab, where the gradient is a slim bar
/// rather than a block.
class PushHeader extends StatelessWidget {
  const PushHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const <Widget>[],
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final String? sub = subtitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 14, 0),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_rounded),
            color: Colors.white,
            tooltip: 'Back',
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 19,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: Colors.white,
                  ),
                ),
                if (sub != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// A push page in the same language as a tab: slim gradient bar, sheet under it.
class PushScaffold extends StatelessWidget {
  const PushScaffold({
    super.key,
    required this.title,
    required this.slivers,
    this.subtitle,
    this.actions = const <Widget>[],
    this.floatingActionButton,
    this.bottomInset = 24,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final List<Widget> slivers;
  final Widget? floatingActionButton;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    return GradientScaffold(
      headerGap: 16,
      bottomInset: bottomInset,
      header: PushHeader(title: title, subtitle: subtitle, actions: actions),
      floatingActionButton: floatingActionButton,
      slivers: slivers,
    );
  }
}

/// The gradient pill that replaces the flat FAB.
class GradientFab extends StatelessWidget {
  const GradientFab({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: p.accentGradient,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: p.gradientMid.withValues(alpha: p.isDark ? 0.45 : 0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(15, 13, 18, 13),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.add_rounded, size: 18, color: Colors.white),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
