import 'package:flutter/material.dart';

/// A password box with an eye button to show or hide what was typed (easy to mistype on a phone).
class PasswordField extends StatefulWidget {
  const PasswordField({super.key, required this.controller, this.label = 'Password', this.helper, this.onSubmitted,
      this.autofillHints});
  final TextEditingController controller;
  final String label;
  final String? helper;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String>? autofillHints;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) => TextField(
        controller: widget.controller,
        obscureText: !_visible,
        enableSuggestions: false,
        autocorrect: false,
        autofillHints: widget.autofillHints,
        onSubmitted: widget.onSubmitted,
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: widget.helper,
          suffixIcon: IconButton(
            tooltip: _visible ? 'Hide password' : 'Show password',
            icon: Icon(_visible ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            onPressed: () => setState(() => _visible = !_visible),
          ),
        ),
      );
}
