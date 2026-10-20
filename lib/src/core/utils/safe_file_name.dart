/// A file name from someone else (a peer's attachment) made safe to use as
/// one path segment: only the last segment of any path in it, no control
/// or reserved characters, no leading dots, no dots, spaces or invisible
/// characters at the end (Windows drops those, so `evil.exe.` is `evil.exe`
/// there), at most [maxLength] characters.
/// Null when nothing usable is left — callers fall back to their own name.
String? safeFileName(String? raw, {int maxLength = 120}) {
  if (raw == null) {
    return null;
  }
  // Last segment of a Unix or Windows path ("../../x", "C:\\a\\b").
  String name = raw.split(RegExp(r'[/\\]')).last;
  name = trimNameEnd(
    name
        .replaceAll(RegExp(r'[\x00-\x1F\x7F<>:"|?*]'), '')
        .replaceAll(RegExp(r'^[.\s]+'), ''),
  );
  if (name.length > maxLength) {
    final int dot = name.lastIndexOf('.');
    final String ext = dot > 0 && name.length - dot <= 10
        ? name.substring(dot)
        : '';
    // The cut may leave a dot or space at the end of the stem or the name.
    name = trimNameEnd(name.substring(0, maxLength - ext.length)) + ext;
  }
  return name.isEmpty ? null : name;
}

/// [name] without what the end of a file name does not count for: dots and
/// whitespace, which Windows silently drops (`skrypt.ps1 ` and `faktura.exe.`
/// open as `.ps1` and `.exe`), and invisible characters such as zero-width
/// spaces and direction marks. Linear in the length of [name].
String trimNameEnd(String name) {
  int end = name.length;
  while (end > 0 && _ignoredAtNameEnd(name.codeUnitAt(end - 1))) {
    end--;
  }
  return end == name.length ? name : name.substring(0, end);
}

bool _ignoredAtNameEnd(int unit) =>
    unit == 0x2E || // .
    unit <= 0x20 || // controls and space
    unit == 0x7F ||
    (unit >= 0x80 && unit <= 0x9F) ||
    unit == 0xA0 ||
    unit == 0xAD || // soft hyphen
    unit == 0x1680 ||
    (unit >= 0x2000 && unit <= 0x200F) || // spaces, zero-width, marks
    (unit >= 0x2028 && unit <= 0x202F) || // separators, direction overrides
    unit == 0x205F ||
    (unit >= 0x2060 && unit <= 0x2064) ||
    (unit >= 0x2066 && unit <= 0x2069) ||
    unit == 0x3000 ||
    unit == 0xFEFF;
