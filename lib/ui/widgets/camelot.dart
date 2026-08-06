library;

import 'package:flutter/material.dart';

const List<Color> _wheel = [
  Color(0xFF3FD2E0),
  Color(0xFF3FE0B4),
  Color(0xFF52E063),
  Color(0xFF93E03F),
  Color(0xFFD6E03F),
  Color(0xFFE0B23F),
  Color(0xFFE08A3F),
  Color(0xFFE0633F),
  Color(0xFFE03F63),
  Color(0xFFE03FB4),
  Color(0xFFB43FE0),
  Color(0xFF633FE0),
];

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

Color camelotForeground(Color background) =>
    background.computeLuminance() > 0.45 ? Colors.black87 : Colors.white;

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
