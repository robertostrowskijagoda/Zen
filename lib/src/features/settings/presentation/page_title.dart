import 'package:flutter/material.dart';

/// The title of a sub-page's [AppBar] that is not cut in long languages:
/// it wraps to a second line instead of ending in "…".
class PageTitle extends StatelessWidget {
  const PageTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      key: const Key('page-title'),
      maxLines: 2,
      softWrap: true,
      style: const TextStyle(fontSize: 18, height: 1.2),
    );
  }
}
