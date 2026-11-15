import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../core/strings.dart';
import '../../data/models.dart';
import '../../services/playback_controller.dart';
import '../../services/playback_plan.dart';
import '../../services/stream_health_checker.dart';
import '../../services/video_player_backend.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

enum _Panel { none, channels, epg }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.initial, this.backendFactory});
  final Channel initial;

  /// Injected in tests; defaults to the ExoPlayer-based backend.
  final MediaBackend Function()? backendFactory;

  /// Global override used by widget tests.
  static MediaBackend Function()? debugBackendFactory;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late Channel _channel = widget.initial;
  late final MediaBackend _backend = (widget.backendFactory ?? PlayerScreen.debugBackendFactory)?.call() ?? VideoPlayerBackend();
  PlaybackController? _ctrl;
  final _rootNode = FocusNode(debugLabel: 'player-root');
  final _playNode = FocusNode(debugLabel: 'play-button');
  final _failNode = FocusNode(debugLabel: 'failure-retry');
  bool _overlay = true;
  bool _fullscreen = true;
  _Panel _panel = _Panel.none;
  Timer? _hideTimer;
  AppState? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ctrl != null) return;
    final app = _app = AppScope.read(context);
    final cfg = app.bundle!.config;
    _ctrl = PlaybackController(
      backend: _backend,
      policy: app.policy,
      recovery: RecoveryPolicy(
          maxRetriesPerSource: cfg.maxRetriesPerSource, baseDelay: Duration(seconds: cfg.retryBaseSeconds)),
      stallTimeout: Duration(seconds: cfg.stallTimeoutSeconds),
      diagnose: (c) => app.checker.checkChannel(c, userCountry: app.geoInfo?.countryCode),
      onPlaybackStarted: (c) => app.recordPlaybackSuccess(c),
    )..addListener(_onCtrl);
    _enterPlayerMode();
    _ctrl!.start(_channel);
    _scheduleHide();
  }

  PlayerPhase? _lastPhase;
  void _onCtrl() {
    final c = _ctrl!;
    if (c.phase == PlayerPhase.failed && _lastPhase != PlayerPhase.failed) {
      final f = c.failure;
      if (f != null && f.detail != 'no_direct_stream') {
        _app?.recordHealth(_channel.id, HealthResult(f.status, detail: 'playback:${f.detail}'.split('\n').first));
      }
      _hideTimer?.cancel();
      setState(() => _overlay = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _failNode.requestFocus();
      });
    }
    _lastPhase = c.phase;
    if (mounted) setState(() {});
  }

  void _enterPlayerMode() {
    _app?.bridge.setKeepScreenOn(true);
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _ctrl?.removeListener(_onCtrl);
    _ctrl?.dispose();
    _app?.bridge.setKeepScreenOn(false);
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _rootNode.dispose();
    _playNode.dispose();
    _failNode.dispose();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || _ctrl!.phase == PlayerPhase.failed || _panel != _Panel.none) return;
      setState(() => _overlay = false);
      _rootNode.requestFocus();
    });
  }

  void _showControls({bool focusButtons = true}) {
    setState(() => _overlay = true);
    _scheduleHide();
    if (focusButtons) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _ctrl!.phase != PlayerPhase.failed) _playNode.requestFocus();
      });
    }
  }

  List<Channel> get _zap => _app!.zapList(_channel);

  void _switchTo(Channel c) {
    setState(() {
      _channel = c;
      _panel = _Panel.none;
    });
    _ctrl!.start(c);
    _showControls(focusButtons: false);
    _rootNode.requestFocus();
  }

  void _zapBy(int delta) {
    final list = _zap;
    if (list.length < 2) return;
    var i = list.indexWhere((c) => c.id == _channel.id);
    if (i < 0) i = 0;
    _switchTo(list[(i + delta) % list.length]); // Dart % is non-negative
  }

  void _togglePanel(_Panel p) {
    setState(() => _panel = _panel == p ? _Panel.none : p);
    if (_panel == _Panel.none) {
      _showControls();
    } else {
      _hideTimer?.cancel();
    }
  }

  Future<void> _openOfficial() async {
    final app = _app!;
    final url = _channel.officialUrl;
    if (url.isEmpty || !app.policy.isOfficialAllowed(url) || !await app.bridge.openUrl(url)) {
      if (mounted) showSnack(context, app.s.t('open_failed'));
    }
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    SystemChrome.setEnabledSystemUIMode(_fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final ctrl = _ctrl!;
    // Always-on media/channel keys.
    if (k == LogicalKeyboardKey.channelUp || k == LogicalKeyboardKey.pageUp) {
      _zapBy(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.channelDown || k == LogicalKeyboardKey.pageDown) {
      _zapBy(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause ||
        k == LogicalKeyboardKey.space) {
      ctrl.togglePause();
      _showControls(focusButtons: false);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyM) {
      ctrl.toggleMute();
      return KeyEventResult.handled;
    }
    // D-pad only when nothing inside the overlay has focus.
    if (!_rootNode.hasPrimaryFocus) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.arrowUp) {
      _zapBy(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _zapBy(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      _togglePanel(_Panel.channels);
      return KeyEventResult.handled;
    }
    if (isSelectKey(k)) {
      _showControls();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool get _canPop => _panel == _Panel.none && (!_overlay || _ctrl!.phase == PlayerPhase.failed);

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final ctrl = _ctrl!;
    final s = app.s;
    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          if (_panel != _Panel.none) {
            _panel = _Panel.none;
          } else {
            _overlay = false;
          }
        });
        _rootNode.requestFocus();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _rootNode,
          autofocus: true,
          onKeyEvent: _onKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _overlay ? setState(() => _overlay = false) : _showControls(focusButtons: false),
            child: Stack(fit: StackFit.expand, children: [
              _VideoView(backend: _backend),
              if (ctrl.phase == PlayerPhase.connecting ||
                  ctrl.phase == PlayerPhase.buffering ||
                  ctrl.phase == PlayerPhase.reconnecting)
                _BufferingIndicator(ctrl: ctrl, s: s),
              if (_overlay) _TopBar(channel: _channel, ctrl: ctrl),
              if (_overlay && ctrl.phase != PlayerPhase.failed)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _Controls(
                    ctrl: ctrl,
                    playNode: _playNode,
                    isFav: app.store.isFavourite(_channel.id),
                    hasOfficial: _channel.officialUrl.isNotEmpty,
                    onPrev: () => _zapBy(-1),
                    onNext: () => _zapBy(1),
                    onFav: () => app.toggleFavourite(_channel.id),
                    onList: () => _togglePanel(_Panel.channels),
                    onEpg: () => _togglePanel(_Panel.epg),
                    onFullscreen: _toggleFullscreen,
                    onOfficial: _openOfficial,
                    onAnyAction: _scheduleHide,
                  ),
                ),
              if (ctrl.phase == PlayerPhase.failed)
                _FailurePanel(
                  channel: _channel,
                  failure: ctrl.failure,
                  retryNode: _failNode,
                  onRetry: () => ctrl.retryNow(),
                  onOfficial: _openOfficial,
                  onPick: _switchTo,
                ),
              if (_panel == _Panel.channels)
                _SidePanel(
                  title: s.t('channels'),
                  child: _ChannelList(channels: _zap, current: _channel, onPick: _switchTo),
                ),
              if (_panel == _Panel.epg) _SidePanel(title: s.t('epg'), child: _EpgView(channel: _channel)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _VideoView extends StatelessWidget {
  const _VideoView({required this.backend});
  final MediaBackend backend;

  @override
  Widget build(BuildContext context) {
    final b = backend;
    if (b is! VideoPlayerBackend) return const SizedBox.expand();
    return ValueListenableBuilder<VideoPlayerController?>(
      valueListenable: b.controller,
      builder: (_, c, __) {
        if (c == null || !c.value.isInitialized) return const SizedBox.expand();
        final ar = c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9;
        return Center(child: AspectRatio(aspectRatio: ar, child: VideoPlayer(c)));
      },
    );
  }
}

class _BufferingIndicator extends StatelessWidget {
  const _BufferingIndicator({required this.ctrl, required this.s});
  final PlaybackController ctrl;
  final S s;

  @override
  Widget build(BuildContext context) {
    final label = switch (ctrl.phase) {
      PlayerPhase.connecting => s.t('connecting'),
      PlayerPhase.reconnecting =>
        '${s.t('reconnecting')} (${s.t('attempt')} ${ctrl.attempt}, ${ctrl.sourceIndex + 1}/${ctrl.sourceCount})',
      _ => s.t('buffering'),
    };
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(color: AppColors.accent),
        const SizedBox(height: 12),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
      ]),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.channel, required this.ctrl});
  final Channel channel;
  final PlaybackController ctrl;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final now = DateTime.now();
    final progs = app.bundle?.epg.upcoming(channel.epgId.isEmpty ? channel.id : channel.epgId, now, count: 1) ??
        const <EpgProgram>[];
    final status = ctrl.phase == PlayerPhase.playing || ctrl.phase == PlayerPhase.buffering
        ? StreamStatus.online
        : app.statusOf(channel);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(28, 18, 28, 40),
        decoration: const BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xCC000000), Colors.transparent])),
        child: Row(children: [
          ChannelLogo(channel, size: 52),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(channel.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 10),
                StatusBadge(status),
              ]),
              Text(
                  progs.isNotEmpty
                      ? '${s.t('now')}: ${progs.first.title} (${hhmm(progs.first.start)}–${hhmm(progs.first.end)})'
                      : '${channel.provider} · ${app.bundle?.country(channel.countryCode)?.name(app.lang) ?? ''}',
                  style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
            ]),
          ),
          if (app.isTv) Text(s.t('remote_hint'), style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
        ]),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.ctrl,
    required this.playNode,
    required this.isFav,
    required this.hasOfficial,
    required this.onPrev,
    required this.onNext,
    required this.onFav,
    required this.onList,
    required this.onEpg,
    required this.onFullscreen,
    required this.onOfficial,
    required this.onAnyAction,
  });

  final PlaybackController ctrl;
  final FocusNode playNode;
  final bool isFav;
  final bool hasOfficial;
  final VoidCallback onPrev, onNext, onFav, onList, onEpg, onFullscreen, onOfficial, onAnyAction;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    Widget btn(IconData icon, String tip, VoidCallback onTap, {FocusNode? node, Key? key}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Tooltip(
            message: tip,
            child: FocusTile(
              key: key,
              focusNode: node,
              radius: 28,
              color: const Color(0x99000000),
              padding: const EdgeInsets.all(12),
              onTap: () {
                onAnyAction();
                onTap();
              },
              onFocus: (f) => f ? onAnyAction() : null,
              child: Icon(icon, color: Colors.white, size: 26),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 22),
      decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color(0xCC000000), Colors.transparent])),
      child: FocusTraversalGroup(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            btn(Icons.skip_previous, 'CH-', onPrev),
            btn(ctrl.paused ? Icons.play_arrow : Icons.pause, s.t('play_pause'), ctrl.togglePause,
                node: playNode, key: const ValueKey('btn_play')),
            btn(Icons.skip_next, 'CH+', onNext),
            const SizedBox(width: 12),
            btn(ctrl.muted ? Icons.volume_off : Icons.volume_up, s.t('mute'), ctrl.toggleMute),
            btn(Icons.volume_down, 'VOL-', () => ctrl.setVolume(ctrl.volume - 0.1)),
            SizedBox(
              width: 60,
              child: Text('${((ctrl.muted ? 0 : ctrl.volume) * 100).round()}%',
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
            ),
            btn(Icons.volume_up_outlined, 'VOL+', () => ctrl.setVolume(ctrl.volume + 0.1)),
            const SizedBox(width: 12),
            btn(isFav ? Icons.star : Icons.star_border, isFav ? s.t('remove_fav') : s.t('add_fav'), onFav,
                key: const ValueKey('btn_fav')),
            btn(Icons.list, s.t('channels'), onList),
            btn(Icons.event_note, s.t('epg'), onEpg),
            btn(Icons.fullscreen, s.t('fullscreen'), onFullscreen),
            if (hasOfficial) btn(Icons.open_in_new, s.t('open_official'), onOfficial),
          ]),
        ),
      ),
    );
  }
}

