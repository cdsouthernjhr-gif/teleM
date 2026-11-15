# Seni bina

```
 GitHub (raw)            Peranti Android (API 23+)
 database/*.json  ──►  DatabaseRepository ──► SchemaValidator ──► cache (fail atomik)
                              │                                    │
                              ▼                                    ▼
                         AppState (ChangeNotifier) ◄── LocalStore (kegemaran, sejarah, tetapan, status)
                              │
        ┌─────────────────────┼─────────────────────────────┐
        ▼                     ▼                             ▼
   HomeScreen            PlayerScreen                 SettingsScreen
   (negara, kategori,     PlaybackController ──► MediaBackend (VideoPlayerBackend → Media3 ExoPlayer)
    grid saluran)          │  RecoveryPolicy (retry terhad, backoff)
                           │  buildSources (utama → sekunder, lulus UrlPolicy)
                           │  StreamHealthChecker (diagnosis sekali selepas semua gagal)
                           └► findAlternatives + BUKA PLATFORM RASMI
```

## Pemain dan pemulihan sambungan

- `package:video_player` 2.10 menggunakan `video_player_android` 2.8.15, iaitu **AndroidX Media3 ExoPlayer 1.5.1** (HLS, DASH, MP4). minSdk perpustakaan ialah 21, jadi serasi dengan API 23.
- Hanya satu `VideoPlayerController` hidup pada satu masa, sesuai untuk TV Box 2 GB.
- `PlaybackController` mengikut langkah ini:
  1. Buka sumber utama.
  2. Jika berlaku ralat, buffering melebihi `stall_timeout_seconds`, atau stream "tamat", cuba semula sumber yang sama sehingga `max_retries_per_source` kali dengan backoff 2 s, 4 s … (maks 15 s).
  3. Kemudian beralih ke sumber sekunder dengan had yang sama.
  4. Jika semua gagal, jalankan **satu** semakan kesihatan untuk mengenal pasti punca, kemudian paparkan panel kegagalan: status, sebab, negara anda, negara yang dibenarkan, CUBA LAGI, BUKA PLATFORM RASMI dan senarai alternatif.
- Ralat kekal (401/410/451) tidak dicuba semula pada URL yang sama.
- Tukar saluran membatalkan semua cubaan semula yang masih menunggu (kiraan generasi).

## Geo-restriction

- `GeoService` menggunakan endpoint dalam `app_config.json` (lalai: Cloudflare `/cdn-cgi/trace`, kemudian ipapi.co). **Hanya kod negara disimpan**; alamat IP tidak disimpan atau direkodkan dalam log.
- Pengguna boleh mematikan ciri ini dalam Tetapan.
- Status GEO_RESTRICTED ditetapkan apabila penyedia membalas HTTP 451, menghantar mesej geo, atau membalas 403 ketika negara pengguna tiada dalam `geo_allowed`.

## VPN

- Aplikasi **tidak** melaksanakan `VpnService`, tidak mempunyai pelayan VPN atau proksi, dan tidak menyimpan kelayakan VPN.
- Ia hanya mengesan sama ada VPN aktif (`NetworkCapabilities.TRANSPORT_VPN`, API 23) dan memaparkannya kepada pengguna, kerana VPN mempengaruhi pengesanan negara.
- Butang **BUKA TETAPAN VPN ANDROID** membuka `Settings.ACTION_VPN_SETTINGS`. Pengguna sendiri memilih dan memberi kebenaran kepada aplikasi VPN sah mereka melalui dialog sistem Android.
- Tetapan memaparkan amaran bahawa VPN tidak boleh digunakan untuk memintas sekatan wilayah, DRM atau langganan.
- Reka bentuk ini dipilih kerana membina VPN dalam aplikasi untuk menonton kandungan geo-blocked bercanggah dengan keperluan keselamatan §4B dan §12.

## Keselamatan

- `network_security_config.xml` membenarkan **HTTPS sahaja**.
- Root ISRG X1/X2 (Let's Encrypt) **ditambah** pada stor sistem, kerana Android 6.0 tidak mempunyainya. Ini dilakukan untuk ExoPlayer (melalui NSC) dan untuk HTTP Dart (melalui `SecurityContext`). Pengesahan sijil tidak pernah dimatikan.
- `UrlPolicy` menolak URL yang bukan https, mempunyai kelayakan dalam URL, atau domainnya tiada dalam senarai dibenarkan, sebelum URL itu dimainkan atau dibuka.
- Kandungan pangkalan data dari GitHub disahkan sepenuhnya sebelum digunakan. Saiz setiap fail dihadkan kepada 2 MB.
- Log diagnostik menapis token, parameter tandatangan dan alamat IPv4/IPv6. URL dilog dalam bentuk `https://host/…/fail?<redacted>`.
- `allowBackup=false`. Tiada kelayakan disimpan di mana-mana.

## Prestasi (TV Box 2 GB)

- Cache imej dihadkan kepada 150 imej / 24 MB, dan logo dinyahkod pada saiz kecil (`cacheWidth`).
- Satu pemain sahaja pada satu masa. Pemain dilepaskan apabila skrin ditutup.
- Rangkaian disemak dengan carian DNS setiap 20 saat; tiada polling berat.
- Pemeriksa kesihatan dijalankan hanya atas permintaan pengguna, dengan maksimum 2 sambungan serentak.
