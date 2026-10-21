import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_code_dart_scan/qr_code_dart_scan.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

final Provider<PeerQrScanner> peerQrScannerProvider = Provider<PeerQrScanner>((
  Ref ref,
) {
  return const PlatformPeerQrScanner();
});

abstract class PeerQrScanner {
  bool get isSupported;

  Future<String?> scan(BuildContext context);
}

final class PlatformPeerQrScanner implements PeerQrScanner {
  const PlatformPeerQrScanner();

  @override
  bool get isSupported => Platform.isAndroid || Platform.isIOS;

  @override
  Future<String?> scan(BuildContext context) {
    if (!isSupported) {
      return Future<String?>.value();
    }
    return Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const _PeerQrScannerPage()),
    );
  }
}

class _PeerQrScannerPage extends StatefulWidget {
  const _PeerQrScannerPage();

  @override
  State<_PeerQrScannerPage> createState() => _PeerQrScannerPageState();
}

class _PeerQrScannerPageState extends State<_PeerQrScannerPage> {
  bool _completed = false;

  void _handleCapture(Result result) {
    if (_completed) {
      return;
    }
    final String value = result.text.trim();
    if (value.isEmpty) {
      return;
    }
    _completed = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('Skanuj kod QR'))),
      body: QRCodeDartScanView(
        typeScan: TypeScan.live,
        formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
        croppingStrategy: CroppingStrategy.cropCenterSquare(
          squareSizeFactor: 0.7,
        ),
        onCapture: _handleCapture,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Colors.black.withAlpha(170),
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withAlpha(170),
                    ],
                    stops: const <double>[0, 0.18, 0.82, 1],
                  ),
                ),
              ),
            ),
            Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  borderRadius: context.zenRadius(28),
                  // The viewfinder in the accent of the theme.
                  border: Border.all(
                    color: ZenColors.of(context).accent,
                    width: 3,
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(180),
                      borderRadius: context.zenRadius(20),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      child: Text(
                        t('Skieruj aparat na kod QR znajomego.'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
