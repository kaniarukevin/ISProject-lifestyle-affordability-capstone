import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user's own order of cards on a page, and the cards they hid (25 Nov: testers wanted what they use most at
/// the top). Kept on this device only; "Reset" brings back the app's order.
class CardLayout {
  CardLayout(this.page, this.defaults, this.labels);
  final String page;
  final List<String> defaults;            // the app's order
  final Map<String, String> labels;       // what each card is called in the editor
  List<String> order = [];
  Set<String> hidden = {};

  String get _key => 'layout_$page';

  /// Saved order, with cards the app added later put back in their usual place and removed ones dropped.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_key) ?? [];
    hidden = (prefs.getStringList('${_key}_hidden') ?? []).where(defaults.contains).toSet();
    order = saved.where(defaults.contains).toList();
    for (var i = 0; i < defaults.length; i++) {
      if (!order.contains(defaults[i])) order.insert(i.clamp(0, order.length), defaults[i]);
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, order);
    await prefs.setStringList('${_key}_hidden', hidden.toList());
  }

  /// The cards to show, in the user's order.
  List<String> get visible => (order.isEmpty ? defaults : order).where((id) => !hidden.contains(id)).toList();

  /// A sheet to drag cards up and down and switch them on or off. Returns true if anything changed.
  Future<bool> edit(BuildContext context) async {
    final o = List<String>.from(order.isEmpty ? defaults : order);
    final h = Set<String>.from(hidden);
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(builder: (context, set) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Edit layout', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('Drag to reorder. Switch off what you don\'t need.', style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Flexible(
                child: ReorderableListView(
                  shrinkWrap: true,
                  buildDefaultDragHandles: false,
                  onReorderItem: (from, to) => set(() => o.insert(to, o.removeAt(from))),
                  children: [
                    for (var i = 0; i < o.length; i++)
                      ListTile(
                        key: ValueKey(o[i]),
                        contentPadding: EdgeInsets.zero,
                        leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_indicator_rounded)),
                        title: Text(labels[o[i]] ?? o[i],
                            style: TextStyle(color: h.contains(o[i]) ? theme.disabledColor : null)),
                        trailing: Switch(
                          value: !h.contains(o[i]),
                          onChanged: (on) => set(() => on ? h.remove(o[i]) : h.add(o[i])),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                TextButton(
                  onPressed: () => set(() {
                    o
                      ..clear()
                      ..addAll(defaults);
                    h.clear();
                  }),
                  child: const Text('Reset'),
                ),
                const Spacer(),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done')),
              ]),
            ]),
          ),
        );
      }),
    );
    if (saved != true) return false;
    order = o;
    hidden = h;
    await _save();
    return true;
  }
}

/// The small "Edit layout" button at the bottom of a page.
class EditLayoutButton extends StatelessWidget {
  const EditLayoutButton({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.center,
        child: TextButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.dashboard_customize_outlined, size: 18),
          label: const Text('Edit layout'),
        ),
      );
}
