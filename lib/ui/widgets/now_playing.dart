library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/player.dart';
import 'camelot.dart';

String _clock(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PreviewPlayer>();
    final track = player.current;
    if (track == null && player.error == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (track == null) {
      return Material(
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  player.error ?? 'No preview available.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: player.stop,
              ),
            ],
          ),
        ),
      );
    }

    return Material(
      color: scheme.surfaceContainerHighest,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Row(
              children: [
                Text(
                  _clock(player.position),
                  style: theme.textTheme.labelSmall,
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 16,
                      ),
                    ),
                    child: Slider(
                      value: player.progress.clamp(0.0, 1.0),
                      onChanged: player.duration.inMilliseconds == 0
                          ? null
                          : player.seek,
                    ),
                  ),
                ),
                Text(
                  _clock(player.duration),
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Row(
              children: [
                IconButton(
                  iconSize: 34,
                  icon: Icon(
                    player.playing
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: scheme.primary,
                  ),
                  onPressed: () => player.toggle(track),
                ),
                const SizedBox(width: 4),
                CamelotChip(
                  number: track.key?.camelotNumber,
                  letter: track.key?.camelotLetter,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        track.artistNames,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (player.loading) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,

                      value: player.loadProgress > 0
                          ? player.loadProgress
                          : null,
                    ),
                  ),
                ],

                IconButton(
                  tooltip: player.autoplay
                      ? 'Autoplay on - plays the next track'
                      : 'Autoplay off',
                  icon: Icon(
                    player.autoplay
                        ? Icons.playlist_play
                        : Icons.playlist_remove,
                    color: player.autoplay
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                  onPressed: () => player.autoplay = !player.autoplay,
                ),
                IconButton(
                  tooltip: 'Stop',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: player.stop,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
