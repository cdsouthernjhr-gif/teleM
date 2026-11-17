import 'package:flutter/material.dart';

import '../../core/diagnostics.dart';
import '../../core/strings.dart';
import '../../data/models.dart';
import '../home/home_screen.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final b = app.bundle;
    final lastCheck = app.store.lastUpdateCheck;

    Widget section(String title, List<Widget> children, {String? desc}) => Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(color: AppColors.accent, fontSize: 16, fontWeight: FontWeight.w800)),
            if (desc != null) ...[
              const SizedBox(height: 4),
              Text(desc, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
            ],
            const SizedBox(height: 10),
            ...children,
          ]),
        );

    Widget button(String label, VoidCallback? onTap, {Key? key, bool busy = false, bool autofocus = false}) =>
        Padding(
          padding: const EdgeInsets.only(right: 10, top: 4),
          child: FocusTile(
            key: key,
            autofocus: autofocus,
            color: AppColors.surfaceHi,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            onTap: onTap,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (busy) ...[
                const SizedBox(
                    width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent)),
                const SizedBox(width: 8),
              ],
              Text(label, style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w700)),
            ]),
          ),
        );

    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text('$k: $v', style: const TextStyle(color: AppColors.text, fontSize: 13)),
        );

    final log = diag.entries.reversed.take(60).toList();

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.text,
        title: Text(s.t('settings')),
      ),
      body: FocusTraversalGroup(
        child: ListView(padding: const EdgeInsets.fromLTRB(24, 8, 24, 32), children: [
          section(s.t('language'), [
            Wrap(children: [
              button('Bahasa Melayu${app.lang == 'ms' ? ' ✓' : ''}', () => app.setLanguage('ms'), autofocus: true),
              button('English${app.lang == 'en' ? ' ✓' : ''}', () => app.setLanguage('en')),
            ]),
          ]),
          section(s.t('database'), [
            kv(s.t('version'), '${b?.version ?? '-'} (${b?.updatedAt ?? '-'})'),
            kv(s.t('source'), app.sourceLabel()),
            kv(s.t('last_check'), lastCheck == null ? '-' : '${s.date(lastCheck)} ${hhmm(lastCheck)}'),
            if (app.updateMessage != null) kv('Status', app.updateMessage!),
            Wrap(children: [
              button(s.t('manual_update'), app.updating ? null : () => app.update(force: true),
                  key: const ValueKey('btn_manual_update'), busy: app.updating),
            ]),
          ]),
          section(s.t('geo'), desc: s.t('geo_desc'), [
            kv(s.t('country_now'),
                app.geoInfo == null ? s.t('unknown') : '${app.geoInfo!.countryCode} (${app.geoInfo!.source})'),
            Wrap(children: [
              button(app.store.geoEnabled ? 'ON ✓' : 'OFF', () => app.setGeoEnabled(!app.store.geoEnabled)),
              if (app.store.geoEnabled) button(s.t('geo_detect_now'), () => app.detectCountry()),
            ]),
          ]),
          section(s.t('vpn'), desc: s.t('vpn_desc'), [
            kv('Status', app.vpnActive ? s.t('vpn_status_on') : s.t('vpn_status_off')),
            Wrap(children: [
              button(s.t('vpn_open'), () async {
                final ok = await app.bridge.openVpnSettings();
                if (!ok && context.mounted) showSnack(context, s.t('vpn_open_failed'));
              }),
            ]),
          ]),
          section(s.t('health'), desc: s.t('health_desc'), [
            if (app.healthRunning) kv(s.t('health_running'), '${app.healthDone}/${app.healthTotal}'),
            Wrap(children: [
              if (b != null && b.config.testStreamUrl.isNotEmpty)
                button(s.t('test_player'), () {
                  HomeScreen.openPlayer(
                      context,
                      Channel(
                        id: 'xx_test_stream',
                        name: b.config.testStreamName.isEmpty ? 'HLS TEST' : b.config.testStreamName,
                        countryCode: 'XX',
                        provider: 'Test',
                        streamType: StreamType.hls,
                        streamUrl: b.config.testStreamUrl,
                      ));
                }, key: const ValueKey('btn_test_player')),
              button(s.t('health_run'), app.healthRunning ? null : () => app.runHealthCheckAll(),
                  busy: app.healthRunning),
            ]),
            const SizedBox(height: 8),
            for (final c in (b?.channels ?? const []).where((c) => app.health.containsKey(c.id)))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  SizedBox(width: 150, child: Text(c.name, style: const TextStyle(color: AppColors.text, fontSize: 12))),
                  StatusBadge(app.health[c.id]!.status, compact: true),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        '${app.health[c.id]!.detail} · ${hhmm(app.health[c.id]!.checkedAt)}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
                  ),
                ]),
              ),
          ]),
          section(s.t('history'), [
            for (final h in app.store.history.take(10))
              kv(b?.byId(h.channelId)?.name ?? h.channelId, '${s.date(h.at)} ${hhmm(h.at)}'),
            Wrap(children: [
              button(s.t('clear_history'), () async {
                await app.store.clearHistory();
                setState(() {});
              }),
            ]),
          ]),
          section(s.t('diagnostics'), desc: s.t('diag_desc'), [
            Container(
              height: 220,
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Colors.black,
              child: ListView(children: [
                for (final e in log)
                  Text(e.toString(),
                      style: TextStyle(
                          color: e.level == 'E'
                              ? const Color(0xFFE74C3C)
                              : e.level == 'W'
                                  ? AppColors.accent
                                  : AppColors.textDim,
                          fontSize: 11,
                          fontFamily: 'monospace')),
              ]),
            ),
            Wrap(children: [
              button(s.t('clear'), () => setState(diag.clear)),
            ]),
          ]),
          section(s.t('about'), [
            Text(s.t('about_text'), style: const TextStyle(color: AppColors.text, fontSize: 13)),
          ]),
        ]),
      ),
    );
  }
}
