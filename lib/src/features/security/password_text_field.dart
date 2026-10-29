import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';

/// A password field with an eye button that shows or hides what is typed
/// (hidden at first). The keyboard learns nothing and suggests nothing.
/// [fieldKey] goes on the text field itself.
class PasswordTextField extends StatefulWidget {
  const PasswordTextField({
    required this.controller,
    this.fieldKey,
    this.decoration = const InputDecoration(),
    this.textInputAction,
    this.autofocus = false,
    this.onSubmitted,
    this.onChanged,
    super.key,
  });

  final TextEditingController controller;
  final Key? fieldKey;
  final InputDecoration decoration;
  final TextInputAction? textInputAction;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;

  @override
  State<PasswordTextField> createState() => _PasswordTextFieldState();
}

class _PasswordTextFieldState extends State<PasswordTextField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) => TextField(
    key: widget.fieldKey,
    controller: widget.controller,
    obscureText: _hidden,
    autofocus: widget.autofocus,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    textInputAction: widget.textInputAction,
    onSubmitted: widget.onSubmitted,
    onChanged: widget.onChanged,
    decoration: widget.decoration.copyWith(
      suffixIcon: IconButton(
        tooltip: _hidden ? t('Pokaż hasło') : t('Ukryj hasło'),
        onPressed: () => setState(() => _hidden = !_hidden),
        icon: Icon(
          _hidden ? Icons.visibility_off_rounded : Icons.visibility_rounded,
        ),
      ),
    ),
  );
}
