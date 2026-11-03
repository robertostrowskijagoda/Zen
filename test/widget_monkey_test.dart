import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// A monkey in the app: taps whatever can be tapped, now and then goes
/// back, for a few hundred steps, from a fixed seed (so a failure comes
/// back the same way: `ZEN_MONKEY_SEED=<seed>`). Anything that throws or
/// runs out of room fails it, with the steps that led there.

/// Steps of one walk, and how many walks (seeds 1, 2, …): a longer hunt
/// with `--dart-define=ZEN_MONKEY_RUNS=60 --dart-define=ZEN_MONKEY_STEPS=300`.
const int _steps = int.fromEnvironment('ZEN_MONKEY_STEPS', defaultValue: 120);
const int _runs = int.fromEnvironment('ZEN_MONKEY_RUNS', defaultValue: 6);

/// Someone who closes every file picker without choosing.
class _CancellingPicker extends FilePicker {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => null;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => null;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async => null;
}

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// What a tap may land on: a control of its own, not a whole page.
bool _tappable(Widget w) => switch (w) {
  InkWell(:final VoidCallback? onTap) => onTap != null,
  ButtonStyleButton(:final VoidCallback? onPressed) => onPressed != null,
  IconButton(:final VoidCallback? onPressed) => onPressed != null,
  ListTile(:final GestureTapCallback? onTap) => onTap != null,
  Switch(:final ValueChanged<bool>? onChanged) => onChanged != null,
  Checkbox(:final ValueChanged<bool?>? onChanged) => onChanged != null,
  FilterChip(:final ValueChanged<bool>? onSelected) => onSelected != null,
  ChoiceChip(:final ValueChanged<bool>? onSelected) => onSelected != null,
  _ => false,
};

/// Labels never tapped: they leave the app, or wipe it.
const List<String> _avoid = <String>[
  'settings-nav-github',
  'settings-nav-discord',
  'settings-nav-reset',
];

bool _avoided(Element e) {
  bool hit = false;
  void look(Element el) {
    final Key? key = el.widget.key;
    if (key is ValueKey<String> && _avoid.contains(key.value)) {
      hit = true;
    }
  }

  look(e);
  e.visitAncestorElements((Element a) {
    look(a);
    return !hit;
  });
  return hit;
}

Future<void> _walk(WidgetTester tester, int seed) async {
  final Random random = Random(seed);
  final List<String> log = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        socialHubAutoHydrateProvider.overrideWithValue(false),
        signalTransportProvider.overrideWithValue(MemorySignalTransport()),
        ledgerNodeEnabledProvider.overrideWithValue(true),
        ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
      ],
      child: MaterialApp(
        theme: seed.isEven ? ZenTheme.dark() : ZenTheme.light(),
        home: const AppShellScreen(),
      ),
    ),
  );
  await tester.runAsync(() => _settle());
  await tester.pump();
  for (int step = 0; step < _steps; step++) {
    final NavigatorState navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    if (random.nextInt(8) == 0 && navigator.canPop()) {
      log.add('$step back');
      await navigator.maybePop();
    } else {
      final List<Element> targets = find
          .byWidgetPredicate(_tappable)
          .hitTestable()
          .evaluate()
          .where((Element e) => !_avoided(e))
          .toList(growable: false);
      if (targets.isEmpty) {
        log.add('$step nothing to tap');
        if (navigator.canPop()) {
          await navigator.maybePop();
        }
      } else {
        final Element target = targets[random.nextInt(targets.length)];
        final Widget w = target.widget;
        log.add(
          '$step tap ${w.runtimeType}'
          '${w.key == null ? '' : ' ${w.key}'}',
        );
        await tester.tap(
          find.byElementPredicate((Element e) => e == target).first,
          warnIfMissed: false,
        );
      }
    }
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 600));
    final Object? error = tester.takeException();
    if (error != null) {
      fail('seed $seed, step $step: $error\n${log.join('\n')}');
    }
  }
  await tester.pumpWidget(const SizedBox.shrink());
  // Something copied waits to be cleared from the clipboard: by design,
  // past the pages that copied it.
  await ExpiringClipboard.instance.clearNow();
  await tester.runAsync(() => _settle());
}

void main() {
  setUpAll(() => FilePicker.platform = _CancellingPicker());
  const String fixed = String.fromEnvironment('ZEN_MONKEY_SEED');
  final List<int> seeds = fixed.isNotEmpty
      ? <int>[int.parse(fixed)]
      : <int>[for (int i = 1; i <= _runs; i++) i];
  for (final int seed in seeds) {
    testWidgets('a monkey taps around the app (seed $seed)', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = seed % 3 == 0
          ? const Size(1280, 800)
          : const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _walk(tester, seed);
    });
  }
}
