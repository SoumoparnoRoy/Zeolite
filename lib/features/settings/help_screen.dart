import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

import 'help_topics.dart';
import 'send_feedback.dart';

class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key, this.openQuestion});

  /// A [HelpQuestion.id] to open and scroll to, from a Settings search result.
  final String? openQuestion;

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  late final Set<String> _open = <String>{
    if (widget.openQuestion case final String id) id,
  };
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{
    for (final HelpQuestion q in helpQuestions) q.id: GlobalKey(),
  };

  @override
  void initState() {
    super.initState();
    final String? id = widget.openQuestion;
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? target = _keys[id]?.currentContext;
      if (target == null || !target.mounted) return;
      // Only as far as it takes to show the whole answer: a question near
      // the top stays where it is, under the screen's title.
      Scrollable.ensureVisible(
        target,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  void _toggle(String id) =>
      setState(() => _open.contains(id) ? _open.remove(id) : _open.add(id));

  @override
  Widget build(BuildContext context) {
    return PushScaffold(
      title: 'Help and FAQ',
      subtitle: 'Short answers to the questions people ask most',
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          // A Column, not a lazy list: a search result may open the last
          // question, and it has to be built to be scrolled to.
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final HelpSection section in helpSections) ...<Widget>[
                  SectionHeader(section.title),
                  _QuestionCard(
                    questions: section.questions,
                    open: _open,
                    keys: _keys,
                    onToggle: _toggle,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                ],
                const _StillStuck(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.questions,
    required this.open,
    required this.keys,
    required this.onToggle,
  });

  final List<HelpQuestion> questions;
  final Set<String> open;
  final Map<String, GlobalKey> keys;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < questions.length; i++) ...<Widget>[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Container(height: 1, color: p.outlineSoft),
              ),
            HelpQuestionTile(
              key: keys[questions[i].id],
              question: questions[i],
              expanded: open.contains(questions[i].id),
              onTap: () => onToggle(questions[i].id),
            ),
          ],
        ],
      ),
    );
  }
}

class HelpQuestionTile extends StatelessWidget {
  const HelpQuestionTile({
    super.key,
    required this.question,
    required this.expanded,
    required this.onTap,
  });

  final HelpQuestion question;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Duration motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // The question is the button and says whether it is open; a screen
        // reader reaches the answer next.
        Semantics(
          container: true,
          button: true,
          expanded: expanded,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        question.question,
                        style: TextStyle(
                          fontSize: AppType.bodyMedium,
                          height: 1.3,
                          fontWeight: FontWeight.w700,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: motion,
                      child: Icon(
                        Icons.expand_more_rounded,
                        size: 20,
                        color: p.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: motion,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 46, 14),
                  // Its own node, or it folds into the card's.
                  child: Semantics(
                    container: true,
                    child: Text(
                      question.answer,
                      style: TextStyle(
                        fontSize: AppType.bodySmall,
                        height: 1.55,
                        color: p.textSecondary,
                      ),
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class _StillStuck extends ConsumerWidget {
  const _StillStuck();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppPalette p = context.palette;
    return SurfaceCard(
      color: p.accentSoft,
      elevated: false,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Still stuck?',
            style: TextStyle(
              fontSize: AppType.titleMedium,
              fontWeight: FontWeight.w700,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Tell the developer what happened. The email already says which '
            'version of Zeolite and Android you have.',
            style: TextStyle(
              fontSize: AppType.bodySmall,
              height: 1.5,
              color: p.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 0),
              minimumSize: const Size(0, 48),
              // Measured against this card's fill, not the page's surface.
              foregroundColor:
                  AppColors.inkOn(p.accent, p.copyWith(surface: p.accentSoft)),
            ),
            onPressed: () => sendFeedback(context, ref),
            icon: const Icon(Icons.mail_outline_rounded, size: 18),
            label: const Text(
              'Send feedback',
              style: TextStyle(
                fontSize: AppType.bodyMedium,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
