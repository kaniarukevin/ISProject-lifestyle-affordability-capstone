import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';

/// Smart reloading: a screen with this mixin refreshes itself when the user's data changes anywhere in the app
/// (a record added on another screen, a plan applied, a statement imported), without reloading the whole app.
/// The current figures stay on screen while the new ones load. Several changes close together cause one reload.
mixin ReloadOnChange<T extends StatefulWidget> on State<T> {
  int? _seen;
  Timer? _wait;

  /// Fetch fresh figures without clearing what is on screen.
  Future<void> reloadQuietly();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final v = Provider.of<AppState>(context).dataVersion;
    if (_seen == null) {
      _seen = v;                           // the first build loads in initState as before
      return;
    }
    if (v == _seen) return;
    _seen = v;
    _wait?.cancel();
    _wait = Timer(const Duration(milliseconds: 400), () {
      if (mounted) reloadQuietly();
    });
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }
}
