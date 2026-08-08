library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/atomic_write.dart';
import '../engine/digger.dart';
import 'downloads.dart';
import 'session.dart';

/// Holds the bundle of crates, keeps it on disk, and walks it into the
/// download queue.
class DiggerRunner extends ChangeNotifier {
  /// The bundle, in the order it will be dug.
  ///
  /// Handed to the walk by reference, so a crate added while a dig is running
  /// joins that dig rather than waiting for the next one.
  final List<DiggerCrate> crates = [];

  bool runOnStart = false;

  bool running = false;
  DiggerStep? step;

  /// The run's queued total at the moment the current crate started, so the
  /// UI can show what this crate on its own has contributed.
  int stepQueuedBefore = 0;

  /// Totals for the last completed run. While one is in progress the live
  /// figures come from the queue, which updates as it goes.
  int queued = 0;
  int skipped = 0;

  /// Crates that failed during the last run, with their reason. A dig carries
  /// on past these, so a run can succeed with gaps.
  final List<String> failures = [];

  DateTime? lastRunAt;
  String? error;

  final DiggerControl _control = DiggerControl();

  int _sequence = 0;
  bool _loaded = false;
  bool _autoStarted = false;
  bool _disposed = false;

  Session? _session;
  DownloadQueue? _queue;

  bool get isConfigured => _loaded;

  bool get canRun =>
      !running && crates.isNotEmpty && !(_queue?.isDiscovering ?? false);

  /// True when at least one crate takes everything, which makes the total
  /// unknowable until the walk runs.
  bool get hasUnlimitedCrate => crates.any((crate) => crate.takesEverything);

  /// Rough upper bound on what queueing the bundle would fetch, before
  /// duplicates and already-downloaded tracks are taken out. Only meaningful
  /// when [hasUnlimitedCrate] is false.
  int get estimatedTracks => crates.fold(
    0,
    (total, crate) => total + (crate.takesEverything ? 0 : crate.boundedLimit),
  );

