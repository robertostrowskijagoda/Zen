import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/zen_web.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/qr_sticker/qr_matrix.dart';
import 'package:zen/src/features/qr_sticker/sticker_design.dart';
import 'package:zen/src/features/qr_sticker/sticker_export.dart';
import 'package:zen/src/features/qr_sticker/sticker_files.dart';
import 'package:zen/src/features/qr_sticker/sticker_scene.dart';
import 'package:zen/src/features/qr_sticker/sticker_store.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// What a sticker's QR code carries: the text of the code, its kind (for
/// the ready texts and the remembered design) and the name the ready texts
/// put in (the person's, the flat's).
@immutable
final class StickerSubject {
  const StickerSubject({
    required this.kind,
    required this.data,
    required this.label,
    this.name = '',
  });

  final StickerKind kind;
  final String data;

  /// What the choice between several subjects shows.
  final String label;
  final String name;

  /// The person's own invitation ("Mój kod"), with their name (not the
  /// "Zen 1A2B" a profile without one shows).
  static StickerSubject invite(PeerShareProfile profile) => StickerSubject(
    kind: StickerKind.friendInvite,
    data: profile.qrData,
    label: t('Zaproszenie do znajomych'),
    name: profile.displayName == 'Zen ${profile.shareId}'
        ? ''
        : profile.displayName,
  );

  /// The page about Zen.
  static StickerSubject zenAbout() => StickerSubject(
    kind: StickerKind.zenAbout,
    data: zenPageUrl('about/'),
    label: t('Strona o Zen'),
  );
}

/// This person's invitation, or null while the network has given no
/// address yet.
final Provider<PeerShareProfile?>
myShareProfileProvider = Provider<PeerShareProfile?>(
  (Ref ref) => PeerShareCodec.buildLocalProfile(
    address: ref.watch(
      appShellControllerProvider.select((AppShellState s) => s.localAddress),
    ),
    displayName: ref.watch(
      userProfileControllerProvider.select((UserProfile p) => p.displayName),
    ),
  ),
);

/// "Naklejka promująca Zen" (O aplikacji): the designer with the page about
/// Zen or the person's own invitation.
Future<void> openZenPromoSticker(BuildContext context, WidgetRef ref) {
  final PeerShareProfile? me = ref.read(myShareProfileProvider);
  return StickerDesignerScreen.open(context, <StickerSubject>[
    StickerSubject.zenAbout(),
    if (me != null) StickerSubject.invite(me),
  ]);
}

/// The sticker designer every printable QR code opens: texts (ready ones
/// or the person's own), the small "Zen" signature, the code's style and
/// colours, a pattern in the margins, the page and the file. The artwork
/// is a square centred on the page, so it can be cut out; the last design
/// of each kind is remembered.
class StickerDesignerScreen extends ConsumerStatefulWidget {
  const StickerDesignerScreen({required this.subjects, super.key})
    : assert(subjects.length > 0);

  final List<StickerSubject> subjects;

  static Future<void> open(
    BuildContext context,
    List<StickerSubject> subjects,
  ) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) =>
          StickerDesignerScreen(subjects: subjects),
    ),
  );

  @override
  ConsumerState<StickerDesignerScreen> createState() =>
      _StickerDesignerScreenState();
}

class _StickerDesignerScreenState extends ConsumerState<StickerDesignerScreen> {
  final TextEditingController _top = TextEditingController();
  final TextEditingController _caption = TextEditingController();
  final TextEditingController _bottom = TextEditingController();
  final Map<StickerKind, StickerDesign> _designs =
      <StickerKind, StickerDesign>{};
  final Map<(String, bool), QrMatrix> _matrices = <(String, bool), QrMatrix>{};
  late final StickerStore _store = ref.read(stickerStoreProvider);
  int _chosen = 0;
  bool _busy = false;
  Timer? _saveLater;
  final Set<StickerKind> _unsaved = <StickerKind>{};

  StickerSubject get _subject => widget.subjects[_chosen];

  StickerDesign get _design =>
      _designs[_subject.kind] ??
      StickerDesign.initial(_subject.kind, name: _subject.name);

  @override
  void initState() {
    super.initState();
    _showTexts();
    unawaited(_load());
  }

  Future<void> _load() async {
    for (final StickerSubject s in widget.subjects) {
      final StickerDesign? kept = await _store.load(s.kind);
      if (!mounted) {
        return;
      }
      if (kept != null && !_designs.containsKey(s.kind)) {
        setState(() => _designs[s.kind] = kept);
        if (s.kind == _subject.kind) {
          _showTexts();
        }
      }
    }
  }

  @override
  void dispose() {
    _saveLater?.cancel();
    _flush();
    _top.dispose();
    _caption.dispose();
    _bottom.dispose();
    super.dispose();
  }

