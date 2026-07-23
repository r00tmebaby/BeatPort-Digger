/// Ways of finding tracks: search, harmonic matching and pasting a link.
///
/// All three are the same task - getting tracks into the list - so they share
/// one destination. The selector lives in the app header; this page just shows
/// the chosen one, keeping every tab alive so its state survives a switch.
library;

import 'package:flutter/material.dart';

import 'harmonic_page.dart';
import 'link_tab.dart';
import 'search_tab.dart';

class BrowsePage extends StatelessWidget {
  const BrowsePage({super.key, required this.index});

  /// Which finder to show: 0 search, 1 harmonic, 2 link.
  final int index;

  @override
  Widget build(BuildContext context) {
    // IndexedStack rather than TabBarView: it keeps the tabs it is not showing
    // alive, so search results are not thrown away when the finder changes.
    return IndexedStack(
      index: index,
      children: const [SearchTab(), HarmonicPage(), LinkTab()],
    );
  }
}
