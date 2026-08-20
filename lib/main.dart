import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:media_kit/media_kit.dart';

import 'state/digger.dart';
import 'state/downloads.dart';
import 'state/player.dart';
import 'state/session.dart';
import 'ui/home_page.dart';
import 'ui/login_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  MediaKit.ensureInitialized();
  runApp(const BeatPortDiggerApp());
}

class BeatPortDiggerApp extends StatelessWidget {
  const BeatPortDiggerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => Session()..restore()),

        ChangeNotifierProxyProvider<Session, DownloadQueue>(
          create: (_) => DownloadQueue()..restore(),
          update: (_, session, queue) =>
              (queue ?? DownloadQueue())..bind(session.catalog),
        ),
        ChangeNotifierProxyProvider<Session, PreviewPlayer>(
          create: (_) => PreviewPlayer(),
          update: (_, session, player) =>
              (player ?? PreviewPlayer())..bind(session.catalog),
        ),

        // Watches both so an automatic dig can start as soon as the session
        // is signed in and the genre list has arrived.
        ChangeNotifierProxyProvider2<Session, DownloadQueue, DiggerRunner>(
          create: (_) => DiggerRunner()..load(),
          update: (_, session, queue, runner) =>
              (runner ?? DiggerRunner())..attach(session, queue),
        ),
      ],
      child: MaterialApp(
        title: 'BeatPort Digger',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: const ExitGuard(child: _Root()),
      ),
    );
  }

  ThemeData _theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF01FF95),
      brightness: brightness,
    ),
  );
}

/// Coordinates window close with the native runner.
///
/// The runner hides the window on close and asks here first; this flushes
/// the download queue and history, stops the transfer isolates and tears
/// down the native player, then tells the runner to destroy the window for
/// real. A hard deadline guarantees the process dies even if a flush wedges,
/// because the alternative is the unkillable background process the app used
/// to leave behind.
class ExitGuard extends StatefulWidget {
  const ExitGuard({required this.child, super.key});

  final Widget child;

  @override
  State<ExitGuard> createState() => _ExitGuardState();
}

class _ExitGuardState extends State<ExitGuard> {
  static const MethodChannel _channel = MethodChannel('beatport/window');
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'closeRequested') unawaited(_shutdown());
      return null;
    });
  }

  Future<void> _shutdown() async {
    if (_closing) return;
    _closing = true;

    Timer(const Duration(seconds: 20), () => exit(0));

    final queue = context.read<DownloadQueue>();
    final player = context.read<PreviewPlayer>();
    try {
      await Future.wait([
        queue.prepareForExit(),
        player.shutdown(),
      ]).timeout(const Duration(seconds: 15));
    } on Object {
      // Best effort: the deadline above still ends the process.
    }
    try {
      await _channel.invokeMethod('destroy');
    } on Object {
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final status = context.watch<Session>().status;

    return switch (status) {
      SessionStatus.restoring => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      SessionStatus.signedOut => const LoginPage(),
      SessionStatus.signedIn => const HomePage(),
    };
  }
}
