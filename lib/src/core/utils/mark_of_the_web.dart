import 'dart:io';

import 'package:flutter/foundation.dart';

/// What Windows keeps in the `Zone.Identifier` stream of a file that came
/// from outside: zone 3 is "the internet".
const String kZoneTransferContent = '[ZoneTransfer]\r\nZoneId=3\r\n';

/// The name of the NTFS alternate data stream that holds the zone of the
/// file at [path].
String zoneIdentifierPath(String path) => '$path:Zone.Identifier';

/// Marks the file at [path] as coming from outside this computer (the
/// "Mark of the Web"): Explorer, SmartScreen and antivirus then treat a
/// program in it with the suspicion it deserves. Call it for every file
/// received from someone else that is saved where the person can open it.
///
/// Windows only (elsewhere it does nothing), and best effort: a file system
/// without alternate data streams (FAT, a network share) or a file that is
/// gone simply stays unmarked, never an error. [windows] is for tests.
Future<void> markFileFromInternet(String path, {bool? windows}) async {
  final bool onWindows = windows ?? (!kIsWeb && Platform.isWindows);
  if (!onWindows || path.isEmpty) {
    return;
  }
  try {
    await File(
      zoneIdentifierPath(path),
    ).writeAsString(kZoneTransferContent, flush: true);
  } on Object {
    // Best effort: the file is saved either way.
  }
}
