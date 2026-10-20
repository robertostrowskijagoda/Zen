/// "Formats from version 1" (STAN §7): every JSON document this app stores
/// names its format in `v`, so a later build can tell an old file from a
/// new one instead of guessing from the fields.
///
/// Files written before the field existed have no `v`: they are version 1.
/// Readers keep ignoring keys they do not know, so adding `v` changes
/// nothing for an older build reading a newer file.
const String kFormatVersionKey = 'v';

/// The first (and so far only) version of the formats that got `v` late.
const int kFirstFormatVersion = 1;

/// [json] with `v` set to [version] (an existing `v` in [json] wins).
Map<String, Object?> withFormatVersion(
  Map<String, Object?> json, {
  int version = kFirstFormatVersion,
}) => <String, Object?>{kFormatVersionKey: version, ...json};

/// The format version of a stored document: its `v`, or 1 when it has none
/// (written before the field existed) or the value is not a positive int.
int storedFormatVersion(Map<dynamic, dynamic> json) {
  final Object? v = json[kFormatVersionKey];
  return v is int && v >= kFirstFormatVersion ? v : kFirstFormatVersion;
}
