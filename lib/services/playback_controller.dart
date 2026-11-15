// Playback state machine with bounded auto-reconnect and source fallback.
//
// The actual decoder is behind [MediaBackend] so the logic can be unit-tested
// without a device. In the app the backend is [VideoPlayerBackend]
// (package:video_player → AndroidX Media3 ExoPlayer, minSdk 21).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/diagnostics.dart';
import '../core/url_policy.dart';
import '../data/models.dart';
import 'playback_plan.dart';
import 'stream_health_checker.dart';

enum BackendEventType { error, buffering, playing, ended }

class BackendEvent {
  BackendEvent(this.type, {this.value = false, this.message});
  final BackendEventType type;
  final bool value;
  final String? message;
}

abstract class MediaBackend {
  /// Opens and starts the source. Throws on failure.
  Future<void> open(PlaybackSource source);
  Future<void> play();
  Future<void> pause();
  Future<void> setVolume(double v);
  Future<void> close();
  set onEvent(void Function(BackendEvent e)? cb);
}

enum PlayerPhase { idle, connecting, playing, buffering, reconnecting, failed }

class PlaybackFailure {
  PlaybackFailure(this.status, this.detail);
  final StreamStatus status;
  final String detail;
}

typedef Diagnoser = Future<HealthResult> Function(Channel channel);

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.backend,
    required this.policy,
    required this.recovery,
    this.stallTimeout = const Duration(seconds: 20),
    this.diagnose,
    this.onPlaybackStarted,
  }) {
    backend.onEvent = _onBackendEvent;
  }

  final MediaBackend backend;
  final UrlPolicy policy;
  final RecoveryPolicy recovery;
  final Duration stallTimeout;

  /// Optional health check run once all sources failed, to classify the
  /// failure (e.g. GEO_RESTRICTED vs OFFLINE).
  final Diagnoser? diagnose;
  final void Function(Channel c)? onPlaybackStarted;

  Channel? _channel;
  List<PlaybackSource> _sources = const [];
  int _sourceIndex = 0;
  int _retries = 0;
  int _totalAttempts = 0;
  int _generation = 0;
  Timer? _retryTimer;
  Timer? _stallTimer;
  bool _disposed = false;

  PlayerPhase phase = PlayerPhase.idle;
  PlaybackFailure? failure;
  bool paused = false;
  bool muted = false;
  double volume = 1.0;
  String? lastError;

  Channel? get channel => _channel;
  int get attempt => _totalAttempts;
  int get sourceIndex => _sourceIndex;
  int get sourceCount => _sources.length;
  PlaybackSource? get currentSource =>
      _sourceIndex < _sources.length ? _sources[_sourceIndex] : null;

  void _set(PlayerPhase p) {
    if (_disposed) return;
    phase = p;
    notifyListeners();
  }

  void _cancelTimers() {
    _retryTimer?.cancel();
    _stallTimer?.cancel();
    _retryTimer = null;
    _stallTimer = null;
  }

  Future<void> start(Channel c) async {
    _generation++;
    _cancelTimers();
    _channel = c;
    _sources = buildSources(c, policy);
    _sourceIndex = 0;
    _retries = 0;
    _totalAttempts = 0;
    failure = null;
    paused = false;
    lastError = null;
    if (_sources.isEmpty) {
      await backend.close();
      final reason = !c.streamType.isPlayable || (c.streamUrl.isEmpty && c.secondaryUrl.isEmpty)
          ? 'no_direct_stream'
          : 'rejected_by_url_policy';
      diag.info('player', '${c.id}: $reason');
      failure = PlaybackFailure(
          c.availability == StreamStatus.online ? StreamStatus.unknown : c.availability, reason);
      _set(PlayerPhase.failed);
      return;
    }
    await _openCurrent(_generation);
  }

  Future<void> retryNow() async {
    final c = _channel;
    if (c != null) await start(c);
  }

  Future<void> _openCurrent(int gen) async {
    final src = currentSource;
    if (src == null || gen != _generation) return;
    _totalAttempts++;
    _set(_totalAttempts == 1 ? PlayerPhase.connecting : PlayerPhase.reconnecting);
    diag.info('player', '${_channel!.id} open ${src.kind.name} ${redactUrl(src.url)} (attempt $_totalAttempts)');
    try {
      await backend.open(src);
      if (gen != _generation) return;
      await backend.setVolume(muted ? 0 : volume);
      if (paused) await backend.pause();
      _set(PlayerPhase.playing);
      _retries = 0;
      onPlaybackStarted?.call(_channel!);
    } catch (e) {
      if (gen != _generation) return;
      await _handleFailure(e.toString(), gen);
    }
  }

  void _onBackendEvent(BackendEvent e) {
    if (_disposed || _channel == null) return;
    final gen = _generation;
    switch (e.type) {
      case BackendEventType.error:
        _handleFailure(e.message ?? 'player error', gen);
        break;
      case BackendEventType.ended:
        // A live stream should never "end": treat it as a dropped connection.
        _handleFailure('stream ended unexpectedly', gen);
        break;
      case BackendEventType.buffering:
        if (phase == PlayerPhase.failed || phase == PlayerPhase.reconnecting || phase == PlayerPhase.connecting) {
          return;
        }
        if (e.value) {
          _stallTimer ??= Timer(stallTimeout, () {
            _stallTimer = null;
            _handleFailure('stalled: buffering > ${stallTimeout.inSeconds}s', gen);
          });
          _set(PlayerPhase.buffering);
        } else {
          _stallTimer?.cancel();
          _stallTimer = null;
          _set(PlayerPhase.playing);
        }
        break;
      case BackendEventType.playing:
        break;
    }
  }

  Future<void> _handleFailure(String message, int gen) async {
    if (gen != _generation || _disposed || phase == PlayerPhase.failed) return;
    if (_retryTimer != null) return; // a retry is already scheduled
    _stallTimer?.cancel();
    _stallTimer = null;
    lastError = message;
    final status = statusFromPlayerError(message);
    diag.warn('player', '${_channel?.id}: ${status.label} ${Diagnostics.scrub(message).split('\n').first}');

    if (!RecoveryPolicy.isPermanent(status) && recovery.canRetry(_retries)) {
      _retries++;
      final delay = recovery.delayFor(_retries);
      _set(PlayerPhase.reconnecting);
      _retryTimer = Timer(delay, () {
        _retryTimer = null;
        _openCurrent(gen);
      });
      return;
    }
    if (_sourceIndex + 1 < _sources.length) {
      _sourceIndex++;
      _retries = 0;
      diag.info('player', '${_channel?.id}: switching to ${currentSource!.kind.name} source');
      _set(PlayerPhase.reconnecting);
      _retryTimer = Timer(recovery.baseDelay, () {
        _retryTimer = null;
        _openCurrent(gen);
      });
      return;
    }
    await backend.close();
    if (gen != _generation) return;
    var finalStatus = status;
    var detail = message;
    final d = diagnose;
    // An explicit answer from the provider (401/410/451) is kept as is;
    // otherwise run one polite health check to explain the failure.
    if (d != null && _channel != null && !RecoveryPolicy.isPermanent(status)) {
      try {
        final r = await d(_channel!);
        if (gen != _generation) return;
        if (r.status != StreamStatus.unknown || finalStatus == StreamStatus.unknown) {
          finalStatus = r.status == StreamStatus.online ? StreamStatus.unknown : r.status;
          detail = r.detail;
        }
      } catch (_) {}
    }
    failure = PlaybackFailure(finalStatus, detail);
    diag.warn('player', '${_channel?.id}: giving up after $_totalAttempts attempts -> ${finalStatus.label}');
    _set(PlayerPhase.failed);
  }

  Future<void> togglePause() async {
    paused = !paused;
    paused ? await backend.pause() : await backend.play();
    notifyListeners();
  }

  Future<void> setVolume(double v) async {
    volume = v.clamp(0.0, 1.0);
    if (volume > 0) muted = false;
    await backend.setVolume(muted ? 0 : volume);
    notifyListeners();
  }

  Future<void> toggleMute() async {
    muted = !muted;
    await backend.setVolume(muted ? 0 : volume);
    notifyListeners();
  }

  Future<void> stop() async {
    _generation++;
    _cancelTimers();
    await backend.close();
    _set(PlayerPhase.idle);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cancelTimers();
    backend.onEvent = null;
    backend.close();
    super.dispose();
  }
}
