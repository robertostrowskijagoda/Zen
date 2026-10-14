const String kRelayLoopbackHost = '127.0.0.1';

String buildUdpRelayCandidateSdp({
  required String host,
  required int port,
  String foundation = 'relay',
  int component = 1,
  int priority = 2130706431,
}) {
  return 'candidate:$foundation $component udp $priority $host $port typ host generation 0';
}
