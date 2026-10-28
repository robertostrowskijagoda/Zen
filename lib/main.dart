import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/app/app_bootstrap.dart';
import 'package:zen/src/app/desktop_window_bridge.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/i18n/zen_language_preference.dart';
import 'package:zen/src/app/i18n/zen_locales.dart';
import 'package:zen/src/app/single_instance_guard.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/about/go_licenses.dart';
import 'package:zen/src/features/account/multi/account_switch.dart';
import 'package:zen/src/features/media/linux_video_player.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/opened_files.dart';
import 'package:zen/src/features/settings/app_settings.dart';

void main(List<String> args) {
  ZenInstance.init(args);
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      _installGlobalErrorHandlers();
      // Zen is portrait only (the manifests say so too; this covers the
      // rest, e.g. tablets that would rotate anyway).
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
      // NOTICE and the Go, native and font licenses next to the Dart
      // packages' ones.
      registerGoLicenses();
      // Linux: video_player has no backend there; Zen's own on GStreamer.
      LinuxVideoPlayer.registerIfNeeded();
      // A second desktop instance cannot bind the runtime's peering port, so
      // it would run permanently offline. Hand the launch over to the instance
      // that is already running instead.
      // A test profile (--zen-profile) runs beside the others on purpose.
      if (ZenInstance.profile == null &&
          !await ZenSingleInstance.acquire(
            // Windows: a file opened while Zen runs goes to the running one.
            open: Platform.isWindows ? zenOpenedFileArgument(args) : null,
          )) {
        logZenMessage('Another Zen instance is already running — exiting.');
        exit(0);
      }
      // Files opened in Zen from outside (a backup tapped in Files):
      // listening before anything else, so the one Zen starts with counts.
      ZenOpenedFiles.instance.start(args);
      // Before the first text: the person's language (or the system's).
      await loadZenLanguage();
      runApp(const _ZenBootstrapApp());
    },
    (Object error, StackTrace stackTrace) {
      logZenError('Uncaught asynchronous error', error, stackTrace);
    },
  );
}

void _installGlobalErrorHandlers() {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    logZenError(
      'Flutter framework error',
      details.exception,
      details.stack ?? StackTrace.current,
    );
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    logZenError('Platform dispatcher error', error, stackTrace);
    return true;
  };
}

final class _BootstrapFailurePresentation {
  const _BootstrapFailurePresentation({
    required this.message,
    required this.details,
  });

  final String message;
  final String details;
}

class _ZenBootstrapApp extends StatefulWidget {
  const _ZenBootstrapApp();

  @override
  State<_ZenBootstrapApp> createState() => _ZenBootstrapAppState();
}

class _ZenBootstrapAppState extends State<_ZenBootstrapApp> {
  static const Duration _bootstrapTimeout = Duration(seconds: 30);

  ZenBootstrapper _bootstrapper = ZenBootstrapper(
    prepareForegroundLaunch: prepareAndroidBackgroundRuntimeForForegroundLaunch,
  );

  late Future<ZenBootstrapResult> _bootstrapFuture;

  /// Bumped when another account opens: its app gets fresh providers.
  int _accountGeneration = 0;

  /// The result whose app is on screen now.
  ZenBootstrapResult? _shown;

  @override
  void initState() {
    super.initState();
    _bootstrapFuture = _bootstrap();
    ZenAccountHost.instance.addListener(_openAccount);
  }

  @override
  void dispose() {
    ZenAccountHost.instance.removeListener(_openAccount);
    super.dispose();
  }

