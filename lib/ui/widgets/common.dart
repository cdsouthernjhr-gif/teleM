import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../state/app_state.dart';

/// Provides [AppState] to the widget tree.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState read(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<AppScope>()!.widget as AppScope).notifier!;
}

class AppColors {
  static const bg = Color(0xFF0B0F17);
  static const surface = Color(0xFF151B26);
  static const surfaceHi = Color(0xFF1E2633);
  static const accent = Color(0xFFE5B53A); // gold
  static const accent2 = Color(0xFF2F80ED);
  static const text = Color(0xFFEDEFF3);
  static const textDim = Color(0xFF9AA3B2);
  static const focus = Color(0xFFFFFFFF);
}

Color statusColor(StreamStatus s) => switch (s) {
      StreamStatus.online => const Color(0xFF2ECC71),
      StreamStatus.offline => const Color(0xFFE74C3C),
      StreamStatus.geoRestricted => const Color(0xFFF39C12),
      StreamStatus.authRequired => const Color(0xFF9B59B6),
      StreamStatus.expired => const Color(0xFFE67E22),
      StreamStatus.timeout => const Color(0xFFE67E22),
      StreamStatus.unknown => const Color(0xFF7F8C8D),
    };

class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key, this.compact = false});
  final StreamStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = statusColor(status);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.18),
        border: Border.all(color: c.withValues(alpha: 0.8)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(status.label,
          style: TextStyle(color: c, fontSize: compact ? 9 : 11, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
    );
  }
}

/// A focusable, clickable tile with a clear focus ring for TV remotes.
class FocusTile extends StatefulWidget {
  const FocusTile({
    super.key,
    required this.child,
    required this.onTap,
    this.autofocus = false,
    this.focusNode,
    this.radius = 10,
    this.selected = false,
    this.padding = EdgeInsets.zero,
    this.color = AppColors.surface,
    this.onFocus,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool autofocus;
  final FocusNode? focusNode;
  final double radius;
  final bool selected;
  final EdgeInsets padding;
  final Color color;
  final ValueChanged<bool>? onFocus;
  final String? semanticLabel;

  @override
  State<FocusTile> createState() => _FocusTileState();
}

class _FocusTileState extends State<FocusTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final border = _focused
        ? Border.all(color: AppColors.focus, width: 3)
        : widget.selected
            ? Border.all(color: AppColors.accent, width: 2)
            : Border.all(color: Colors.transparent, width: 2);
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: AnimatedScale(
        scale: _focused ? 1.05 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Material(
          color: _focused ? AppColors.surfaceHi : widget.color,
          borderRadius: BorderRadius.circular(widget.radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            onTap: widget.onTap,
            focusColor: Colors.transparent,
            onFocusChange: (f) {
              setState(() => _focused = f);
              widget.onFocus?.call(f);
              if (f) {
                Scrollable.ensureVisible(context,
                    alignment: 0.5, duration: const Duration(milliseconds: 150));
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: widget.padding,
              decoration: BoxDecoration(border: border, borderRadius: BorderRadius.circular(widget.radius)),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Channel logo: cached file → monogram fallback (never blocks the UI).
class ChannelLogo extends StatefulWidget {
  const ChannelLogo(this.channel, {super.key, this.size = 64});
  final Channel channel;
  final double size;

  @override
  State<ChannelLogo> createState() => _ChannelLogoState();
}

class _ChannelLogoState extends State<ChannelLogo> {
  File? _file;
  String? _for;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(ChannelLogo old) {
    super.didUpdateWidget(old);
    if (old.channel.logo != widget.channel.logo) _load();
  }

  void _load() {
    final logo = widget.channel.logo;
    if (_for == logo) return;
    _for = logo;
    _file = null;
    AppScope.read(context).logos.get(logo).then((f) {
      if (mounted && _for == logo) setState(() => _file = f);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    if (_file != null) {
      return SizedBox(
        width: s,
        height: s,
        child: Image.file(_file!,
            cacheWidth: (s * 2).round(),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _Monogram(widget.channel, s)),
      );
    }
    return _Monogram(widget.channel, s);
  }
}

class _Monogram extends StatelessWidget {
  const _Monogram(this.c, this.size);
  final Channel c;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hue = (c.id.codeUnits.fold<int>(0, (a, b) => a * 31 + b) % 360).toDouble();
    final color = HSLColor.fromAHSL(1, hue, 0.45, 0.35).toColor();
    final label = c.name.length <= 6 ? c.name : c.name.split(' ').map((w) => w.isEmpty ? '' : w[0]).join();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size * 0.18)),
      padding: EdgeInsets.all(size * 0.08),
      child: FittedBox(
        child: Text(label,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
      ),
    );
  }
}

/// Keys that mean "back" on TV remotes and keyboards.
bool isBackKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.browserBack;

bool isSelectKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.select ||
    k == LogicalKeyboardKey.enter ||
    k == LogicalKeyboardKey.numpadEnter ||
    k == LogicalKeyboardKey.gameButtonA;

void showSnack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
}
