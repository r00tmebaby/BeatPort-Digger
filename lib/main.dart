import 'package:flutter/material.dart';
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
        home: const _Root(),
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