  void _showTexts() {
    final StickerTexts texts = _design.texts;
    _top.text = texts.top;
    _caption.text = texts.caption;
    _bottom.text = texts.bottom;
  }

  void _change(StickerDesign next) {
    final StickerKind kind = _subject.kind;
    setState(() => _designs[kind] = next);
    _unsaved.add(kind);
    _saveLater?.cancel();
    _saveLater = Timer(const Duration(milliseconds: 600), _flush);
  }

  void _flush() {
    for (final StickerKind kind in _unsaved.toList()) {
      final StickerDesign? design = _designs[kind];
      if (design != null) {
        unawaitedLogged(
          _store.save(kind, design),
          context: 'Saving the sticker design failed',
        );
      }
    }
    _unsaved.clear();
  }

  void _textsChanged() => _change(
    _design.copyWith(
      texts: StickerTexts(
        top: _top.text,
        caption: _caption.text,
        bottom: _bottom.text,
      ),
    ),
  );

  QrMatrix _matrix(String data, bool robust) => _matrices.putIfAbsent((
    data,
    robust,
  ), () => QrMatrix.encode(data, robust: robust));

  /// The code of [data] can carry the logo.
  bool _logoFits(String data) {
    try {
      return _matrix(data, true).logoHole != null;
    } on Object {
      return false;
    }
  }

  /// The design as drawn: no logo where the code cannot carry one.
  StickerDesign get _drawn {
    final StickerDesign d = _design;
    return d.logo && !_logoFits(_subject.data) ? d.copyWith(logo: false) : d;
  }

  StickerScene _scene() {
    final StickerDesign d = _drawn;
    return StickerScene.build(_matrix(_subject.data, d.logo), d);
  }

  Future<void> _presets() async {
    final List<StickerTexts> presets = stickerPresets(
      _subject.kind,
      name: _subject.name,
    );
    final StickerTexts? picked = await showModalBottomSheet<StickerTexts>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) {
        final ZenColors zen = ZenColors.of(context);
        return SafeArea(
          child: ListView(
            key: const Key('sticker-presets'),
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  t('Gotowe teksty'),
                  style: zen.display(
                    color: zen.textPrimary,
                    size: 18,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              for (final (int i, StickerTexts p) in presets.indexed)
                ListTile(
                  key: Key('sticker-preset-$i'),
                  leading: const Icon(Icons.format_quote_rounded),
                  title: Text(
                    <String>[
                      p.top,
                      p.caption,
                      p.bottom,
                    ].where((String s) => s.isNotEmpty).join(' · '),
                  ),
                  onTap: () => Navigator.of(context).pop(p),
                ),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) {
      return;
    }
    _change(_design.copyWith(texts: picked));
    _showTexts();
  }

  Future<Uint8List?> _export(StickerFormat format) async {
    setState(() => _busy = true);
    try {
      return await exportSticker(_scene(), _drawn, format: format);
    } on Object catch (error, stack) {
      logZenError('Sticker export', error, stack);
      _say(t('Nie udało się przygotować naklejki.'));
      return null;
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _fileName(StickerFormat format) =>
      '${_subject.kind.fileStem}.${format.extension}';

  void _say(String text, {SnackBarAction? action}) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text), action: action));
  }

  Future<void> _save() async {
    final StickerFormat format = _design.format;
    final Uint8List? bytes = await _export(format);
    if (bytes == null || !mounted) {
      return;
    }
    final StickerOutlet outlet = ref.read(stickerOutletProvider);
    try {
      final String? saved = await outlet.save(
        _fileName(format),
        bytes,
        format.mime,
      );
      if (saved == null) {
        return;
      }
      _say(
        t('Zapisano: {path}', <String, Object?>{'path': saved}),
        action: outlet.canOpen
            ? SnackBarAction(
                label: t('Otwórz'),
                onPressed: () => unawaited(outlet.open(saved)),
              )
            : null,
      );
    } on Object catch (error, stack) {
      logZenError('Saving the sticker', error, stack);
      _say(t('Nie udało się zapisać naklejki.'));
    }
  }

  Future<void> _share() async {
    final StickerFormat format = _design.format;
    final Uint8List? bytes = await _export(format);
    if (bytes == null || !mounted) {
      return;
    }
    final bool ok = await ref
        .read(stickerOutletProvider)
        .share(_fileName(format), bytes, format.mime);
    if (!ok) {
      _say(t('Nie udało się otworzyć udostępniania.'));
    }
  }

