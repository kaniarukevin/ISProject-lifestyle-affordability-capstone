import 'package:flutter/material.dart';

/// One button on a choice sheet.
class SheetChoice<T> {
  const SheetChoice(this.label, this.value, {this.primary = false});
  final String label;
  final T value;
  final bool primary;
}

/// A bottom sheet that asks before doing something ("Log out?"). Returns the chosen value, or null for Cancel.
Future<T?> showChoiceSheet<T>(
  BuildContext context, {
  required String title,
  required String message,
  required List<SheetChoice<T>> choices,
}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(message, style: theme.textTheme.bodyLarge),
                const SizedBox(height: 20),
                for (final c in choices) ...[
                  c.primary
                      ? FilledButton(onPressed: () => Navigator.pop(context, c.value), child: Text(c.label))
                      : FilledButton.tonal(
                          style: FilledButton.styleFrom(
                            backgroundColor: theme.colorScheme.surface,
                            foregroundColor: theme.colorScheme.onSurface,
                          ),
                          onPressed: () => Navigator.pop(context, c.value),
                          child: Text(c.label)),
                  const SizedBox(height: 10),
                ],
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              ],
            ),
          ),
        );
      },
    );
