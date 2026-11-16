// Bahasa Melayu (default) and English UI strings.

import '../data/models.dart';

class S {
  S(this.lang);
  final String lang;

  static const _t = <String, Map<String, String>>{
    'app_name': {'ms': 'MY ASEAN TV', 'en': 'MY ASEAN TV'},
    'online': {'ms': 'Dalam talian', 'en': 'Online'},
    'offline': {'ms': 'Luar talian', 'en': 'Offline'},
    'vpn_on': {'ms': 'VPN aktif', 'en': 'VPN active'},
    'favourites': {'ms': 'Kegemaran', 'en': 'Favourites'},
    'history': {'ms': 'Sejarah', 'en': 'History'},
    'settings': {'ms': 'Tetapan', 'en': 'Settings'},
    'last_channel': {'ms': 'Saluran terakhir', 'en': 'Last channel'},
    'update': {'ms': 'KEMAS KINI', 'en': 'UPDATE'},
    'manual_update': {'ms': 'KEMAS KINI MANUAL', 'en': 'MANUAL UPDATE'},
    'updating': {'ms': 'Menyemak kemas kini…', 'en': 'Checking for updates…'},
    'up_to_date': {'ms': 'Pangkalan data terkini', 'en': 'Database is up to date'},
    'updated_to': {'ms': 'Dikemas kini ke versi', 'en': 'Updated to version'},
    'update_failed': {
      'ms': 'Kemas kini gagal – cache lama dikekalkan',
      'en': 'Update failed – previous cache kept'
    },
    'update_invalid': {
      'ms': 'Data dari GitHub tidak sah – cache lama dikekalkan',
      'en': 'Data from GitHub is invalid – previous cache kept'
    },
    'app_too_old': {
      'ms': 'Pangkalan data baharu memerlukan versi aplikasi yang lebih baharu',
      'en': 'The new database needs a newer app version'
    },
    'extra_assets': {'ms': 'Aset tambahan', 'en': 'Extra assets'},
    'extra_assets_desc': {
      'ms': 'Fail tambahan (audio, gambar, video, pangkalan data) dimuat turun dari GitHub Releases dan disahkan dengan SHA-256.',
      'en': 'Extra files (audio, images, video, databases) downloaded from GitHub Releases and verified with SHA-256.'
    },
    'extra_assets_open': {'ms': 'URUS ASET', 'en': 'MANAGE ASSETS'},
    'source_remote': {'ms': 'GitHub (terkini)', 'en': 'GitHub (latest)'},
    'source_cache': {'ms': 'Cache luar talian', 'en': 'Offline cache'},
    'source_bundled': {'ms': 'Data terbina dalam APK', 'en': 'Built-in data'},
    'offline_banner': {
      'ms': 'Tiada sambungan internet. Memaparkan senarai saluran dari cache.',
      'en': 'No internet connection. Showing cached channel list.'
    },
    'no_channels': {'ms': 'Tiada saluran dalam kategori ini', 'en': 'No channels in this category'},
    'no_favourites': {
      'ms': 'Belum ada kegemaran. Tekan ★ dalam pemain untuk menambah.',
      'en': 'No favourites yet. Press ★ in the player to add one.'
    },
    'connecting': {'ms': 'Menyambung…', 'en': 'Connecting…'},
    'buffering': {'ms': 'Menimbal…', 'en': 'Buffering…'},
    'reconnecting': {'ms': 'Menyambung semula', 'en': 'Reconnecting'},
    'attempt': {'ms': 'cubaan', 'en': 'attempt'},
    'cannot_play': {'ms': 'Saluran tidak dapat dimainkan', 'en': 'This channel cannot be played'},
    'retry': {'ms': 'CUBA LAGI', 'en': 'RETRY'},
    'open_official': {'ms': 'BUKA PLATFORM RASMI', 'en': 'OPEN OFFICIAL PLATFORM'},
    'open_failed': {
      'ms': 'Tiada pelayar/aplikasi untuk membuka pautan ini pada peranti ini.',
      'en': 'No browser/app on this device can open this link.'
    },
    'alternatives': {'ms': 'Alternatif rasmi', 'en': 'Official alternatives'},
    'no_alternatives': {'ms': 'Tiada alternatif yang disahkan', 'en': 'No verified alternative'},
    'channels': {'ms': 'Saluran', 'en': 'Channels'},
    'epg': {'ms': 'Jadual Rancangan', 'en': 'Programme Guide'},
    'no_epg': {'ms': 'Tiada data EPG untuk saluran ini', 'en': 'No EPG data for this channel'},
    'now': {'ms': 'Kini', 'en': 'Now'},
    'next': {'ms': 'Seterusnya', 'en': 'Next'},
    'back': {'ms': 'Kembali', 'en': 'Back'},
    'language': {'ms': 'Bahasa', 'en': 'Language'},
    'database': {'ms': 'Pangkalan data', 'en': 'Database'},
    'version': {'ms': 'Versi', 'en': 'Version'},
    'source': {'ms': 'Sumber', 'en': 'Source'},
    'last_check': {'ms': 'Semakan terakhir', 'en': 'Last check'},
    'geo': {'ms': 'Pengesanan lokasi rangkaian', 'en': 'Network location detection'},
    'geo_desc': {
      'ms': 'Mengenal pasti negara anda berdasarkan IP (hanya kod negara disimpan) untuk menerangkan sekatan wilayah.',
      'en': 'Detects your country from your IP (only the country code is stored) to explain regional restrictions.'
    },
    'geo_detect_now': {'ms': 'KESAN SEKARANG', 'en': 'DETECT NOW'},
    'country_now': {'ms': 'Negara semasa', 'en': 'Current country'},
    'unknown': {'ms': 'Tidak diketahui', 'en': 'Unknown'},
    'vpn': {'ms': 'VPN', 'en': 'VPN'},
    'vpn_desc': {
      'ms': 'MY ASEAN TV tidak menyediakan atau mengaktifkan VPN. Anda boleh menguruskan aplikasi VPN sah anda sendiri '
          'dalam tetapan Android. Patuhi syarat penyiar: VPN tidak boleh digunakan untuk memintas sekatan wilayah, '
          'DRM atau langganan.',
      'en': 'MY ASEAN TV does not provide or enable any VPN. You can manage your own legitimate VPN app in Android '
          'settings. Respect broadcaster terms: a VPN must not be used to bypass regional restrictions, DRM or '
          'subscriptions.'
    },
    'vpn_status_on': {'ms': 'VPN sedang aktif pada peranti ini', 'en': 'A VPN is active on this device'},
    'vpn_status_off': {'ms': 'Tiada VPN aktif', 'en': 'No VPN active'},
    'vpn_open': {'ms': 'BUKA TETAPAN VPN ANDROID', 'en': 'OPEN ANDROID VPN SETTINGS'},
    'vpn_open_failed': {
      'ms': 'Tetapan VPN tidak tersedia pada peranti ini.',
      'en': 'VPN settings are not available on this device.'
    },
    'health': {'ms': 'Pemeriksa kesihatan stream', 'en': 'Stream health checker'},
    'health_desc': {
      'ms': 'Menguji setiap URL stream (playlist + segmen pertama) dari rangkaian anda. Had 2 sambungan serentak.',
      'en': 'Tests every stream URL (playlist + first segment) from your network. Max 2 concurrent connections.'
    },
    'test_player': {'ms': 'UJI PEMAIN HLS', 'en': 'TEST HLS PLAYER'},
    'health_run': {'ms': 'UJI SEMUA STREAM', 'en': 'TEST ALL STREAMS'},
    'health_running': {'ms': 'Menguji…', 'en': 'Testing…'},
    'diagnostics': {'ms': 'Log diagnostik', 'en': 'Diagnostic log'},
    'diag_desc': {
      'ms': 'Log tidak mengandungi token, alamat IP atau kata laluan.',
      'en': 'The log contains no tokens, IP addresses or passwords.'
    },
    'clear': {'ms': 'KOSONGKAN', 'en': 'CLEAR'},
    'clear_history': {'ms': 'KOSONGKAN SEJARAH', 'en': 'CLEAR HISTORY'},
    'about': {'ms': 'Perihal', 'en': 'About'},
    'about_text': {
      'ms': 'Aplikasi ini hanya memainkan stream percuma yang disenaraikan dalam pangkalan data dan dihoskan oleh '
          'penyiar. Tiada DRM dipintas, tiada akaun berbayar digunakan. Status stream hanya "ONLINE" selepas diuji.',
      'en': 'This app only plays free streams listed in the database and hosted by the broadcasters. No DRM is '
          'bypassed and no paid accounts are used. A stream is only "ONLINE" after it has been tested.'
    },
    'reason_no_direct_stream': {
      'ms': 'Tiada stream terus yang disahkan untuk saluran ini. Tonton melalui platform rasmi penyiar.',
      'en': 'There is no verified direct stream for this channel. Watch it on the broadcaster\'s official platform.'
    },
    'reason_rejected_by_url_policy': {
      'ms': 'URL stream ditolak oleh polisi keselamatan (bukan HTTPS atau domain tidak disahkan).',
      'en': 'The stream URL was rejected by the security policy (not HTTPS or domain not verified).'
    },
    'reason_geo_restricted': {
      'ms': 'Kandungan ini tidak tersedia di negara anda mengikut syarat penyiar.',
      'en': 'This content is not available in your country under the broadcaster\'s terms.'
    },
    'reason_auth_required': {
      'ms': 'Penyiar memerlukan log masuk/langganan. MY ASEAN TV tidak menggunakan akaun pengguna.',
      'en': 'The broadcaster requires sign-in/subscription. MY ASEAN TV does not use user accounts.'
    },
    'reason_expired': {
      'ms': 'Pautan stream telah tamat tempoh. Pentadbir perlu mengemas kini pangkalan data.',
      'en': 'The stream link has expired. The administrator needs to update the database.'
    },
    'reason_offline': {
      'ms': 'Stream sedang luar talian atau pelayan penyiar tidak bertindak balas.',
      'en': 'The stream is offline or the broadcaster\'s server is not responding.'
    },
    'reason_timeout': {
      'ms': 'Sambungan tamat masa. Periksa internet anda dan cuba lagi.',
      'en': 'The connection timed out. Check your internet and try again.'
    },
    'reason_unknown': {
      'ms': 'Stream tidak dapat dimainkan atas sebab yang tidak diketahui. Lihat log diagnostik.',
      'en': 'The stream could not be played for an unknown reason. See the diagnostic log.'
    },
    'your_country': {'ms': 'Negara anda', 'en': 'Your country'},
    'allowed_in': {'ms': 'Dibenarkan di', 'en': 'Allowed in'},
    'play_pause': {'ms': 'Main/Jeda', 'en': 'Play/Pause'},
    'mute': {'ms': 'Senyap', 'en': 'Mute'},
    'fullscreen': {'ms': 'Skrin penuh', 'en': 'Fullscreen'},
    'add_fav': {'ms': 'Tambah kegemaran', 'en': 'Add favourite'},
    'remove_fav': {'ms': 'Buang kegemaran', 'en': 'Remove favourite'},
    'remote_hint': {
      'ms': '▲▼ tukar saluran · ◀ senarai · OK kawalan · BACK keluar',
      'en': '▲▼ change channel · ◀ list · OK controls · BACK exit'
    },
    'status_online': {'ms': 'ONLINE', 'en': 'ONLINE'},
  };

  String t(String key) => _t[key]?[lang] ?? _t[key]?['ms'] ?? key;

  String status(StreamStatus s) => s.label;

  String reason(StreamStatus s, String detail) {
    if (detail == 'no_direct_stream') return t('reason_no_direct_stream');
    if (detail.startsWith('rejected_by')) return t('reason_rejected_by_url_policy');
    return t('reason_${s.json}');
  }

  String weekday(DateTime d) {
    const ms = ['Isnin', 'Selasa', 'Rabu', 'Khamis', 'Jumaat', 'Sabtu', 'Ahad'];
    const en = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return (lang == 'en' ? en : ms)[d.weekday - 1];
  }

  String month(DateTime d) {
    const ms = ['Jan', 'Feb', 'Mac', 'Apr', 'Mei', 'Jun', 'Jul', 'Ogo', 'Sep', 'Okt', 'Nov', 'Dis'];
    const en = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return (lang == 'en' ? en : ms)[d.month - 1];
  }

  String date(DateTime d) => '${weekday(d)}, ${d.day} ${month(d)} ${d.year}';
}

String two(int n) => n.toString().padLeft(2, '0');
String hhmm(DateTime d) => '${two(d.hour)}:${two(d.minute)}';