  /// What the bundle will fetch, in words.
  String get sizeLabel {
    if (crates.isEmpty) return 'No crates yet.';
    final count = '${crates.length} ${crates.length == 1 ? 'crate' : 'crates'}';
    if (!hasUnlimitedCrate) return '$count, up to $estimatedTracks tracks';
    return estimatedTracks == 0
        ? '$count, every matching track'
        : '$count, $estimatedTracks tracks plus every match of the rest';
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// A fresh identifier for a crate. Crates with identical filters are still
  /// separate entries, so they cannot be keyed by their contents.
  String nextCrateId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';

  Future<File> _bundleFile() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}${Platform.pathSeparator}digger_bundle.json');
  }

  Future<void> load() async {
    try {
      final file = await _bundleFile();
      if (await file.exists()) {
        final payload = jsonDecode(await file.readAsString());
        if (payload is Map<String, dynamic>) {
          runOnStart = payload['run_on_start'] == true;
          final raw = payload['crates'];
          if (raw is List) {
            for (final entry in raw.whereType<Map<String, dynamic>>()) {
              final crate = DiggerCrate.fromJson(entry);
              if (crate != null) crates.add(crate);
            }
          }
        }
      }
    } on Object {
      // Best-effort load; a corrupt bundle just starts empty.
    }
    _loaded = true;
    _notify();
    _considerAutoStart();
  }

  Future<void> save() async {
    try {
      await writeFileAtomically(
        await _bundleFile(),
        jsonEncode({
          'run_on_start': runOnStart,
          'crates': [for (final crate in crates) crate.toJson()],
        }),
      );
    } on Object {
      // Best-effort save; ignore write failures (e.g. read-only fs).
    }
  }

  void addCrate(DiggerCrate crate) => addCrates([crate]);

  /// Adds a batch, saving once. Adding one at a time meant a save per crate,
  /// each racing the last to write the same file.
  void addCrates(Iterable<DiggerCrate> batch) {
    final added = batch.toList();
    if (added.isEmpty) return;
    crates.addAll(added);
    error = null;
    _notify();
    unawaited(save());
  }

  void removeCrate(String id) {
    // Also stops it if it happens to be the one being walked, so deleting the
    // crate you are watching does what it looks like it does.
    _control.skip(id);
    crates.removeWhere((crate) => crate.id == id);
    _notify();
    unawaited(save());
  }

  /// Stops collecting from the crate being walked and moves on to the next.
  ///
  /// Tracks already queued from it stay queued, and the crate stays in the
  /// bundle for next time. Use this when a crate has turned up enough.
  void skipCurrentCrate() {
    final current = step?.crate.id;
    if (current == null) return;
    _control.skip(current);
    _notify();
  }

  /// Whether there is a crate in progress that can be skipped.
  bool get canSkipCurrent => running && step != null;

  void clearCrates() {
    if (crates.isEmpty) return;
    crates.clear();
    _notify();
    unawaited(save());
  }

  /// Turning this on takes effect at the next launch rather than starting a
  /// dig immediately, which is what the setting says it does.
  void setRunOnStart(bool value) {
    if (runOnStart == value) return;
    runOnStart = value;
    _notify();
    unawaited(save());
  }

  /// Keeps the current session and queue to hand, and starts an automatic dig
  /// once everything it needs has arrived. Called from the provider tree, so
  /// it runs again each time either of those changes.
  void attach(Session session, DownloadQueue queue) {
    _session = session;
    _queue = queue;
    _considerAutoStart();
  }

  void _considerAutoStart() {
    if (_autoStarted || !_loaded || !runOnStart || crates.isEmpty) return;

    final session = _session;
    final queue = _queue;
    if (session == null || queue == null) return;
    if (session.status != SessionStatus.signedIn) return;

    _autoStarted = true;

    // Reached from inside a build, so the run has to wait for the frame to
    // finish before it starts notifying listeners.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) unawaited(run(session, queue));
    });
  }

  /// Stops the walk. Tracks already queued keep downloading.
  void stop() => _queue?.cancelDiscovery();

  /// Walks the bundle, queueing what it finds as it goes.
  ///
  /// Returns how many tracks were queued. Tracks already on disk are passed
  /// over when the queue is set to skip them, and counted in [skipped].
  Future<int> run(Session session, DownloadQueue queue) async {
    if (running || queue.isDiscovering) return 0;
    if (crates.isEmpty) {
      error = 'Add at least one crate to the bundle first.';
      _notify();
      return 0;
    }

    running = true;
    error = null;
    step = null;
    queued = 0;
    skipped = 0;
    stepQueuedBefore = 0;
    failures.clear();
    _control.reset();
    _notify();

    final skippedBefore = queue.skippedDownloaded;
    final digger = Digger(session.catalog);
    final total = crates.length;

    try {
      queued = await queue.enqueueStream(
        digger.dig(
          crates,
          control: _control,
          onStep: (value) {
            step = value;
            stepQueuedBefore = queue.discovered;
            queue.describeDiscovery(value.label);
            _notify();
          },
          onFailure: (crate, exception) =>
              failures.add('${crate.title}: $exception'),
        ),
        label: 'Digging $total ${total == 1 ? 'crate' : 'crates'}',
      );
      error = queue.discoverError;
    } on Object catch (exception) {
      error = exception.toString();
    } finally {
      skipped = queue.skippedDownloaded - skippedBefore;
      lastRunAt = DateTime.now();
      running = false;
      step = null;
      _notify();
    }

    return queued;
  }

  /// A one-line account of the last run, or null if there has not been one.
  String? get summary {
    if (lastRunAt == null) return null;
    return [
      'Queued $queued',
      if (skipped > 0) 'skipped $skipped already downloaded',
      if (failures.isNotEmpty)
        '${failures.length} ${failures.length == 1 ? 'crate' : 'crates'} failed',
    ].join(', ');
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
