import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/core/logging/zen_log.dart';

const MethodChannel _system = MethodChannel('zen/system');

/// A map link anyone can open (no Google account needed).
String mapUrl(double lat, double lon) =>
    'https://www.openstreetmap.org/?mlat=${lat.toStringAsFixed(6)}'
    '&mlon=${lon.toStringAsFixed(6)}#map=17/${lat.toStringAsFixed(6)}/'
    '${lon.toStringAsFixed(6)}';

/// Opens the phone's dialer with [number] (the person presses call).
/// Returns `false` where that is not possible.
Future<bool> openDialer(String number) async {
  if (kIsWeb || !Platform.isAndroid) {
    return false;
  }
  try {
    return await _system.invokeMethod<bool>('dial', <String, Object>{
          'number': number,
        }) ??
        false;
  } on Object catch (error) {
    logZenWarning('Wybieranie numeru: $error');
    return false;
  }
}

/// Opens a map at [lat], [lon] (a map app on the phone, the browser on a
/// computer).
Future<bool> openMap(double lat, double lon, {String label = ''}) async {
  if (kIsWeb) {
    return false;
  }
  try {
    if (Platform.isAndroid) {
      return await _system.invokeMethod<bool>('openMap', <String, Object>{
            'lat': lat,
            'lon': lon,
            'label': label,
          }) ??
          false;
    }
    final String url = mapUrl(lat, lon);
    if (Platform.isWindows) {
      await Process.run('explorer', <String>[url]);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[url]);
    } else {
      await Process.run('xdg-open', <String>[url]);
    }
    return true;
  } on Object catch (error) {
    logZenWarning('Otwieranie mapy: $error');
    return false;
  }
}

/// Opens an https page in the browser. Anything else (another scheme, a
/// link without a host) is refused. Returns `false` where it could not be
/// opened, so the caller can copy the link instead.
Future<bool> openWebLink(String url) async {
  final Uri? uri = Uri.tryParse(url.trim());
  if (kIsWeb || uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    return false;
  }
  final String link = uri.toString();
  try {
    if (Platform.isAndroid) {
      return await _system.invokeMethod<bool>('openUrl', <String, Object>{
            'url': link,
          }) ??
          false;
    }
    if (Platform.isWindows) {
      await Process.run('explorer', <String>[link]);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[link]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', <String>[link]);
    } else {
      return false;
    }
    return true;
  } on Object catch (error) {
    logZenWarning('Otwieranie strony: $error');
    return false;
  }
}

/// Android: the "open by default" page of Zen, where a person can let Zen
/// answer its invitation links (a Zen QR scanned with the camera then opens
/// straight in Zen). Returns `false` elsewhere.
Future<bool> openLinkHandlingSettings() async {
  if (kIsWeb || !Platform.isAndroid) {
    return false;
  }
  try {
    return await _system.invokeMethod<bool>('openLinkSettings') ?? false;
  } on Object catch (error) {
    logZenWarning('Ustawienia linków: $error');
    return false;
  }
}
