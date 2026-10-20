import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
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
import 'package:zen/src/features/media/linux_video_player.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';

void main(List<String> args) {
  ZenInstance.init(args);
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      _installGlobalErrorHandlers();
      // The Go bridge's licenses next to the Dart packages' ones.
      registerGoLicenses();
      // Linux: video_player has no backend there; Zen's own on GStreamer.
      LinuxVideoPlayer.registerIfNeeded();
      // A second desktop instance cannot bind the runtime's peering port, so
      // it would run permanently offline. Hand the launch over to the instance
      // that is already running instead.
      // A test profile (--zen-profile) runs beside the others on purpose.
      if (ZenInstance.profile == null && !await ZenSingleInstance.acquire()) {
        logZenMessage('Another Zen instance is already running — exiting.');
        exit(0);
      }
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

  final ZenBootstrapper _bootstrapper = ZenBootstrapper(
    prepareForegroundLaunch: prepareAndroidBackgroundRuntimeForForegroundLaunch,
  );

  late Future<ZenBootstrapResult> _bootstrapFuture;

  @override
  void initState() {
    super.initState();
    _bootstrapFuture = _bootstrap();
  }

  @override
  Widget build(BuildContext context) {
    return DesktopWindowBridge(
      child: FutureBuilder<ZenBootstrapResult>(
        future: _bootstrapFuture,
        builder:
            (BuildContext context, AsyncSnapshot<ZenBootstrapResult> snapshot) {
              if (snapshot.hasData) {
                final ZenBootstrapResult result = snapshot.data!;
                return ProviderScope(
                  overrides: [...result.buildProviderOverrides()],
                  child: const ZenRewriteApp(),
                );
              }
              if (snapshot.hasError) {
                final _BootstrapFailurePresentation failure =
                    _presentBootstrapFailure(snapshot.error);
                return _BootstrapSurface(
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
    required this.title,
    required this.message,
    required this.showProgressIndicator,
    this.errorDetails,
    this.actionLabel,
    this.onPressed,
  });

  final String title;
  final String message;
  final bool showProgressIndicator;
  final String? errorDetails;
  final String? actionLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Zen',
      theme: ZenTheme.light(),
      darkTheme: ZenTheme.dark(),
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
                    // The logo's own white lettering (graphite on the light
                    // theme, where white would vanish).
                    Builder(
                      builder: (BuildContext context) {
                        final Color ink =
                            Theme.of(context).brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black;
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
                          borderRadius: BorderRadius.circular(20),
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
