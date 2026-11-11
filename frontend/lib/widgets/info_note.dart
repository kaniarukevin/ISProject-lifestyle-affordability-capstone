import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// An explanation you can actually see (11 Nov: testers said the explanations were there but did not stand out).
/// A tinted box with an icon down the left, used everywhere Tosha explains what something is, why it is asking,
/// or where a number came from. [points] are shown as a short bulleted list.
class InfoNote extends StatelessWidget {
  const InfoNote({
    super.key,
    this.title,
    this.text,
    this.points = const [],
    this.icon = Icons.info_outline_rounded,
    this.tone = NoteTone.plain,
    this.margin = const EdgeInsets.only(top: 12),
  });

  /// "Why we ask" above a setup question: the same box, with the question mark icon.
  const InfoNote.why({super.key, required String this.text, this.margin = const EdgeInsets.only(top: 10)})
      : title = 'Why we ask',
        points = const [],
        icon = Icons.help_outline_rounded,
        tone = NoteTone.plain;

  final String? title;
  final String? text;
  final List<String> points;
  final IconData icon;
  final NoteTone tone;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final (bg, ink) = switch (tone) {
      NoteTone.plain => (c.field, theme.colorScheme.onSurface),
      NoteTone.warn => (c.warnBg, c.warn),
      NoteTone.good => (c.lime, c.onLime),
    };
    return Container(
      margin: margin,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 19, color: ink)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (title != null)
              Padding(
                padding: EdgeInsets.only(bottom: text != null || points.isNotEmpty ? 4 : 0),
                child: Text(title!,
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: ink)),
              ),
            if (text != null) Text(text!, style: theme.textTheme.bodyMedium?.copyWith(color: ink)),
            for (final p in points)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 7, right: 10),
                    child: Container(width: 5, height: 5, decoration: BoxDecoration(color: ink, shape: BoxShape.circle)),
                  ),
                  Expanded(child: Text(p, style: theme.textTheme.bodyMedium?.copyWith(color: ink))),
                ]),
              ),
          ]),
        ),
      ]),
    );
  }
}

enum NoteTone { plain, warn, good }
