import 'package:flutter/foundation.dart';

/// The key of a message's picture size in what it carries beside the
/// basics: its stored extras, the copies for the account's other devices
/// and a signal's chat extras (`{w, h}`).
const String kMediaSizeKey = 'dim';

/// The keys of a picture's width and height in a message, a group message,
/// a file's placeholder and its chunks on the wire. Plain numbers beside
/// the other file fields: the mailboxes pass on only those for a file
/// (`relay_engine_blobs.dart`).
const String kMediaWidthKey = 'mediaWidth';
const String kMediaHeightKey = 'mediaHeight';

/// The largest side, in pixels, a picture's size is taken with; a larger
/// one is no size at all (the bubble then waits for the picture, as for a
/// message from a Zen before 1.17.5).
const int kMaxChatMediaSide = 1 << 16;

/// The most one side of a picture's box is longer than the other. The
/// sender says the size: a picture of 1 x 60000 pixels would otherwise make
/// a box nobody can see.
const double kMaxChatMediaAspect = 8;

/// The size of a message's picture (a photo, a GIF) in pixels, as its
/// sender read it when the file was attached, upright. The bubble takes its
/// final size from it before the file is there or decoded, so the
/// conversation does not move when the picture comes in.
///
/// It comes from the sender and is not checked against the picture: it
/// only gives a box (bounded by [boxWithin]) that the picture is fitted in.
@immutable
final class ChatMediaSize {
  const ChatMediaSize._(this.width, this.height);

  final int width;
  final int height;

  /// [width] x [height] when both are whole numbers from 1 to
  /// [kMaxChatMediaSide]; null otherwise.
  static ChatMediaSize? of(Object? width, Object? height) {
    if (width is! int ||
        height is! int ||
        width < 1 ||
        height < 1 ||
        width > kMaxChatMediaSide ||
        height > kMaxChatMediaSide) {
      return null;
    }
    return ChatMediaSize._(width, height);
  }

  /// The size [json] (`{w, h}`) holds, or null.
  static ChatMediaSize? fromJson(Object? json) =>
      json is Map ? of(json['w'], json['h']) : null;

  Map<String, dynamic> toJson() => <String, dynamic>{'w': width, 'h': height};

  /// The fields a message carries it in ([kMediaWidthKey],
  /// [kMediaHeightKey]).
  Map<String, dynamic> toPayload() => <String, dynamic>{
    kMediaWidthKey: width,
    kMediaHeightKey: height,
  };

  /// Width over height, within [kMaxChatMediaAspect] either way.
  double get aspectRatio =>
      (width / height).clamp(1 / kMaxChatMediaAspect, kMaxChatMediaAspect);

  /// The box, in logical pixels, the picture is shown in: in its proportions
  /// ([aspectRatio]), at most [maxWidth] wide and [maxHeight] tall. A GIF
  /// keeps its own size when it fits (one pixel of it is one logical pixel,
  /// as it is shown without a size); with [enlarge] (a photo) the box takes
  /// the whole [maxWidth] unless that makes it taller than [maxHeight]. A
  /// bound that is not a positive finite number is the picture's own size.
  ({double width, double height}) boxWithin({
    required double maxWidth,
    required double maxHeight,
    bool enlarge = false,
  }) {
    final double ratio = aspectRatio;
    final double widest = maxWidth.isFinite && maxWidth > 0
        ? maxWidth
        : width.toDouble();
    final double tallest = maxHeight.isFinite && maxHeight > 0
        ? maxHeight
        : height.toDouble();
    double boxWidth = enlarge || width > widest ? widest : width.toDouble();
    double boxHeight = boxWidth / ratio;
    if (boxHeight > tallest) {
      boxHeight = tallest;
      boxWidth = boxHeight * ratio;
    }
    return (width: boxWidth, height: boxHeight);
  }

  @override
  bool operator ==(Object other) =>
      other is ChatMediaSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}
