// The demo account of the website's pictures: made-up people with drawn
// faces, a conversation, a group, posts, friends of friends and the dates
// the friends graph grew by, in Polish or English. Nobody here is a real
// person and every picture is drawn from code, so every run shows the same.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// One made-up person.
final class DemoPerson {
  const DemoPerson(this.index, this.name, this.palette);

  final int index;
  final String name;

  /// Background, hair, skin and shirt of the drawn face.
  final List<List<int>> palette;

  /// A mesh address of the same shape as a real one (made up).
  String get address {
    final String n = index.toRadixString(16).padLeft(2, '0');
    return '201:5e$n:d0c5:1a7e:4b2:91c3:7e$n:2a4f';
  }
}

const List<List<int>> _backgrounds = <List<int>>[
  <int>[255, 214, 186],
  <int>[196, 226, 255],
  <int>[214, 240, 205],
  <int>[236, 214, 255],
  <int>[255, 236, 179],
  <int>[255, 205, 222],
  <int>[200, 236, 236],
  <int>[226, 226, 240],
];
const List<List<int>> _hair = <List<int>>[
  <int>[74, 48, 34],
  <int>[28, 24, 30],
  <int>[176, 112, 54],
  <int>[222, 180, 104],
  <int>[120, 72, 44],
  <int>[150, 60, 42],
  <int>[96, 96, 104],
];
const List<List<int>> _skin = <List<int>>[
  <int>[247, 214, 190],
  <int>[233, 190, 158],
  <int>[198, 145, 108],
  <int>[150, 104, 72],
  <int>[240, 200, 170],
];
const List<List<int>> _shirts = <List<int>>[
  <int>[109, 61, 245],
  <int>[33, 150, 120],
  <int>[230, 110, 70],
  <int>[40, 110, 200],
  <int>[200, 60, 140],
  <int>[70, 70, 90],
];

/// The colours of this person's own face.
const List<List<int>> demoOwnPalette = <List<int>>[
  <int>[214, 226, 255],
  <int>[92, 56, 40],
  <int>[244, 206, 178],
  <int>[109, 61, 245],
];

DemoPerson _person(int i, String name) => DemoPerson(i, name, <List<int>>[
  _backgrounds[i % _backgrounds.length],
  _hair[(i * 3) % _hair.length],
  _skin[(i * 2 + 1) % _skin.length],
  _shirts[(i * 5) % _shirts.length],
]);

/// The texts and people of the demo in one language.
final class DemoAccount {
  DemoAccount._(this.lang, this.me, this.friends, this.far, this.texts);

  factory DemoAccount.of(String lang) {
    final bool pl = lang == 'pl';
    final List<String> friendNames = pl
        ? <String>['Ola', 'Kuba', 'Zosia', 'Marek', 'Ewa', 'Tomek', 'Hania']
        : <String>['Ada', 'Ben', 'Chloe', 'Dan', 'Emma', 'Finn', 'Grace'];
    final List<String> farNames = pl
        ? <String>[
            'Basia',
            'Wojtek',
            'Kasia',
            'Piotr',
            'Lena',
            'Szymon',
            'Natalia',
            'Adam',
            'Maja',
            'Igor',
          ]
        : <String>[
            'Iris',
            'Jack',
            'Kate',
            'Leo',
            'Mia',
            'Noah',
            'Olive',
            'Paul',
            'Rosa',
            'Theo',
          ];
    return DemoAccount._(
      lang,
      pl ? 'Anna' : 'Sam',
      <DemoPerson>[
        for (int i = 0; i < friendNames.length; i++)
          _person(i + 1, friendNames[i]),
      ],
      <DemoPerson>[
        for (int i = 0; i < farNames.length; i++) _person(i + 20, farNames[i]),
      ],
      pl ? _pl : _en,
    );
  }

  final String lang;

  /// This person's own name.
  final String me;

  /// Friends, the first one in the conversation.
  final List<DemoPerson> friends;

  /// Friends of friends (on the friends graph).
  final List<DemoPerson> far;
  final Map<String, String> texts;

  /// This device's own (made-up) mesh address.
  String get ownAddress => '200:5ee:d0c5:1a7e:4b2:91c3:7e10:2a4f';

  String text(String key) => texts[key]!;

  /// Friends of friends each friend shares: friend index -> far indexes.
  static const Map<int, List<int>> friendLists = <int, List<int>>{
    0: <int>[0, 1, 2],
    1: <int>[2, 3, 4],
    2: <int>[4, 5],
    3: <int>[6, 7, 1],
    4: <int>[8, 9],
    5: <int>[3, 9],
    6: <int>[5, 0],
  };

  /// Friends who know each other: pairs of friend indexes.
  static const List<(int, int)> friendPairs = <(int, int)>[
    (0, 1),
    (0, 4),
    (1, 2),
    (3, 5),
    (4, 6),
  ];

