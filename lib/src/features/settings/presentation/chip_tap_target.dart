import 'package:flutter/material.dart';

/// The smallest tap target of a settings choice chip.
const double kChipTapTarget = 44;

/// A choice chip whose tap target is at least [kChipTapTarget] tall. The
/// padded target of a chip is 48 px less the compact density the app uses
/// on phones, so 40; this adds the rest around it and leaves the chip
/// looking as it does (a tap anywhere in the box goes to the chip).
class ChipTapTarget extends StatelessWidget {
  const ChipTapTarget({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: kChipTapTarget),
    child: child,
  );
}
