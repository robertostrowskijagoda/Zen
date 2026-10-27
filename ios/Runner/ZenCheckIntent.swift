import AppIntents
import Foundation

/// "Sprawdź wiadomości Zen": a Shortcuts action that runs one background
/// check without opening Zen (ZenBackgroundBridge.check: the app's engine
/// when Zen is in memory, otherwise an engine without a screen running the
/// locked receiver). A Shortcuts automation ("Time of Day", "Run
/// Immediately") can run it every hour, which wakes Zen far more reliably
/// than iOS's own background refresh; iOS shows a short banner each time
/// an automation runs (docs/IOS_BACKGROUND.md).
@available(iOS 16.0, *)
struct ZenCheckMessagesIntent: AppIntent {
  static let title: LocalizedStringResource = "Sprawdź wiadomości Zen"
  static let description = IntentDescription(
    "Zen pyta skrzynki u znajomych o nowe wiadomości i pokazuje powiadomienia, bez otwierania aplikacji."
  )
  static let openAppWhenRun = false

  /// Within the time iOS gives an action that runs in the background.
  private static let seconds = 20

  @MainActor
  func perform() async throws -> some IntentResult {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      ZenBackgroundBridge.shared.checkFromShortcut(seconds: ZenCheckMessagesIntent.seconds) { _ in
        done.resume()
      }
    }
    return .result()
  }
}

/// Lists the action in Shortcuts as soon as Zen is installed, so an
/// automation can pick it without any setup in Zen.
@available(iOS 16.0, *)
struct ZenShortcuts: AppShortcutsProvider {
  @AppShortcutsBuilder
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ZenCheckMessagesIntent(),
      phrases: ["Sprawdź wiadomości w \(.applicationName)"])
  }
}
