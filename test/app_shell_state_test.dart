import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';

void main() {
  test('routing entries count as a live mesh even with zero listed peers', () {
    const AppShellState state = AppShellState(
      health: ServiceHealth.active,
      peers: 0,
      routingEntries: 12,
    );

    expect(state.serviceRunning, isTrue);
    expect(state.isConnected, isTrue);
    expect(state.isConnecting, isFalse);
    expect(state.connectionLabel, 'Połączono');
  });

  test('active node with no peers and no routes stays connecting', () {
    const AppShellState state = AppShellState(
      health: ServiceHealth.active,
      peers: 0,
    );

    expect(state.isConnected, isFalse);
    expect(state.isConnecting, isTrue);
    expect(state.connectionLabel, 'Łączę...');
  });

  test('stopped and failed nodes are offline, not connecting', () {
    const AppShellState stopped = AppShellState(health: ServiceHealth.stopped);
    const AppShellState failed = AppShellState(
      health: ServiceHealth.failed,
      errorMessage: 'bridge down',
    );

    expect(stopped.isConnecting, isFalse);
    expect(stopped.connectionLabel, 'Brak sieci');
    expect(failed.isConnecting, isFalse);
    expect(failed.connectionLabel, 'Brak sieci');
  });

  test('listed peers mark the mesh connected', () {
    const AppShellState state = AppShellState(
      health: ServiceHealth.syncing,
      peers: 2,
    );

    expect(state.isConnected, isTrue);
    expect(state.isConnecting, isFalse);
    expect(state.connectionLabel, 'Połączono');
  });
}
