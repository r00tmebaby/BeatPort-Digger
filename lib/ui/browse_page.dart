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
    return IndexedStack(
      index: index,
      children: const [SearchTab(), HarmonicPage(), LinkTab()],
    );
  }
}
