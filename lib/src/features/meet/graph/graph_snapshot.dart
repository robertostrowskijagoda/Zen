import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/meet/graph/graph_insights.dart';
import 'package:zen/src/features/meet/graph/graph_model.dart';
import 'package:zen/src/features/meet/graph/graph_painter.dart';
import 'package:zen/src/features/security/exported_files.dart';

// "Zrzut grafu bez danych osobowych": a picture of the graph with initials
// and the colours of circles — no names, no addresses, nothing else.

/// Side of the picture, in pixels.
const double kGraphSnapshotSize = 1080;

/// Friends of friends get initials only while there are no more of them
/// than this (more would be a blur of letters).
const int kSnapshotFarInitials = 300;

/// What one person looks like on the picture: where, how big, in which
/// colour and with which letters. Nothing that names them.
typedef SnapshotDot = ({Offset at, double radius, Color color, String letters});

/// The dots of the picture of [scene], fitted into a square of [size]:
/// friends with their initials, friends of friends (and further) with
/// theirs only when few, each in the colour of its circle ([clusters]).
List<SnapshotDot> snapshotDots(
  GraphScene scene,
  Map<String, int> clusters,
  ZenColors zen, {
  double size = kGraphSnapshotSize,
}) {
  final List<GraphNode> nodes = scene.layout.nodes;
  final Offset c = scene.layout.center;
  double reach = 1;
  for (int i = 0; i < nodes.length; i++) {
    reach = max(reach, (scene.layout.at(i) - c).distance);
  }
  final double k = (size / 2 - 60) / reach;
  final Offset mid = Offset(size / 2, size / 2);
  final int far = nodes.where((GraphNode n) => !n.isFriend).length;
  return <SnapshotDot>[
    for (int i = 0; i < nodes.length; i++)
      () {
        final GraphNode n = nodes[i];
        final int cluster = clusters[n.address] ?? -1;
        return (
          at: mid + (scene.layout.at(i) - c) * k,
          radius: n.isFriend ? 22.0 : 12.0,
          color: cluster >= 0
              ? zenTone(zen, cluster % 6)
              : (n.isFriend ? zen.accent : zen.textMuted),
          letters: n.isFriend || far <= kSnapshotFarInitials
              ? initialsOf(n.name)
              : '',
        );
      }(),
  ];
}

/// Paints the picture of [scene] (see [snapshotDots]) as PNG bytes; null
/// when the image could not be made.
Future<Uint8List?> graphSnapshotPng(
  GraphScene scene,
  Map<String, int> clusters,
  ZenColors zen, {
  double size = kGraphSnapshotSize,
}) async {
  final List<SnapshotDot> dots = snapshotDots(scene, clusters, zen, size: size);
  final Offset mid = Offset(size / 2, size / 2);
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(Offset.zero & Size(size, size), Paint()..color = zen.surface);
  Offset at(int i) => i < 0 ? mid : dots[i].at;
  final Paint line = Paint()
    ..color = zen.outline.withValues(alpha: 0.35)
    ..strokeWidth = 1.6;
  for (int e = 0; e < scene.edgeCount; e++) {
    canvas.drawLine(at(scene.edgeFrom[e]), at(scene.edgeTo[e]), line);
  }
  for (int i = 0; i + 1 < scene.links.length; i += 2) {
    canvas.drawLine(at(scene.links[i]), at(scene.links[i + 1]), line);
  }
  void letters(String text, Offset center, Color color, double px) {
    if (text.isEmpty) {
      return;
    }
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: px,
          fontFamily: ZenText.sansFamily,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
    tp.dispose();
  }

  final Paint fill = Paint();
  for (final SnapshotDot d in dots) {
    canvas.drawCircle(d.at, d.radius, fill..color = d.color);
    letters(d.letters, d.at, zen.surface, d.radius * 0.8);
  }
  canvas.drawCircle(mid, 34, fill..color = zen.accent);
  letters(t('Ty'), mid, zen.onAccent, 24);
  final ui.Picture picture = recorder.endRecording();
  try {
    final ui.Image image = await picture.toImage(size.round(), size.round());
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    return data?.buffer.asUint8List();
  } on Object {
    return null;
  } finally {
    picture.dispose();
  }
}

/// Where a picture of the graph is saved (replaced in tests).
abstract interface class GraphImageSaver {
  /// Saves [bytes] as [name]: the system dialog on a computer, the app's
  /// `Zen` folder on a phone. The path, or null when cancelled.
  Future<String?> save(String name, Uint8List bytes);
}

/// The real [GraphImageSaver].
final class PlatformGraphImageSaver implements GraphImageSaver {
  const PlatformGraphImageSaver();

  @override
  Future<String?> save(String name, Uint8List bytes) async {
    String? target;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      target = await FilePicker.platform.saveFile(
        dialogTitle: t('Zapisz obrazek grafu'),
        fileName: name,
      );
    } else {
      final Directory? dir = Platform.isAndroid
          ? await getExternalStorageDirectory()
          : await getApplicationDocumentsDirectory();
      if (dir != null) {
        final Directory zen = Directory('${dir.path}/Zen');
        await zen.create(recursive: true);
        target = '${zen.path}/$name';
      }
    }
    if (target == null || target.isEmpty) {
      return null;
    }
    await File(target).writeAsBytes(bytes, flush: true);
    // A plain file on purpose: the panic password deletes it too.
    await rememberExportedFile(target);
    return target;
  }
}

final Provider<GraphImageSaver> graphImageSaverProvider =
    Provider<GraphImageSaver>((Ref ref) => const PlatformGraphImageSaver());
