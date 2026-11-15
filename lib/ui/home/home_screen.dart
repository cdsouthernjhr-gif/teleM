import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/strings.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../player/player_screen.dart';
import '../settings/settings_screen.dart';
import '../widgets/common.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static void openPlayer(BuildContext context, Channel c) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlayerScreen(initial: c)));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final b = app.bundle;
    final announcement = b == null ? '' : (app.lang == 'en' ? b.config.announcementEn : b.config.announcementMs);
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: FocusTraversalGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Header(),
                if (!app.online) _Banner(s.t('offline_banner'), Icons.wifi_off, const Color(0xFFE74C3C)),
                if (announcement.isNotEmpty) _Banner(announcement, Icons.campaign, AppColors.accent2),
                const SizedBox(height: 10),
                const _CountryBar(),
                if (app.selectedCountry != kFavouritesTab) const _CategoryBar(),
                const SizedBox(height: 8),
                const Expanded(child: _ChannelGrid()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, this.icon, this.color);
  final String text;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.6))),
        child: Row(children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(color: AppColors.text, fontSize: 13))),
        ]),
      );
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final last = app.lastChannel;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 8,
      children: [
        RichText(
          text: const TextSpan(children: [
            TextSpan(
                text: 'MY ',
                style: TextStyle(color: AppColors.accent, fontSize: 26, fontWeight: FontWeight.w900)),
            TextSpan(
                text: 'ASEAN TV',
                style: TextStyle(color: AppColors.text, fontSize: 26, fontWeight: FontWeight.w900)),
          ]),
        ),
        Wrap(
          spacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (last != null)
              _HeaderButton(
                icon: Icons.history,
                label: narrow ? last.name : '${s.t('last_channel')}: ${last.name}',
                onTap: () => HomeScreen.openPlayer(context, last),
              ),
            _HeaderButton(
              icon: Icons.sync,
              label: s.t('update'),
              busy: app.updating,
              onTap: app.updating
                  ? null
                  : () async {
                      await app.update(force: true);
                      if (context.mounted && app.updateMessage != null) showSnack(context, app.updateMessage!);
                    },
            ),
            _HeaderButton(
              icon: Icons.settings,
              label: s.t('settings'),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
            ),
            _NetChip(online: app.online, vpn: app.vpnActive, s: s),
            const _Clock(),
          ],
        ),
      ],
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.icon, required this.label, this.onTap, this.busy = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => FocusTile(
        onTap: onTap,
        radius: 8,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          busy
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent))
              : Icon(icon, size: 18, color: AppColors.text),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: AppColors.text, fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _NetChip extends StatelessWidget {
  const _NetChip({required this.online, required this.vpn, required this.s});
  final bool online;
  final bool vpn;
  final S s;

  @override
  Widget build(BuildContext context) {
    final c = online ? const Color(0xFF2ECC71) : const Color(0xFFE74C3C);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(online ? Icons.wifi : Icons.wifi_off, color: c, size: 18),
      const SizedBox(width: 4),
      Text(online ? s.t('online') : s.t('offline'), style: TextStyle(color: c, fontSize: 12)),
      if (vpn) ...[
        const SizedBox(width: 8),
        const Icon(Icons.vpn_lock, color: AppColors.accent, size: 16),
        const SizedBox(width: 2),
        Text(s.t('vpn_on'), style: const TextStyle(color: AppColors.accent, fontSize: 12)),
      ],
    ]);
  }
}

class _Clock extends StatefulWidget {
  const _Clock();
  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  Timer? _t;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 15), (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    return Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
      Text(hhmm(_now), style: const TextStyle(color: AppColors.text, fontSize: 22, fontWeight: FontWeight.w700)),
      Text(s.date(_now), style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
    ]);
  }
}

class _CountryBar extends StatelessWidget {
  const _CountryBar();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final b = app.bundle;
    if (b == null) return const SizedBox.shrink();
    final items = <(String, String)>[
      for (final c in b.countries) (c.code, c.name(app.lang)),
      (kFavouritesTab, '★ ${app.s.t('favourites')}'),
    ];
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final (code, name) = items[i];
          final sel = app.selectedCountry == code;
          return FocusTile(
            selected: sel,
            color: sel ? AppColors.accent.withValues(alpha: 0.18) : AppColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            onTap: () => app.selectCountry(code),
            child: Text(name,
                style: TextStyle(
                    color: sel ? AppColors.accent : AppColors.text, fontSize: 15, fontWeight: FontWeight.w700)),
          );
        },
      ),
    );
  }
}

class _CategoryBar extends StatelessWidget {
  const _CategoryBar();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final cats = app.bundle?.categories ?? const <Category>[];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: cats.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final c = cats[i];
            final sel = app.selectedCategory == c.id;
            return FocusTile(
              selected: sel,
              radius: 19,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              onTap: () => app.selectCategory(c.id),
              child: Text(c.name(app.lang),
                  style: TextStyle(color: sel ? AppColors.accent : AppColors.textDim, fontSize: 13)),
            );
          },
        ),
      ),
    );
  }
}

class _ChannelGrid extends StatelessWidget {
  const _ChannelGrid();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final list = app.visibleChannels;
    if (list.isEmpty) {
      return Center(
        child: Text(app.selectedCountry == kFavouritesTab ? app.s.t('no_favourites') : app.s.t('no_channels'),
            style: const TextStyle(color: AppColors.textDim)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.only(top: 6, bottom: 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 210, mainAxisSpacing: 14, crossAxisSpacing: 14, childAspectRatio: 1.15),
      itemCount: list.length,
      itemBuilder: (_, i) => ChannelCard(channel: list[i], autofocus: i == 0),
    );
  }
}

class ChannelCard extends StatelessWidget {
  const ChannelCard({super.key, required this.channel, this.autofocus = false});
  final Channel channel;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final st = app.statusOf(channel);
    final country = app.bundle?.country(channel.countryCode)?.name(app.lang) ?? channel.countryCode;
    final fav = app.store.isFavourite(channel.id);
    return FocusTile(
      key: ValueKey('card_${channel.id}'),
      autofocus: autofocus,
      semanticLabel: channel.name,
      padding: const EdgeInsets.all(10),
      onTap: () => HomeScreen.openPlayer(context, channel),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(clipBehavior: Clip.none, children: [
            ChannelLogo(channel, size: 56),
            if (fav) const Positioned(right: -10, top: -8, child: Icon(Icons.star, color: AppColors.accent, size: 18)),
          ]),
          const SizedBox(height: 8),
          Text(channel.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w700)),
          Text('$country · ${channel.provider}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            StatusBadge(st, compact: true),
            if (!channel.hasDirectStream) ...[
              const SizedBox(width: 4),
              const Icon(Icons.open_in_new, size: 13, color: AppColors.textDim),
            ],
          ]),
        ],
      ),
    );
  }
}
