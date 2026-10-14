/// A file name from someone else (a peer's attachment) made safe to use as
/// one path segment: only the last segment of any path in it, no control
/// or reserved characters, no leading dots, at most [maxLength] characters.
/// Null when nothing usable is left — callers fall back to their own name.
String? safeFileName(String? raw, {int maxLength = 120}) {
  if (raw == null) {
    return null;
  }
  // Last segment of a Unix or Windows path ("../../x", "C:\\a\\b").
  String name = raw.split(RegExp(r'[/\\]')).last;
  name = name
      .replaceAll(RegExp(r'[\x00-\x1F\x7F<>:"|?*]'), '')
      .replaceAll(RegExp(r'^[.\s]+'), '')
      .trim();
  if (name.length > maxLength) {
    final int dot = name.lastIndexOf('.');
    final String ext = dot > 0 && name.length - dot <= 10
        ? name.substring(dot)
        : '';
    name = name.substring(0, maxLength - ext.length) + ext;
  }
  return name.isEmpty ? null : name;
}
