import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/admin_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'screens/privacy_screen.dart';
import 'screens/onboarding_screen.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'widgets/busy_words.dart';

void main() {
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => AppState()..load()),
      ChangeNotifierProvider(create: (_) => ThemeController()..load()),
    ],
    child: const App(),
  ));
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tosha',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: context.watch<ThemeController>().mode,
        home: const _Start(),
        // A whole-app wait (logging out) is said in words over whatever screen is showing.
        // SelectionArea: text anywhere in the app can be selected and copied (it could not be before).
        builder: (context, child) => Stack(children: [
          // SelectionArea needs an Overlay above it for its handles and Copy menu; the app's own Overlay sits
          // inside the Navigator (child), so give it one here (25 Nov: selecting still did not work without it).
          if (child != null) _Selectable(child: child),
          if (context.watch<AppState>().busy case final lines?)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
                child: Center(
                  child: Material(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(24),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
                      child: DefaultTextStyle.merge(
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                        child: BusyWords(lines: lines),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
}

/// Not signed in: account screen. Signed in without a household: onboarding. Otherwise: the app.
class _Start extends StatelessWidget {
  const _Start();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.loaded) return const Scaffold(body: BusyCenter(startWords));
    if (!state.signedIn) return const AuthScreen();
    if (state.admin) return const AdminScreen();      // role-based: admins never see the household app
    if (state.consented == false) return const ConsentScreen();
    return state.profile == null ? const OnboardingScreen() : const HomeScreen();
  }
}


/// Text anywhere in the app can be selected and copied. SelectionArea needs an Overlay above it for its handles
/// and Copy menu, and the app's own Overlay sits inside the Navigator below, so this gives it one. The entry is
/// made once and rebuilt with the new child, so the app below keeps its state.
class _Selectable extends StatefulWidget {
  const _Selectable({required this.child});
  final Widget child;

  @override
  State<_Selectable> createState() => _SelectableState();
}

class _SelectableState extends State<_Selectable> {
  late final OverlayEntry _entry = OverlayEntry(builder: (_) => SelectionArea(child: widget.child));

  @override
  void didUpdateWidget(_Selectable old) {
    super.didUpdateWidget(old);
    if (old.child != widget.child) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entry.markNeedsBuild();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}
