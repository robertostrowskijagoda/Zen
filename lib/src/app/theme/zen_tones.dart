import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// What a coloured element is about. Every screen colours the same meaning
/// the same way ([ZenToneColors.tone]): a row about your people is blue in
/// the settings, on the rail and in the feed alike.
enum ZenTone {
  /// Friends, profiles, contacts, invitations.
  people,

  /// Chats, messages, calls, notifications, languages.
  communication,

  /// Connection, nodes, mailboxes, devices on the network.
  network,

  /// Meeting people: places, events, nearby, neighbours.
  places,

  /// Money, the wallet, the pyramid.
  money,

  /// Photos, films, sounds, GIFs, posts.
  media,

  /// The look of the app: themes, colours.
  appearance,

  /// Privacy and security: keys, passwords, locks, permissions.
  privacy,

  /// Danger and safety: the alarm, blocking, deleting.
  safety,

  /// The app itself: storage, updates, diagnostics, information.
  system,
}

/// The colour of a tone in a palette.
extension ZenToneColors on ZenColors {
  /// [tone] in this palette: readable as text (4.5:1) on the background,
  /// the surface and raised surfaces.
  Color tone(ZenTone tone) => ZenTones.of(this)[tone.index];
}

/// The tone map of every palette, defined once.
///
/// A colourful palette gives each tone its own hue (the same hues in every
/// colourful palette, in that palette's saturation). A restricted palette
/// ([ZenColors.duotone]: the terminals, the player, the neon looks, Onyks,
/// the monochrome Klasyczny) maps every tone to shades of its own few
/// colours by one fixed table, so nothing ever falls back to a colour from
/// outside the palette. Either way every tone is moved, if needed, until it
/// reads at 4.5:1 on the background, the surface and raised surfaces.
abstract final class ZenTones {
  /// The hue of each tone in colourful palettes (null: from the palette:
  /// safety is its danger colour, system its secondary text colour).
  static const List<double?> hues = <double?>[
    210, // people: blue
    170, // communication: teal
    246, // network: indigo
    128, // places: green
    40, // money: amber
    326, // media: pink
    18, // appearance: orange
    286, // privacy: violet
    null, // safety: the palette's danger red
    null, // system: the palette's neutral
  ];

  /// Restricted palettes: the base colour of each tone (0 accent,
  /// 1 accentSecondary, 2 accentTertiary, 3 danger, 4 secondary text) and
  /// a lightness step (positive: further from the background).
  static const List<(int, double)> restricted = <(int, double)>[
    (0, 0), // people
    (2, 0), // communication
    (0, -0.14), // network
    (1, 0), // places
    (1, -0.14), // money
    (2, 0.14), // media
    (0, 0.16), // appearance
    (2, -0.14), // privacy
    (3, 0), // safety
    (4, 0), // system
  ];

  /// The tones of the old numbered feature colours ([zenTone]).
  static const List<ZenTone> numbered = <ZenTone>[
    ZenTone.privacy,
    ZenTone.media,
    ZenTone.appearance,
    ZenTone.money,
    ZenTone.network,
    ZenTone.places,
    ZenTone.communication,
    ZenTone.people,
  ];

  /// The contrast every tone keeps (a little over 4.5:1 for rounding).
  static const double minContrast = 4.6;

  static final Expando<List<Color>> _cache = Expando<List<Color>>('zen tones');

  /// The tones of [zen], in [ZenTone] order.
  static List<Color> of(ZenColors zen) => _cache[zen] ??= _resolve(zen);

  static List<Color> _resolve(ZenColors zen) {
    final bool dark = zen.background.computeLuminance() < 0.2;
    final List<Color> out = <Color>[];
    if (zen.duotone) {
      final List<Color> bases = <Color>[
        zen.accent,
        zen.accentSecondary,
        zen.accentTertiary,
        zen.danger,
        zen.textSecondary,
      ];
      for (final (int base, double step) in restricted) {
        final HSLColor h = HSLColor.fromColor(bases[base]);
        out.add(
          _fit(
            h.withLightness(
              (h.lightness + (dark ? step : -step)).clamp(0.0, 1.0),
            ),
            zen,
            dark,
          ),
        );
      }
      return List<Color>.unmodifiable(out);
    }
    final double s = zen.toneSaturation.clamp(0.34, 0.85);
    for (int i = 0; i < hues.length; i++) {
      final double? hue = hues[i];
      final HSLColor h = hue != null
          ? HSLColor.fromAHSL(1, hue, s, dark ? 0.68 : 0.42)
          : HSLColor.fromColor(
              i == ZenTone.safety.index ? zen.danger : zen.textSecondary,
            );
      out.add(_fit(h, zen, dark));
    }
    return List<Color>.unmodifiable(out);
  }

  /// [h], made lighter (dark palettes) or darker (light ones) until it
  /// reads on every ground of [zen].
  static Color _fit(HSLColor h, ZenColors zen, bool dark) {
    final List<Color> grounds = <Color>[
      zen.surface,
      zen.background,
      zen.surfaceRaised,
    ];
    HSLColor x = h;
    for (int i = 0; i < 100; i++) {
      final Color c = x.toColor();
      if (grounds.every((Color g) => contrast(c, g) >= minContrast)) {
        return c;
      }
      x = x.withLightness(
        (x.lightness + (dark ? 0.01 : -0.01)).clamp(0.0, 1.0),
      );
    }
    return x.toColor();
  }

  /// The WCAG contrast ratio of [a] and [b].
  static double contrast(Color a, Color b) {
    final double la = a.computeLuminance();
    final double lb = b.computeLuminance();
    final double hi = la > lb ? la : lb;
    final double lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }
}