class _FailurePanel extends StatelessWidget {
  const _FailurePanel({
    required this.channel,
    required this.failure,
    required this.retryNode,
    required this.onRetry,
    required this.onOfficial,
    required this.onPick,
  });

  final Channel channel;
  final PlaybackFailure? failure;
  final FocusNode retryNode;
  final VoidCallback onRetry;
  final VoidCallback onOfficial;
  final ValueChanged<Channel> onPick;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final st = failure?.status ?? StreamStatus.unknown;
    final detail = failure?.detail ?? '';
    final alts = findAlternatives(channel, app.bundle?.channels ?? const [],
        statuses: app.health, userCountry: app.geoInfo?.countryCode);
    final officialOk = channel.officialUrl.isNotEmpty && app.policy.isOfficialAllowed(channel.officialUrl);
    return Container(
      color: const Color(0xE6000000),
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: FocusTraversalGroup(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.portable_wifi_off, color: AppColors.accent, size: 48),
              const SizedBox(height: 10),
              Text(s.t('cannot_play'),
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              StatusBadge(st),
              const SizedBox(height: 10),
              Text(s.reason(st, detail),
                  key: const ValueKey('failure_reason'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.text, fontSize: 15)),
              const SizedBox(height: 6),
              Text(
                [
                  '${s.t('your_country')}: ${app.geoInfo?.countryCode ?? s.t('unknown')}',
                  if (channel.geoAllowed.isNotEmpty) '${s.t('allowed_in')}: ${channel.geoAllowed.join(', ')}',
                  if (app.vpnActive) s.t('vpn_status_on'),
                ].join(' · '),
                style: const TextStyle(color: AppColors.textDim, fontSize: 12),
              ),
              const SizedBox(height: 18),
              Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
                if (channel.hasDirectStream)
                  FocusTile(
                    key: const ValueKey('btn_retry'),
                    focusNode: retryNode,
                    autofocus: true,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    onTap: onRetry,
                    child: Text(s.t('retry'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                  ),
                if (officialOk)
                  FocusTile(
                    key: const ValueKey('btn_official'),
                    focusNode: channel.hasDirectStream ? null : retryNode,
                    autofocus: !channel.hasDirectStream,
                    color: AppColors.accent.withValues(alpha: 0.25),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    onTap: onOfficial,
                    child: Text(
                        channel.officialPlatform.isEmpty
                            ? s.t('open_official')
                            : '${s.t('open_official')} · ${channel.officialPlatform}',
                        style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w800)),
                  ),
              ]),
              const SizedBox(height: 22),
              Text(s.t('alternatives'), style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
              const SizedBox(height: 8),
              if (alts.isEmpty)
                Text(s.t('no_alternatives'), style: const TextStyle(color: AppColors.textDim, fontSize: 12))
              else
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final a in alts)
                      FocusTile(
                        key: ValueKey('alt_${a.id}'),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        onTap: () => onPick(a),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          ChannelLogo(a, size: 28),
                          const SizedBox(width: 8),
                          Text(a.name, style: const TextStyle(color: Colors.white)),
                          const SizedBox(width: 6),
                          StatusBadge(app.statusOf(a), compact: true),
                        ]),
                      ),
                  ],
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Positioned(
        top: 0,
        bottom: 0,
        right: 0,
        width: 320,
        child: Container(
          color: const Color(0xF0101520),
          padding: const EdgeInsets.fromLTRB(14, 20, 14, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(color: AppColors.accent, fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Expanded(child: FocusTraversalGroup(child: child)),
          ]),
        ),
      );
}

