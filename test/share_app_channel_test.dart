import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/update/share_app_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('zen/share_app-test');

  void answer(Future<Object?>? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  }

  test('the installed app goes to the share sheet with no path', () async {
    final List<MethodCall> calls = <MethodCall>[];
    answer((MethodCall call) async {
      calls.add(call);
      return <String, Object>{
        'ok': true,
        'baseOnly': false,
        'name': 'Zen-1.9.0.apk',
      };
    });

    final ApkShareResult result = await const ShareAppChannel(
      channel: channel,
    ).shareApk();

    expect(calls.single.method, 'shareApk');
    expect(calls.single.arguments, <String, Object>{});
    expect(result.opened, isTrue);
    expect(result.baseOnly, isFalse);
    expect(result.fileName, 'Zen-1.9.0.apk');
  });

  test('a chosen file is sent under its own name', () async {
    final List<MethodCall> calls = <MethodCall>[];
    answer((MethodCall call) async {
      calls.add(call);
      return <String, Object>{'ok': true, 'baseOnly': false, 'name': 'z.apk'};
    });

    await const ShareAppChannel(
      channel: channel,
    ).shareApk(path: '/cache/zen-2.0.0.apk', fileName: 'zen-2.0.0.apk');

    expect(calls.single.arguments, <String, Object>{
      'path': '/cache/zen-2.0.0.apk',
      'name': 'zen-2.0.0.apk',
    });
  });

  test('an app installed in parts says only the main file went', () async {
    answer(
      (MethodCall call) async => <String, Object>{
        'ok': true,
        'baseOnly': true,
        'name': 'Zen-1.9.0.apk',
      },
    );

    final ApkShareResult result = await const ShareAppChannel(
      channel: channel,
    ).shareApk();

    expect(result.status, ApkShareStatus.opened);
    expect(result.baseOnly, isTrue);
  });

  test('native errors become statuses the screen can explain', () async {
    answer((MethodCall call) async => <String, Object>{'error': 'no_file'});
    expect(
      (await const ShareAppChannel(channel: channel).shareApk()).status,
      ApkShareStatus.noFile,
    );

    answer((MethodCall call) async => <String, Object>{'error': 'failed:boom'});
    expect(
      (await const ShareAppChannel(channel: channel).shareApk()).status,
      ApkShareStatus.failed,
    );

    answer((MethodCall call) async {
      throw PlatformException(code: 'share');
    });
    expect(
      (await const ShareAppChannel(channel: channel).shareApk()).status,
      ApkShareStatus.failed,
    );
  });

  test('no native side means unsupported', () async {
    // Nothing answers on this channel.
    const ShareAppChannel missing = ShareAppChannel(
      channel: MethodChannel('zen/share_app-missing'),
    );
    expect((await missing.shareApk()).status, ApkShareStatus.unsupported);
  });

  test('replies are read defensively', () {
    expect(parseApkShareReply(null).status, ApkShareStatus.failed);
    expect(parseApkShareReply(<Object?, Object?>{'ok': true}).fileName, isNull);
    expect(
      parseApkShareReply(<Object?, Object?>{'ok': false}).status,
      ApkShareStatus.failed,
    );
  });
}
