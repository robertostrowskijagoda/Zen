import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/start_trace.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// Tells when a start takes longer than usual: [slow] turns true
/// [patience] after [watch] while the start still runs. "Czekaj" ([wait])
/// hides the slow-start panel for another [patience].
final class ZenStartWatchdog extends ChangeNotifier {
  ZenStartWatchdog({this.patience = const Duration(seconds: 8)});

  /// How long a start may take before the panel shows.
  final Duration patience;

  Timer? _timer;
  bool _slow = false;

  /// Whether the slow-start panel is to be shown.
  bool get slow => _slow;

  /// A start begins: the panel shows if it is still running after
  /// [patience].
  void watch() {
    _timer?.cancel();
    _set(false);
    _timer = Timer(patience, () => _set(true));
  }

  /// "Czekaj": the panel goes, and comes back after another [patience].
  void wait() => watch();

  /// The start finished (or failed with its own screen).
  void stop() {
    _timer?.cancel();
    _timer = null;
    _set(false);
  }

  void _set(bool slow) {
    if (_slow == slow) {
      return;
    }
    _slow = slow;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// "Zen uruchamia się dłużej niż zwykle": which step the start waits on
/// ([ZenStartTrace.current]) and what can be done: wait, save the
/// diagnostics log, or start without the step when the app can do
/// without it. Never a wipe of the app's data.
class ZenSlowStartPanel extends StatefulWidget {
  const ZenSlowStartPanel({
    required this.onWait,
    required this.onSaveLog,
    super.key,
  });

  /// "Czekaj".
  final VoidCallback onWait;

  /// "Zapisz dziennik": whether the log was saved.
  final Future<bool> Function() onSaveLog;

  @override
  State<ZenSlowStartPanel> createState() => _ZenSlowStartPanelState();
}

class _ZenSlowStartPanelState extends State<ZenSlowStartPanel> {
  bool _saving = false;
  String? _saved;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saved = null;
    });
    bool ok = false;
    try {
      ok = await widget.onSaveLog();
    } on Object {
      ok = false;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _saving = false;
      _saved = ok
          ? t('Dziennik zapisany.')
          : t('Nie udało się zapisać dziennika.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ValueListenableBuilder<ZenStartStep?>(
      valueListenable: ZenStartTrace.current,
      builder: (BuildContext context, ZenStartStep? step, Widget? _) {
        final bool canSkip =
            step != null && step.optional && ZenStartTrace.canSkip;
        return Container(
          key: const Key('slow-start-panel'),
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          decoration: BoxDecoration(
            color: zen.accent.withValues(alpha: 0.08),
            borderRadius: context.zenRadius(20),
            border: Border.all(color: zen.accent.withValues(alpha: 0.24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                t('Zen uruchamia się dłużej niż zwykle'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: zen.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
              if (step != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  t('Czeka na: {step}', <String, Object>{'step': step.label}),
                  key: const Key('slow-start-step'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
              ],
              if (_saved != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  _saved!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: zen.textSecondary, fontSize: 13),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: <Widget>[
                  TextButton(
                    key: const Key('slow-start-wait'),
                    onPressed: widget.onWait,
                    child: Text(t('Czekaj')),
                  ),
                  TextButton(
                    key: const Key('slow-start-save-log'),
                    onPressed: _saving ? null : _save,
                    child: Text(t('Zapisz dziennik')),
                  ),
                  if (canSkip)
                    FilledButton(
                      key: const Key('slow-start-skip'),
                      onPressed: ZenStartTrace.skip,
                      child: Text(
                        t('Uruchom bez: {step}', <String, Object>{
                          'step': step.label,
                        }),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
