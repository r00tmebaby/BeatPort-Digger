/// Ways of finding tracks, grouped as tabs.
///
/// Search, harmonic matching and pasting a link are all the same task - getting
/// tracks into the list - so they belong together rather than as separate
/// top-level destinations.
library;

import 'package:flutter/material.dart';

import 'harmonic_page.dart';
import 'link_tab.dart';
import 'search_tab.dart';

class BrowsePage extends StatefulWidget {
  const BrowsePage({super.key});

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;

  static const _tabs = [
    (icon: Icons.search, label: 'Search'),
    (icon: Icons.album, label: 'Harmonic'),
    (icon: Icons.link, label: 'Link'),
  ];

  @override
  void initState() {
    super.initState();
    _controller = TabController(length: _tabs.length, vsync: this)
      ..addListener(() {
        if (!_controller.indexIsChanging) setState(() {});
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _controller,
          tabs: [
            for (final tab in _tabs)
              Tab(icon: Icon(tab.icon, size: 20), text: tab.label),
          ],
        ),
        // IndexedStack rather than TabBarView: TabBarView disposes the tabs it
        // is not showing, which would throw away search results every time the
        // tab changed.
        Expanded(
          child: IndexedStack(
            index: _controller.index,
            children: const [SearchTab(), HarmonicPage(), LinkTab()],
          ),
        ),
      ],
    );
  }
}
