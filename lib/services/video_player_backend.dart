// MediaBackend implementation on package:video_player (ExoPlayer/Media3 on
// Android). One controller at a time to stay light on 2 GB TV boxes.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../data/models.dart';
import 'playback_controller.dart';
import 'playback_plan.dart';

class VideoPlayerBackend implements MediaBackend {
  VideoPlayerBackend({this.initTimeout = const Duration(seconds: 25)});

  final Duration initTimeout;

  /// The widget layer listens to this to render [VideoPlayer].
  final ValueNotifier<VideoPlayerController?> controller = ValueNotifier(null);

  void Function(BackendEvent e)? _cb;
  bool _wasBuffering = false;
  bool _errorReported = false;
  bool _endReported = false;

  @override
  set onEvent(void Function(BackendEvent e)? cb) => _cb = cb;

  void _listener() {
    final c = controller.value;
    if (c == null) return;
    final v = c.value;
    if (v.hasError && !_errorReported) {
      _errorReported = true;
      _cb?.call(BackendEvent(BackendEventType.error, message: v.errorDescription));
      return;
    }
    if (v.isInitialized && v.isCompleted && !_endReported) {
      _endReported = true;
      _cb?.call(BackendEvent(BackendEventType.ended));
      return;
    }
    if (v.isBuffering != _wasBuffering) {
      _wasBuffering = v.isBuffering;
      _cb?.call(BackendEvent(BackendEventType.buffering, value: v.isBuffering));
    }
  }

  @override
  Future<void> open(PlaybackSource source) async {
    await close();
    _errorReported = false;
    _endReported = false;
    _wasBuffering = false;
    final hint = switch (source.type) {
      StreamType.hls => VideoFormat.hls,
      StreamType.dash => VideoFormat.dash,
      _ => VideoFormat.other,
    };
    final c = VideoPlayerController.networkUrl(
      Uri.parse(source.url),
      formatHint: hint,
      httpHeaders: const {'User-Agent': 'MYASEANTV/1.0 (Android; ExoPlayer)'},
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    controller.value = c;
    try {
      await c.initialize().timeout(initTimeout);
    } on TimeoutException {
      await close();
      throw Exception('timeout: player did not start within ${initTimeout.inSeconds}s');
    } catch (e) {
      final desc = c.value.errorDescription ?? e.toString();
      await close();
      throw Exception(desc);
    }
    c.addListener(_listener);
    await c.play();
  }

  @override
  Future<void> play() async => controller.value?.play();

  @override
  Future<void> pause() async => controller.value?.pause();

  @override
  Future<void> setVolume(double v) async => controller.value?.setVolume(v);

  @override
  Future<void> close() async {
    final c = controller.value;
    if (c == null) return;
    controller.value = null;
    c.removeListener(_listener);
    try {
      await c.dispose();
    } catch (_) {}
  }
}