class _ChannelList extends StatelessWidget {
  const _ChannelList({required this.channels, required this.current, required this.onPick});
  final List<Channel> channels;
  final Channel current;
  final ValueChanged<Channel> onPick;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListView.separated(
      itemCount: channels.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, i) {
        final c = channels[i];
        final cur = c.id == current.id;
        return FocusTile(
          key: ValueKey('list_${c.id}'),
          autofocus: cur,
          selected: cur,
          padding: const EdgeInsets.all(8),
          onTap: () => onPick(c),
          child: Row(children: [
            ChannelLogo(c, size: 36),
            const SizedBox(width: 10),
            Expanded(
                child: Text(c.name,
                    overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14))),
            StatusBadge(app.statusOf(c), compact: true),
          ]),
        );
      },
    );
  }
}

class _EpgView extends StatelessWidget {
  const _EpgView({required this.channel});
  final Channel channel;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final list = app.bundle?.epg.upcoming(channel.epgId.isEmpty ? channel.id : channel.epgId, DateTime.now(),
            count: 12) ??
        const <EpgProgram>[];
    if (list.isEmpty) {
      return Focus(
          autofocus: true,
          child: Text(s.t('no_epg'), style: const TextStyle(color: AppColors.textDim)));
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (_, i) {
        final p = list[i];
        final now = p.isOnAt(DateTime.now());
        return FocusTile(
          autofocus: i == 0,
          onTap: () {},
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${hhmm(p.start.toLocal())} – ${hhmm(p.end.toLocal())}${now ? '  • ${s.t('now')}' : ''}',
                style: TextStyle(color: now ? AppColors.accent : AppColors.textDim, fontSize: 12)),
            Text(p.title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
            if (p.description.isNotEmpty)
              Text(p.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
          ]),
        );
      },
    );
  }
}