  Future<void> _print() async {
    final Uint8List? pdf = await _export(StickerFormat.pdf);
    if (pdf == null || !mounted) {
      return;
    }
    final bool ok = await ref
        .read(stickerOutletProvider)
        .printPdf(_fileName(StickerFormat.pdf), pdf);
    if (!ok) {
      _say(t('Nie udało się otworzyć drukowania.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final StickerDesign design = _design;
    final StickerScene scene = _scene();
    final StickerOutlet outlet = ref.watch(stickerOutletProvider);
    final bool logoFits = _logoFits(_subject.data);
    final List<String> texts = <String>[
      design.texts.top,
      design.texts.caption,
      design.texts.bottom,
    ].map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList();

    Widget label(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
      child: Text(text, style: zen.label(color: zen.textSecondary)),
    );

    Widget chips<T>(
      String key,
      List<T> values,
      T selected,
      String Function(T) name,
      void Function(T) pick, {
      Widget? Function(T)? avatar,
    }) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final T v in values)
          ChoiceChip(
            key: Key('sticker-$key-${v is Enum ? v.name : v}'),
            label: Text(name(v)),
            avatar: avatar?.call(v),
            selected: v == selected,
            onSelected: (_) => pick(v),
          ),
      ],
    );

    return Scaffold(
      key: const Key('sticker-designer'),
      appBar: AppBar(title: Text(t('Naklejka z kodem QR'))),
      body: SafeArea(
        top: false,
        child: ListView(
          key: const Key('sticker-designer-list'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Semantics(
                    image: true,
                    label: texts.isEmpty
                        ? t('Podgląd naklejki z kodem QR')
                        : t(
                            'Podgląd naklejki z kodem QR: {texts}',
                            <String, Object?>{'texts': texts.join(', ')},
                          ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: zen.outlineSoft),
                        boxShadow: ZenLook.of(context).lift(zen, radius: 12),
                      ),
                      child: StickerPreview(
                        key: const Key('sticker-preview'),
                        scene: scene,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              t(
                'Kwadrat stoi na środku strony: po wydruku przytnij go po '
                'brzegach (albo po liniach cięcia).',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(color: zen.textMuted, fontSize: 12.5),
            ),
            if (widget.subjects.length > 1) ...<Widget>[
              ZenSection(t('Co otwiera kod')),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final (int i, StickerSubject s)
                      in widget.subjects.indexed)
                    ChoiceChip(
                      key: Key('sticker-subject-${s.kind.name}'),
                      label: Text(s.label),
                      selected: i == _chosen,
                      onSelected: (_) {
                        if (i == _chosen) {
                          return;
                        }
                        setState(() => _chosen = i);
                        _showTexts();
                      },
                    ),
                ],
              ),
            ],
            ZenSection(t('Teksty')),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                key: const Key('sticker-presets-open'),
                onPressed: () => unawaited(_presets()),
                icon: const Icon(Icons.format_quote_rounded),
                label: Text(t('Gotowe teksty')),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('sticker-top'),
              minLines: 1,
              maxLines: 3,
              controller: _top,
              maxLength: StickerDesign.maxText,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: t('Napis na górze')),
              onChanged: (_) => _textsChanged(),
            ),
            TextField(
              key: const Key('sticker-caption'),
              controller: _caption,
              maxLength: StickerDesign.maxCaption,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: t('Mały napis pod kodem')),
              onChanged: (_) => _textsChanged(),
            ),
            TextField(
              key: const Key('sticker-bottom'),
              minLines: 1,
              maxLines: 3,
              controller: _bottom,
              maxLength: StickerDesign.maxText,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: t('Napis na dole')),
              onChanged: (_) => _textsChanged(),
            ),
            SwitchListTile(
              key: const Key('sticker-signature'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              title: Text(t('Podpis „Zen” w rogu')),
              value: design.signature,
              onChanged: (bool v) => _change(design.copyWith(signature: v)),
            ),
            ZenSection(t('Wygląd')),
            label(t('STYL KODU')),
            chips<QrStyle>(
              'style',
              QrStyle.values,
              design.style,
              (QrStyle s) => s.label,
              (QrStyle s) => _change(design.copyWith(style: s)),
            ),
            SwitchListTile(
              key: const Key('sticker-logo'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              title: Text(t('Logo Zen w środku kodu')),
              subtitle: Text(
                logoFits
                    ? t(
                        'Kod dostaje wtedy najmocniejszą korekcję błędów, '
                        'więc logo nie przeszkadza w skanowaniu.',
                      )
                    : t(
                        'Ten kod jest za gęsty na logo — zostaje bez niego, '
                        'żeby każdy aparat go odczytał.',
                      ),
              ),
              value: design.logo && logoFits,
              onChanged: logoFits
                  ? (bool v) => _change(design.copyWith(logo: v))
                  : null,
            ),
            label(t('KOLORY')),
            chips<StickerTheme>(
              'theme',
              StickerTheme.values,
              design.theme,
              (StickerTheme s) => s.label,
              (StickerTheme s) => _change(design.copyWith(theme: s)),
              avatar: (StickerTheme s) => CircleAvatar(
                backgroundColor: Color(s.accent),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(s.ink),
                      shape: BoxShape.circle,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            label(t('WZOREK')),
            chips<StickerPattern>(
              'pattern',
              StickerPattern.values,
              design.pattern,
              (StickerPattern s) => s.label,
              (StickerPattern s) => _change(design.copyWith(pattern: s)),
            ),
            ZenSection(t('Wydruk')),
            label(t('FORMAT STRONY')),
            chips<StickerPage>(
              'page',
              StickerPage.values,
              design.page,
              (StickerPage s) => s.label,
              (StickerPage s) => _change(design.copyWith(page: s)),
            ),
            if (design.page.hasOrientation) ...<Widget>[
              label(t('UKŁAD')),
              chips<bool>(
                'landscape',
                const <bool>[false, true],
                design.landscape,
                (bool v) => v ? t('Poziomo') : t('Pionowo'),
                (bool v) => _change(design.copyWith(landscape: v)),
              ),
            ],
            if (design.page.hasMargins)
              SwitchListTile(
                key: const Key('sticker-crop-marks'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                title: Text(t('Linie cięcia')),
                value: design.cropMarks,
                onChanged: (bool v) => _change(design.copyWith(cropMarks: v)),
              ),
            label(t('PLIK')),
            chips<StickerFormat>(
              'format',
              StickerFormat.values,
              design.format,
              (StickerFormat s) => s.label,
              (StickerFormat s) => _change(design.copyWith(format: s)),
            ),
            const SizedBox(height: 18),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: LinearProgressIndicator(),
              ),
            FilledButton.icon(
              key: const Key('sticker-save'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: _busy ? null : () => unawaited(_save()),
              icon: const Icon(Icons.download_rounded),
              label: Text(
                t('Zapisz jako {format}', <String, Object?>{
                  'format': design.format.label,
                }),
              ),
            ),
            if (outlet.canShare || outlet.canPrint) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  if (outlet.canShare)
                    OutlinedButton.icon(
                      key: const Key('sticker-share'),
                      onPressed: _busy ? null : () => unawaited(_share()),
                      icon: const Icon(Icons.share_rounded),
                      label: Text(t('Udostępnij')),
                    ),
                  if (outlet.canPrint)
                    OutlinedButton.icon(
                      key: const Key('sticker-print'),
                      onPressed: _busy ? null : () => unawaited(_print()),
                      icon: const Icon(Icons.print_rounded),
                      label: Text(t('Drukuj')),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A sticker drawn at the size it gets (a square).
class StickerPreview extends StatelessWidget {
  const StickerPreview({required this.scene, super.key});

  final StickerScene scene;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _StickerPainter(scene),
      child: const SizedBox.expand(),
    ),
  );
}

class _StickerPainter extends CustomPainter {
  const _StickerPainter(this.scene);

  final StickerScene scene;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..scale(size.shortestSide / StickerScene.side);
    paintStickerScene(canvas, scene);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StickerPainter old) => !identical(old.scene, scene);
}

/// The remembered design of [subject]'s kind, drawn small (the door screen
/// shows the sticker it would print).
class StoredStickerPreview extends ConsumerStatefulWidget {
  const StoredStickerPreview({required this.subject, super.key});

  final StickerSubject subject;

  @override
  ConsumerState<StoredStickerPreview> createState() =>
      _StoredStickerPreviewState();
}

class _StoredStickerPreviewState extends ConsumerState<StoredStickerPreview> {
  StickerDesign? _kept;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final StickerDesign? kept = await ref
        .read(stickerStoreProvider)
        .load(widget.subject.kind);
    if (mounted && kept != null) {
      setState(() => _kept = kept);
    }
  }

  @override
  Widget build(BuildContext context) {
    final StickerSubject s = widget.subject;
    StickerDesign design = _kept ?? StickerDesign.initial(s.kind, name: s.name);
    QrMatrix matrix = StickerScene.matrixFor(s.data, design);
    if (design.logo && matrix.logoHole == null) {
      design = design.copyWith(logo: false);
      matrix = StickerScene.matrixFor(s.data, design);
    }
    return StickerPreview(scene: StickerScene.build(matrix, design));
  }
}

/// The button under a printable QR code that opens the designer.
class StickerButton extends StatelessWidget {
  const StickerButton({required this.subject, super.key});

  final StickerSubject subject;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () => unawaited(
      StickerDesignerScreen.open(context, <StickerSubject>[subject]),
    ),
    icon: const Icon(Icons.print_rounded),
    label: Text(t('Naklejka do druku')),
  );
}