  /// Days ago each friend became one (the graph's timeline).
  static const List<int> friendDaysAgo = <int>[340, 300, 250, 190, 120, 60, 12];

  /// Days ago each friend of a friend was first seen.
  static const List<int> farDaysAgo = <int>[
    330,
    290,
    260,
    240,
    200,
    150,
    110,
    90,
    45,
    20,
  ];
}

const Map<String, String> _pl = <String, String>{
  'c1': 'Cześć! Zdjęcie z wczorajszego spaceru nad jeziorem.',
  'c2': 'Pięknie! Musimy tam pojechać razem.',
  'c4': 'Jestem za. 10:00 przy moście?',
  'c5': 'Super, wezmę termos z herbatą.',
  'c6': 'Do zobaczenia w sobotę!',
  'send': 'Wezmę też kanapki dla wszystkich',
  'p1':
      'Pierwszy przymrozek na działce. Kto pomoże w sobotę przy '
      'jesiennych porządkach? Będzie zupa dyniowa!',
  'p2':
      'Dziękuję wszystkim za wczorajsze ognisko: ciepło, spokojnie i '
      'bardzo po naszemu.',
  'p3': 'Wschód słońca nad jeziorem. Warto było wstać o piątej.',
  'group': 'Górskie wędrówki',
  'groupAbout': 'Szlaki, mapy i podwózki na start',
  'g1': 'Prognoza na sobotę wygląda dobrze.',
  'g2': 'To jedziemy! Zbiórka o 8:00 na dworcu?',
  'g3': 'Pasuje. Wezmę mapę i apteczkę.',
  'g4': 'Ja biorę termosy. Kto ma miejsce w aucie?',
  'g5': 'Mam trzy wolne miejsca.',
  'l0': 'Do zobaczenia w sobotę!',
  'l1': 'Zdjęcia z wycieczki są w grupie.',
  'l2': 'Dzięki za przepis na zupę!',
  'l3': 'Zadzwonię po pracy.',
  'l4': 'Liczcie na mnie w sobotę.',
  'l5': 'Haha, dobre.',
  'l6': 'Do jutra!',
  'yesterday': 'Wczoraj',
  'mon': 'pon.',
  'sun': 'niedz.',
};

const Map<String, String> _en = <String, String>{
  'c1': 'Hi! A photo from yesterday\'s walk by the lake.',
  'c2': 'Beautiful! We have to go there together.',
  'c4': 'Count me in. 10 am at the bridge?',
  'c5': 'Great, I\'ll bring a flask of tea.',
  'c6': 'See you on Saturday!',
  'send': 'I\'ll bring sandwiches for everyone too',
  'p1':
      'First frost at the allotment. Anyone up for autumn tidying on '
      'Saturday? There will be pumpkin soup!',
  'p2':
      'Thank you all for the bonfire last night: quiet, warm and very '
      'much us.',
  'p3': 'Sunrise over the lake. Worth getting up at five.',
  'group': 'Weekend hikers',
  'groupAbout': 'Trails, maps and lifts to the start',
  'g1': 'The forecast for Saturday looks good.',
  'g2': 'Let\'s go then! 8 am at the station?',
  'g3': 'Works for me. I\'ll bring the map and a first-aid kit.',
  'g4': 'I\'ll take the flasks. Who has room in a car?',
  'g5': 'I have three free seats.',
  'l0': 'See you on Saturday!',
  'l1': 'Photos from the hike are in the group.',
  'l2': 'Thanks for the soup recipe!',
  'l3': 'I\'ll call you after work.',
  'l4': 'Count me in for Saturday.',
  'l5': 'Ha, good one.',
  'l6': 'See you tomorrow!',
  'yesterday': 'Yesterday',
  'mon': 'Mon',
  'sun': 'Sun',
};

double _smooth(double edge, double d) =>
    (0.5 - d / edge).clamp(0.0, 1.0).toDouble();

List<int> _mix(List<int> a, List<int> b, double k) => <int>[
  for (int i = 0; i < 3; i++) (a[i] + (b[i] - a[i]) * k).round(),
];

