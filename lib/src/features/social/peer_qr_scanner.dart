import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_code_dart_scan/qr_code_dart_scan.dart';

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
      appBar: AppBar(title: const Text('Skanuj kod QR')),
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
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: Colors.white, width: 3),
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
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      child: Text(
                        'Skieruj aparat na kod QR znajomego.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, height: 1.4),
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