  /// Another account was asked for (the account menu, the lock screen, a
  /// restored copy): the app starts again for it, in this process.
  ///
  /// The app of the account left goes at once: its providers with the
  /// splash that replaces it, its node runtime right after (nothing of it
  /// may start that account's node again beside the next one).
  void _openAccount() {
    final ZenAccountOpening? opening = ZenAccountHost.instance.take();
    if (opening == null) {
      return;
    }
    final ZenBootstrapResult? left = _shown;
    _shown = null;
    if (left != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        retireBootstrapResult(left);
      });
    }
    setState(() {
      _accountGeneration += 1;
      _bootstrapper = ZenBootstrapper(
        prepareForegroundLaunch:
            prepareAndroidBackgroundRuntimeForForegroundLaunch,
        opening: opening,
      );
      _bootstrapFuture = _bootstrap().whenComplete(
        ZenAccountHost.instance.settled,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return DesktopWindowBridge(
      child: FutureBuilder<ZenBootstrapResult>(
        future: _bootstrapFuture,
        builder:
            (BuildContext context, AsyncSnapshot<ZenBootstrapResult> snapshot) {
              final ZenBootstrapResult? result = settledBootstrapResult(
                snapshot,
              );
              if (result != null) {
                _shown = result;
                return ProviderScope(
                  key: ValueKey<int>(_accountGeneration),
                  overrides: [...result.buildProviderOverrides()],
                  child: const ZenRewriteApp(),
                );
              }
              if (snapshot.connectionState == ConnectionState.done &&
                  snapshot.hasError) {
                final _BootstrapFailurePresentation failure =
                    _presentBootstrapFailure(snapshot.error);
                return _BootstrapSurface(
                  settings: _bootstrapper.loadedSettings,
                  title: 'Zen',
                  message: failure.message,
                  errorDetails: failure.details,
                  actionLabel: t('Spróbuj ponownie'),
                  showProgressIndicator: false,
                  onPressed: () {
                    setState(() {
                      _bootstrapFuture = _bootstrap();
                    });
                  },
                );
              }
              return _BootstrapSurface(
                settings: _bootstrapper.loadedSettings,
                title: 'Zen',
                message: t('Ładowanie danych i uruchamianie sieci…'),
                showProgressIndicator: true,
              );
            },
      ),
    );
  }

  Future<ZenBootstrapResult> _bootstrap() async {
    try {
      return await _bootstrapper.bootstrap().timeout(_bootstrapTimeout);
    } on TimeoutException catch (error, stackTrace) {
      logZenError('App bootstrap timed out', error, stackTrace);
      throw ZenBootstrapException(
        userMessage: t(
          'Uruchamianie aplikacji trwa zbyt długo. Sprawdź uprawnienia '
          'i spróbuj ponownie.',
        ),
        details:
            'Bootstrap timeout after ${_bootstrapTimeout.inSeconds} seconds.',
      );
    } on ZenBootstrapException catch (error, stackTrace) {
      logZenError('App bootstrap failed', error, stackTrace);
      rethrow;
    } catch (error, stackTrace) {
      logZenError('App bootstrap failed', error, stackTrace);
      throw ZenBootstrapException(
        userMessage: t('Start aplikacji nie powiódł się.'),
        details: '$error',
      );
    }
  }

  _BootstrapFailurePresentation _presentBootstrapFailure(Object? error) {
    if (error is ZenBootstrapException) {
      return _BootstrapFailurePresentation(
        message: error.userMessage,
        details: error.details,
      );
    }
    return _BootstrapFailurePresentation(
      message: t('Start aplikacji nie powiódł się.'),
      details: error?.toString() ?? t('Nieznany błąd uruchamiania.'),
    );
  }
}

class _BootstrapSurface extends StatelessWidget {
  const _BootstrapSurface({
    required this.settings,
    required this.title,
    required this.message,
    required this.showProgressIndicator,
    this.errorDetails,
    this.actionLabel,
    this.onPressed,
  });

  /// The person's settings once read (see [ZenBootstrapper.loadedSettings]):
  /// the splash is drawn in the theme they chose.
  final ValueListenable<AppSettings?> settings;
  final String title;
  final String message;
  final bool showProgressIndicator;
  final String? errorDetails;
  final String? actionLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppSettings?>(
      valueListenable: settings,
      builder: (BuildContext context, AppSettings? chosen, Widget? _) {
        if (chosen == null && showProgressIndicator && Platform.isAndroid) {
          // The chosen theme is not known yet: stay as black as the system
          // launch screen instead of flashing a theme that is not theirs.
          return const ColoredBox(color: Color(0xFF000000));
        }
        return _buildThemed(chosen ?? const AppSettings());
      },
    );
  }

  Widget _buildThemed(AppSettings chosen) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Zen',
      theme: ZenTheme.light(chosen.accentTheme, chosen.palette),
      darkTheme: ZenTheme.dark(chosen.accentTheme, chosen.palette),
      themeMode: chosen.themeMode.materialThemeMode,
      // The language loadZenLanguage() picked before runApp.
      locale: zenLocaleOf(ZenI18n.code),
      supportedLocales: zenSupportedLocales,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // A Builder: the colours come from the theme of this MaterialApp
      // (ZenColors.of falls back safely when the extension is missing).
      home: Builder(builder: _buildSplash),
    );
  }

  Widget _buildSplash(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool failed = !showProgressIndicator;
    return Scaffold(
      backgroundColor: zen.background,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.35),
            radius: 0.9,
            colors: <Color>[
              (failed ? zen.danger : zen.accent).withValues(alpha: 0.20),
              zen.accentSecondary.withValues(alpha: 0.06),
              zen.background.withValues(alpha: 0),
            ],
            stops: const <double>[0, 0.45, 1],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // The logo lettering takes the theme's own ink, so it
                    // reads on every background.
                    Builder(
                      builder: (BuildContext context) {
                        final Color ink = zen.textPrimary;
                        final Widget asText = Text(
                          title,
                          textAlign: TextAlign.center,
                          style: zen.display(
                            color: ink,
                            size: 72,
                            weight: FontWeight.w700,
                          ),
                        );
                        if (title != 'Zen') {
                          return asText;
                        }
                        return Image.asset(
                          'assets/branding/wordmark.png',
                          height: 64,
                          color: ink,
                          colorBlendMode: BlendMode.srcIn,
                          filterQuality: FilterQuality.medium,
                          semanticLabel: 'Zen',
                          errorBuilder:
                              (
                                BuildContext context,
                                Object error,
                                StackTrace? stack,
                              ) => asText,
                        );
                      },
                    ),
                    const SizedBox(height: 28),
                    if (showProgressIndicator) ...<Widget>[
                      SizedBox.square(
                        dimension: 30,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          strokeCap: StrokeCap.round,
                          color: zen.accent,
                          backgroundColor: zen.accent.withValues(alpha: 0.14),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 14.5,
                          height: 1.45,
                        ),
                      ),
                    ] else
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                        decoration: BoxDecoration(
                          color: zen.danger.withValues(alpha: 0.09),
                          borderRadius: context.zenRadius(20),
                          border: Border.all(
                            color: zen.danger.withValues(alpha: 0.28),
                          ),
                        ),
                        child: Column(
                          children: <Widget>[
                            Icon(
                              Icons.error_outline_rounded,
                              size: 32,
                              color: zen.danger,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              message,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: zen.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                height: 1.4,
                              ),
                            ),
                            if (errorDetails != null) ...<Widget>[
                              const SizedBox(height: 8),
                              Text(
                                errorDetails!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: zen.textSecondary,
                                  fontSize: 13,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    if (actionLabel != null && onPressed != null) ...<Widget>[
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: onPressed,
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(actionLabel!),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
