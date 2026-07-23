/// Navigation shell.
///
/// A rail on wide windows and a bottom bar on narrow ones, so the same build
/// serves desktop and phone.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/session.dart';
import 'browse_page.dart';
import 'downloads_page.dart';
import 'settings_page.dart';
import 'widgets/now_playing.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  static const _destinations = [
    (icon: Icons.search, label: 'Browse'),
    (icon: Icons.download, label: 'Downloads'),
    (icon: Icons.settings_outlined, label: 'Settings'),
  ];

  /// IndexedStack keeps every page alive, so search results, filters and scroll
  /// position survive a trip to Downloads and back.
  Widget _page() => IndexedStack(
    index: _index,
    children: const [BrowsePage(), DownloadsPage(), SettingsPage()],
  );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;

    return Scaffold(
      appBar: AppBar(
        title: Text(_destinations[_index].label),
        actions: const [_AccountMenu()],
      ),
      // The transport sits above the nav bar so it stays put while pages change.
      bottomSheet: const NowPlayingBar(),
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (value) =>
                      setState(() => _index = value),
                  destinations: [
                    for (final destination in _destinations)
                      NavigationRailDestination(
                        icon: Icon(destination.icon),
                        label: Text(destination.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _page()),
              ],
            )
          : _page(),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (value) => setState(() => _index = value),
              destinations: [
                for (final destination in _destinations)
                  NavigationDestination(
                    icon: Icon(destination.icon),
                    label: destination.label,
                  ),
              ],
            ),
    );
  }
}

class _AccountMenu extends StatelessWidget {
  const _AccountMenu();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final token = session.token;
    final expiry = token?.expiresOn;

    return PopupMenuButton<String>(
      icon: const Icon(Icons.account_circle_outlined),
      tooltip: 'Account',
      onSelected: (value) async {
        if (value == 'logout') await context.read<Session>().logOut();
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Signed in'),
              if (expiry != null)
                Text(
                  'Token expires ${expiry.toLocal().toString().split('.').first}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              Text(
                'Renews automatically',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'logout',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout),
            title: Text('Sign out'),
          ),
        ),
      ],
    );
  }
}
