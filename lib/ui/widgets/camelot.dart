/// Colours for the Camelot wheel.
///
/// The wheel is conventionally coloured by hue, one step per position, so
/// neighbouring keys sit next to each other in colour as well as in pitch. Minor
/// (A) is the deeper shade and major (B) the lighter one, matching how mixing
/// software draws it.
library;

import 'package:flutter/material.dart';

/// Base hue per Camelot position, 1 through 12.
const List<Color> _wheel = [
  Color(0xFF3FD2E0), // 1
  Color(0xFF3FE0B4), // 2
  Color(0xFF52E063), // 3
  Color(0xFF93E03F), // 4
  Color(0xFFD6E03F), // 5
  Color(0xFFE0B23F), // 6
  Color(0xFFE08A3F), // 7
  Color(0xFFE0633F), // 8
  Color(0xFFE03F63), // 9
  Color(0xFFE03FB4), // 10
  Color(0xFFB43FE0), // 11
  Color(0xFF633FE0), // 12
];

/// Background for a Camelot code, or null when the code is unknown.
///
/// Shades are pulled apart in light and dark themes: the same fill that reads
/// as a tint on white is muddy on a dark surface.
Color? camelotColor(int? number, String? letter, Brightness brightness) {
  if (number == null || number < 1 || number > 12) return null;
  final base = _wheel[number - 1];
  final minor = (letter ?? '').toUpperCase() == 'A';
  final hsl = HSLColor.fromColor(base);

  if (brightness == Brightness.dark) {
    return hsl
        .withLightness(minor ? 0.34 : 0.44)
        .withSaturation(0.55)
        .toColor();
  }
  return hsl.withLightness(minor ? 0.70 : 0.82).toColor();
}

/// A readable foreground for [background].
Color camelotForeground(Color background) =>
    background.computeLuminance() > 0.45 ? Colors.black87 : Colors.white;

/// The Camelot code as a coloured chip.
class CamelotChip extends StatelessWidget {
  const CamelotChip({
    super.key,
    required this.number,
    required this.letter,
    this.dense = true,
  });

  final int? number;
  final String? letter;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = (number == null || letter == null || letter!.isEmpty)
        ? ''
        : '$number${letter!.toUpperCase()}';
    if (code.isEmpty) return const Text('');

    final background =
        camelotColor(number, letter, theme.brightness) ??
        theme.colorScheme.secondaryContainer;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 10,
        vertical: dense ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        code,
        style: TextStyle(
          fontSize: dense ? 11 : 13,
          fontWeight: FontWeight.w700,
          color: camelotForeground(background),
        ),
      ),
    );
  }
}
