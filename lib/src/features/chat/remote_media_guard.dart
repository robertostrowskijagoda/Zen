import 'dart:io';

/// Hosts that may serve remote media rendered by the app. Incoming messages
/// may carry a `gifUrl`; restricting it to this allow-list (https only, no IP
/// literals) stops peers from forcing the client to fetch arbitrary URLs
/// (tracking pixels, internal-network probes, public-IP leaks).
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
