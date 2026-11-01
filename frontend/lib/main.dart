import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'screens/profile_screen.dart';
import 'state/app_state.dart';

void main() {
  runApp(ChangeNotifierProvider(create: (_) => AppState()..load(), child: const App()));
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Lifestyle Affordability',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1B7F5B), useMaterial3: true),
        home: const _Start(),
      );
}

/// Not signed in: account screen. Signed in without a household: profile. Otherwise: the app.
class _Start extends StatelessWidget {
  const _Start();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!state.signedIn) return const AuthScreen();
    return state.profile == null ? const ProfileScreen() : const HomeScreen();
  }
}
