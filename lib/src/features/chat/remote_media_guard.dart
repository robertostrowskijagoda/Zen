import 'dart:io';

/// Hosts the app itself may download a GIF from: only the sender's own device
/// fetches one, after picking it in the GIF picker, and only from the catalog
/// host (https only, no IP literals, redirects re-checked). Nothing a peer
/// sends is ever fetched.
const Set<String> kAllowedRemoteMediaHostSuffixes = <String>{'klipy.com'};

bool isAllowedRemoteMediaUrl(String? raw) {
  final String trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) {
    return false;
  }
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.isAbsolute || uri.scheme != 'https') {
    return false;
  }
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) {
    return false;
  }
  // IP literals would let a peer aim the fetch at any machine directly,
  // including hosts on the local network.
  if (InternetAddress.tryParse(host) != null) {
    return false;
  }
  for (final String suffix in kAllowedRemoteMediaHostSuffixes) {
    if (host == suffix || host.endsWith('.$suffix')) {
      return true;
    }
  }
  return false;
}
