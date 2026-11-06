import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifestyle_affordability/theme/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the chosen appearance is remembered on this device', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ThemeController();
    await first.load();
    expect(first.mode, ThemeMode.light);
    await first.set(ThemeMode.dark);
    final again = ThemeController();
    await again.load();
    expect(again.mode, ThemeMode.dark);
  });
}