/// A drawn face: hair, head, eyes, a smile and shoulders on a pastel
/// background, as a PNG of [size] pixels.
Uint8List drawAvatar(DemoPerson p, {int size = 192}) {
  final img.Image image = img.Image(width: size, height: size);
  final double s = size.toDouble();
  final List<int> bg = p.palette[0];
  final List<int> hair = p.palette[1];
  final List<int> skin = p.palette[2];
  final List<int> shirt = p.palette[3];
  final List<int> ink = <int>[52, 40, 44];
  final bool longHair = p.index.isOdd;
  double circle(double x, double y, double cx, double cy, double r) =>
      math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) - r;
  for (int py = 0; py < size; py++) {
    for (int px = 0; px < size; px++) {
      final double x = (px + 0.5) / s;
      final double y = (py + 0.5) / s;
      final double aa = 1.5 / s;
      List<int> c = _mix(bg, <int>[255, 255, 255], y * 0.25);
      // Long hair falls behind the shoulders.
      if (longHair) {
        final double back = math.max(
          circle(x, y, 0.5, 0.47, 0.27),
          -(0.72 - y),
        );
        c = _mix(c, hair, _smooth(aa, back));
      }
      c = _mix(c, shirt, _smooth(aa, circle(x, y * 1.15, 0.5, 1.22, 0.40)));
      c = _mix(c, skin, _smooth(aa, circle(x, y, 0.5, 0.80, 0.075)));
      c = _mix(c, hair, _smooth(aa, circle(x, y, 0.5, 0.40, 0.235)));
      // The face, under the fringe.
      final double face = math.max(
        circle(x, y * 0.94, 0.5, 0.47, 0.20),
        -(y - (0.36 + 0.04 * math.cos((x - 0.5) * 9))),
      );
      c = _mix(c, skin, _smooth(aa, face));
      for (final double ex in <double>[0.43, 0.57]) {
        c = _mix(c, ink, _smooth(aa, circle(x, y, ex, 0.48, 0.018)));
      }
      final double smile = (circle(x, y, 0.5, 0.505, 0.075)).abs() - 0.008;
      if (y > 0.54) {
        c = _mix(c, ink, _smooth(aa, smile) * 0.9);
      }
      for (final double cx in <double>[0.39, 0.61]) {
        c = _mix(c, <int>[
          240,
          130,
          130,
        ], _smooth(aa, circle(x, y, cx, 0.54, 0.028)) * 0.35);
      }
      image.setPixelRgb(px, py, c[0], c[1], c[2]);
    }
  }
  return img.encodePng(image);
}

/// A landscape drawn from code: a sky in two colours, a sun, hills and a
/// lake with the sun's reflection, as a JPEG.
Uint8List drawLandscape(
  int width,
  int height, {
  required List<int> top,
  required List<int> bottom,
  required List<int> sun,
  required List<int> hills,
  List<int>? water,
  double sunX = 0.62,
}) {
  final img.Image image = img.Image(width: width, height: height);
  final double cx = width * sunX;
  final double cy = height * 0.42;
  final double r = width * 0.11;
  final double lake = height * 0.78;
  for (int y = 0; y < height; y++) {
    final double k = y / (height - 1);
    for (int x = 0; x < width; x++) {
      final double far =
          height * 0.60 +
          math.sin(x / width * math.pi * 3.1 + 1) * height * 0.04;
      final double near =
          height * 0.68 + math.sin(x / width * math.pi * 2.2) * height * 0.05;
      final double dx = x - cx;
      final double dy = y - cy;
      List<int> c = <int>[
        for (int i = 0; i < 3; i++) (top[i] + (bottom[i] - top[i]) * k).round(),
      ];
      final double glow = math.max(
        0,
        1 - math.sqrt(dx * dx + dy * dy) / (r * 3),
      );
      c = _mix(c, sun, glow * 0.35);
      if (dx * dx + dy * dy < r * r) {
        c = sun;
      }
      if (y > far) {
        c = _mix(hills, bottom, 0.45);
      }
      if (y > near) {
        c = hills;
      }
      if (water != null && y > lake) {
        final double shimmer =
            (x - cx).abs() < r * (1.2 - (y - lake) / height * 2) &&
                (y ~/ 4).isEven
            ? 0.55
            : 0;
        c = _mix(
          _mix(water, top, (y - lake) / (height - lake) * 0.3),
          sun,
          shimmer,
        );
      }
      image.setPixelRgb(x, y, c[0], c[1], c[2]);
    }
  }
  return img.encodeJpg(image, quality: 85);
}

/// The photo of the conversation: an evening lake.
Uint8List lakePhoto() => drawLandscape(
  640,
  400,
  top: <int>[255, 150, 112],
  bottom: <int>[255, 222, 182],
  sun: <int>[255, 246, 222],
  hills: <int>[58, 84, 96],
  water: <int>[92, 120, 150],
);

/// The photo of a post: a sunrise.
Uint8List sunrisePhoto() => drawLandscape(
  720,
  540,
  top: <int>[120, 160, 230],
  bottom: <int>[255, 214, 170],
  sun: <int>[255, 244, 210],
  hills: <int>[70, 96, 80],
  water: <int>[90, 130, 170],
  sunX: 0.35,
);

/// The photo of the group: hills in the morning.
Uint8List hillsPhoto() => drawLandscape(
  640,
  360,
  top: <int>[150, 200, 240],
  bottom: <int>[230, 244, 250],
  sun: <int>[255, 250, 230],
  hills: <int>[80, 130, 90],
  sunX: 0.75,
);
