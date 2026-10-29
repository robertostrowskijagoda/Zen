// The pictures and short films of the website (tool/pages/shots): which
// screens, in which languages, themes and sizes, and how large the files
// may be. Read by the screen renderer (site_screens_test.dart), by
// `dart run tool/screenshots.dart` and by test/pages_site_test.dart, so the
// three never disagree. Plain Dart: no Flutter here.

/// Where the website's pictures are kept.
const String kShotsDir = 'tool/pages/shots';

/// Where the renderer leaves its full-size PNG frames for the encoder
/// (outside the repository's tracked files).
const String kShotsRawDir = 'build/shots';

/// The languages the pictures are made in; every other language of the
/// site shows the English ones.
const List<String> kShotLanguages = <String>['pl', 'en'];

/// The fallback language of the pictures.
const String kShotFallbackLanguage = 'en';

/// Every picture is made in the light and the dark theme.
const List<String> kShotThemes = <String>['light', 'dark'];

/// A picture or film size: logical pixels and the device pixel ratio.
enum ShotSize {
  /// A phone: 360 x 780 dp at 3x, 1080 x 2340 pixels.
  phone(360, 780, 3),

  /// A computer window: 1440 x 900 pixels.
  desktop(1440, 900, 1);

  const ShotSize(this.width, this.height, this.ratio);

  final double width;
  final double height;
  final double ratio;

  int get pixelWidth => (width * ratio).round();
  int get pixelHeight => (height * ratio).round();
}

/// One screen of the app on the website.
final class SiteShot {
  const SiteShot(this.id, {this.size = ShotSize.phone});

  final String id;
  final ShotSize size;
}

/// The screens, in the order of the gallery.
const List<SiteShot> kSiteShots = <SiteShot>[
  SiteShot('chats'),
  SiteShot('conversation'),
  SiteShot('group'),
  SiteShot('feed'),
  SiteShot('graph'),
  SiteShot('graph-timeline'),
  SiteShot('nearby'),
  SiteShot('notifications'),
  SiteShot('storage'),
  SiteShot('lock'),
  SiteShot('desktop', size: ShotSize.desktop),
];

/// A short looping film made of rendered frames, shown at half the phone's
/// resolution, with a still poster (the last frame) for visitors who asked
/// for less motion.
final class SiteFilm {
  const SiteFilm(this.id);

  final String id;
}

const List<SiteFilm> kSiteFilms = <SiteFilm>[
  SiteFilm('send-message'),
  SiteFilm('graph-growth'),
];

/// The largest a picture may be.
const int kShotMaxBytes = 150 * 1024;

/// The largest a film may be.
const int kFilmMaxBytes = 2 * 1024 * 1024;

/// The largest a film's poster may be.
const int kPosterMaxBytes = 120 * 1024;

/// A film's frames are this fraction of the phone's pixels.
const double kFilmScale = 0.5;

/// The picture of [id] in [lang] and [theme], from the site's root.
String shotPath(String lang, String id, String theme) =>
    'shots/$lang/$id-$theme.webp';

/// A film, from the site's root.
String filmPath(String lang, String id, String theme) =>
    'shots/$lang/$id-$theme.webp';

/// A film's still poster, from the site's root.
String posterPath(String lang, String id, String theme) =>
    'shots/$lang/$id-$theme-poster.webp';

/// Every file the website needs, from the site's root, with the most it
/// may weigh.
Map<String, int> expectedShotFiles() => <String, int>{
  for (final String lang in kShotLanguages)
    for (final String theme in kShotThemes) ...<String, int>{
      for (final SiteShot s in kSiteShots)
        shotPath(lang, s.id, theme): kShotMaxBytes,
      for (final SiteFilm f in kSiteFilms) ...<String, int>{
        filmPath(lang, f.id, theme): kFilmMaxBytes,
        posterPath(lang, f.id, theme): kPosterMaxBytes,
      },
    },
};
