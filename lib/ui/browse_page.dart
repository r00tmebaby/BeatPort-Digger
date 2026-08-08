library;

import 'package:flutter/material.dart';

import 'harmonic_page.dart';
import 'link_tab.dart';
import 'search_tab.dart';

class BrowsePage extends StatelessWidget {
  const BrowsePage({super.key, required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    // Same reasoning as the top-level nav: the tabs stay built to keep their
    // results and scroll position, so the ones out of sight get their tickers
    // switched off rather than animating unseen.
    return IndexedStack(
      index: index,
      children: [
        TickerMode(enabled: index == 0, child: const SearchTab()),
        TickerMode(enabled: index == 1, child: const HarmonicPage()),
        TickerMode(enabled: index == 2, child: const LinkTab()),
      ],
    );
  }
}
