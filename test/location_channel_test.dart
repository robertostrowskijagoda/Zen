import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/meet/location.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('zen/location-test');
  const ChannelGeoSource source = ChannelGeoSource(channel: channel);

  /// The platform side: [answers] by method name (a function gets the
  /// call); every call is recorded.
  List<MethodCall> platform(Map<String, Object?> answers) {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          final Object? answer = answers[call.method];
          if (answer is Object? Function(MethodCall)) {
            return answer(call);
          }
          return answer;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    return calls;
  }

  final GeoSource realSource = geoSource;
  tearDown(() => geoSource = realSource);

  test(
    'permission names map onto the steps; anything else is unknown',
    () async {
      for (final LocationPermission p in LocationPermission.values) {
        platform(<String, Object?>{'check': p.name, 'request': p.name});
        expect(await source.checkPermission(), p);
        expect(await source.requestPermission(), p);
      }
      platform(<String, Object?>{'check': 'maybe', 'request': null});
      expect(
        await source.checkPermission(),
        LocationPermission.unableToDetermine,
      );
      expect(
        await source.requestPermission(),
        LocationPermission.unableToDetermine,
      );
    },
  );

  test(
    'a fresh position: the time limit goes along, the map comes back',
    () async {
      final List<MethodCall> calls = platform(<String, Object?>{
        'current': <String, Object?>{
          'lat': 54.35,
          'lon': 18.65,
          'accuracy': 7.5,
          'at': 1760000000000,
        },
      });
      final GeoFix fix = await source.current(const Duration(seconds: 12));
      expect(fix.lat, 54.35);
      expect(fix.lon, 18.65);
      expect(fix.accuracy, 7.5);
      expect(fix.at, DateTime.fromMillisecondsSinceEpoch(1760000000000));
      expect(calls.single.arguments, <String, Object?>{'timeoutMs': 12000});
    },
  );

  test('under the service the notification texts go along', () async {
    final List<MethodCall> calls = platform(<String, Object?>{
      'current': <String, Object?>{'lat': 1, 'lon': 2},
    });
    final GeoFix fix = await source.currentUnderService(
      const Duration(seconds: 15),
    );
    expect(fix.lat, 1);
    expect(fix.accuracy, 0);
    expect(fix.at, isNull);
    final Map<Object?, Object?> args =
        calls.single.arguments as Map<Object?, Object?>;
    expect(args['timeoutMs'], 15000);
    expect(args['background'], isTrue);
    expect(args['title'], 'Zen');
    expect(args['text'], isA<String>());
    expect(args['channel'], isA<String>());
  });

  test('an impossible or missing position is no position', () async {
    for (final Object? bad in <Object?>[
      null,
      'here',
      <String, Object?>{'lat': 91, 'lon': 0},
      <String, Object?>{'lat': 0, 'lon': -181},
      <String, Object?>{'lat': double.nan, 'lon': 0},
      <String, Object?>{'lon': 0},
    ]) {
      platform(<String, Object?>{'current': bad, 'lastKnown': bad});
      await expectLater(
        source.current(const Duration(seconds: 1)),
        throwsStateError,
      );
      expect(await source.lastKnown(), isNull);
    }
  });

  test('the whole alarm flow over the channel: asks, then reads', () async {
    final List<MethodCall> calls = platform(<String, Object?>{
      'serviceEnabled': true,
      'check': 'denied',
      'request': 'whileInUse',
      'current': <String, Object?>{'lat': 52.23, 'lon': 21.01, 'accuracy': 20},
    });
    geoSource = source;
    final GeoFix? fix = await currentFix();
    expect(fix!.lat, 52.23);
    expect(calls.map((MethodCall c) => c.method), <String>[
      'serviceEnabled',
      'check',
      'request',
      'current',
    ]);
  });

  test('no fresh position in time: the last known one', () async {
    final List<MethodCall> calls = platform(<String, Object?>{
      'serviceEnabled': true,
      'check': 'always',
      'current': (MethodCall call) =>
          throw PlatformException(code: 'timeout', message: 'No position'),
      'lastKnown': <String, Object?>{'lat': 50.06, 'lon': 19.94},
    });
    geoSource = source;
    expect((await currentFixInBackground())!.lat, 50.06);
    expect(calls.map((MethodCall c) => c.method).last, 'lastKnown');
  });

  test('refused: nothing is read, nobody is asked twice', () async {
    final List<MethodCall> calls = platform(<String, Object?>{
      'serviceEnabled': true,
      'check': 'deniedForever',
      'lastKnown': <String, Object?>{'lat': 1, 'lon': 1},
    });
    geoSource = source;
    expect(await currentFix(), isNull);
    expect(await lastKnownFix(), isNull);
    expect(calls.map((MethodCall c) => c.method), <String>[
      'serviceEnabled',
      'check',
      'check',
    ]);
  });

  test('the last known position needs the permission already given', () async {
    final List<MethodCall> calls = platform(<String, Object?>{
      'check': 'whileInUse',
      'lastKnown': <String, Object?>{
        'lat': 54.4,
        'lon': 18.6,
        'at': 1760000000000,
      },
    });
    geoSource = source;
    final GeoFix? fix = await lastKnownFix();
    expect(fix!.at, DateTime.fromMillisecondsSinceEpoch(1760000000000));
    expect(calls.map((MethodCall c) => c.method), <String>[
      'check',
      'lastKnown',
    ]);
  });

  test(
    'a platform without the bridge gives no position and no error',
    () async {
      // Nothing answers on this channel.
      geoSource = const ChannelGeoSource(
        channel: MethodChannel('zen/location-missing'),
      );
      expect(await currentFix(), isNull);
      expect(await currentFixInBackground(), isNull);
      expect(await lastKnownFix(), isNull);
    },
  );
}
