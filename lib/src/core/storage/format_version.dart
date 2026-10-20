/// Every JSON document this app stores names its format in `v`, so a later
/// build can tell one format from another instead of guessing from the
/// fields. Readers ignore keys they do not know.
const String kFormatVersionKey = 'v';

/// The first (and so far only) format version.
const int kFirstFormatVersion = 1;

/// [json] with `v` set to [version] (an existing `v` in [json] wins).
Map<String, Object?> withFormatVersion(
  Map<String, Object?> json, {
  int version = kFirstFormatVersion,
}) => <String, Object?>{kFormatVersionKey: version, ...json};
