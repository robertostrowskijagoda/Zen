import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/calls/call_screen_share.dart';

/// Asks which screen or window to share; `null` when cancelled.
Future<ScreenShareSource?> showScreenSourcePicker(
  BuildContext context,
  List<ScreenShareSource> sources,
) => showDialog<ScreenShareSource>(
  context: context,
  builder: (BuildContext dialog) => ScreenSourcePicker(sources: sources),
);

/// Desktop: pick the whole screen or one window.
class ScreenSourcePicker extends StatelessWidget {
  const ScreenSourcePicker({super.key, required this.sources});

  final List<ScreenShareSource> sources;

  @override
  Widget build(BuildContext context) {
    final List<ScreenShareSource> screens = sources
        .where((ScreenShareSource s) => !s.isWindow)
        .toList();
    final List<ScreenShareSource> windows = sources
        .where((ScreenShareSource s) => s.isWindow)
        .toList();
    Widget tile(ScreenShareSource s) => InkWell(
      key: Key('screen-source-${s.id}'),
      onTap: () => Navigator.of(context).pop(s),
      borderRadius: context.zenRadius(16),
      child: SizedBox(
        width: 170,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: context.zenRadius(12),
                  child: s.thumbnail == null
                      ? const ColoredBox(
                          color: Colors.black26,
                          child: Icon(Icons.desktop_windows_outlined),
                        )
                      : Image.memory(s.thumbnail!, fit: BoxFit.cover),
                ),
              ),
              const SizedBox(height: 6),
              Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
    return AlertDialog(
      title: Text(t('Co udostępnić?')),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (screens.isNotEmpty) ...<Widget>[
                ZenSection(t('Cały ekran'), top: 0),
                const SizedBox(height: 6),
                Wrap(
                  children: <Widget>[
                    for (final ScreenShareSource s in screens) tile(s),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (windows.isNotEmpty) ...<Widget>[
                ZenSection(t('Jedno okno'), top: 0),
                const SizedBox(height: 6),
                Wrap(
                  children: <Widget>[
                    for (final ScreenShareSource s in windows) tile(s),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Anuluj')),
        ),
      ],
    );
  }
}
