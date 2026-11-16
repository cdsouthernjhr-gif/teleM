// UI text in Malay (default) and English.

class FdamStrings {
  const FdamStrings(this.lang);
  final String lang;
  bool get _en => lang == 'en';
  String _t(String ms, String en) => _en ? en : ms;

  String get setupTitle => _t('Persediaan Aset', 'Asset Setup');
  String get welcome => _t('Selamat datang! Aplikasi memerlukan beberapa fail tambahan sebelum boleh digunakan.',
      'Welcome! The app needs a few extra files before it can be used.');
  String get internet => _t('Internet', 'Internet');
  String get online => _t('Dalam talian', 'Online');
  String get offline => _t('Luar talian', 'Offline');
  String get checking => _t('Menyemak…', 'Checking…');
  String get requiredSize => _t('Saiz muat turun wajib', 'Required download size');
  String get availableStorage => _t('Ruang storan tersedia', 'Available storage');
  String get unknown => _t('Tidak diketahui', 'Unknown');
  String get download => _t('Muat turun', 'Download');
  String get downloadNow => _t('Muat turun sekarang', 'Download now');
  String get skipOptional => _t('Langkau muat turun pilihan', 'Skip optional downloads');
  String get continueApp => _t('Teruskan ke aplikasi', 'Continue to app');
  String get retry => _t('Cuba semula', 'Retry');
  String get pause => _t('Jeda', 'Pause');
  String get resume => _t('Sambung', 'Resume');
  String get cancel => _t('Batal', 'Cancel');
  String get downloadsTitle => _t('Pengurus Muat Turun', 'Download Manager');
  String get overall => _t('Kemajuan keseluruhan', 'Overall progress');
  String get noDownloads => _t('Tiada muat turun.', 'No downloads.');
  String get remaining => _t('baki', 'remaining');
  String get dashboardTitle => _t('Papan Pemuka Aset', 'Asset Dashboard');
  String get totalAssets => _t('Aset dimuat turun', 'Downloaded assets');
  String get storageUsed => _t('Storan digunakan', 'Storage used');
  String get manifestVersion => _t('Versi manifest terkini', 'Latest manifest version');
  String get lastUpdate => _t('Semakan terakhir', 'Last update check');
  String get assetStatus => _t('Status aset', 'Asset status');
  String get settingsTitle => _t('Tetapan Aset', 'Asset Settings');
  String get autoUpdate => _t('Kemas kini automatik', 'Auto update');
  String get autoUpdateDesc =>
      _t('Muat turun versi baharu aset yang sudah dipasang secara automatik.', 'Download new versions of installed assets automatically.');
  String get wifiOnly => _t('Wi-Fi sahaja', 'Wi-Fi only');
  String get wifiOnlyDesc => _t('Jangan guna data mudah alih untuk muat turun.', 'Do not use mobile data for downloads.');
  String get manualUpdate => _t('Kemas kini sekarang', 'Update now');
  String get checkUpdates => _t('Semak kemas kini', 'Check for updates');
  String get clearOptional => _t('Kosongkan cache pilihan', 'Clear optional cache');
  String get storageManagement => _t('Pengurusan storan', 'Storage management');
  String get cleanupRemoved => _t('Buang aset lapuk yang tidak digunakan', 'Remove unused retired assets');
  String get openDownloads => _t('Buka pengurus muat turun', 'Open download manager');
  String get openSettings => _t('Tetapan aset', 'Asset settings');
  String get rollback => _t('Kembali ke versi terdahulu', 'Roll back');
  String get notConfigured => _t('Pengurus aset belum dikonfigurasi (tiada URL manifest).',
      'The asset manager is not configured (no manifest URL).');
  String get startError => _t('Senarai aset tidak dapat dimuatkan.', 'The asset list could not be loaded.');
  String get done => _t('Selesai', 'Done');
  String cleared(int n) => _t('$n aset pilihan dibuang.', '$n optional assets removed.');
  String removedCount(int n) => _t('$n aset lapuk dibuang.', '$n retired assets removed.');
  String get upToDate => _t('Semua aset terkini.', 'All assets are up to date.');
  String updatesAvailable(int n) => _t('$n kemas kini tersedia.', '$n updates available.');
  String get offlineCache => _t('Menggunakan senarai aset tersimpan (luar talian).', 'Using the saved asset list (offline).');
  String get required => _t('Wajib', 'Required');
  String get optional => _t('Pilihan', 'Optional');
  String get startup => _t('Permulaan', 'Startup');

  String status(String s) => switch (s) {
        'installed' => _t('Dipasang', 'Installed'),
        'update' => _t('Kemas kini tersedia', 'Update available'),
        'install' => _t('Belum dimuat turun', 'Not downloaded'),
        'repair' => _t('Perlu dibaiki', 'Needs repair'),
        'removed' => _t('Tiada lagi dalam manifest', 'No longer in manifest'),
        'queued' => _t('Dalam giliran', 'Queued'),
        'waitingForNetwork' => _t('Menunggu rangkaian', 'Waiting for network'),
        'downloading' => _t('Memuat turun', 'Downloading'),
        'paused' => _t('Dijeda', 'Paused'),
        'verifying' => _t('Mengesahkan SHA-256', 'Verifying SHA-256'),
        'extracting' => _t('Mengekstrak', 'Extracting'),
        'installing' => _t('Memasang', 'Installing'),
        'completed' => _t('Selesai', 'Completed'),
        'failed' => _t('Gagal', 'Failed'),
        'cancelled' => _t('Dibatalkan', 'Cancelled'),
        _ => s,
      };
}

String formatBytes(num bytes) {
  if (bytes < 1024) return '${bytes.toInt()} B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

String formatDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}j ${d.inMinutes.remainder(60)}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
  return '${d.inSeconds}s';
}
