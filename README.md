# MY ASEAN TV

Aplikasi TV percuma Flutter untuk **Android TV Box, telefon dan tablet Android**. Ia menghimpunkan saluran Free-to-Air (FTA) dan TV Digital dari **Malaysia, Indonesia, Singapura dan Brunei**.

- **Android 6.0 (API 23)** ialah versi minimum (`minSdk 23`, Flutter 3.32.8, Media3 ExoPlayer 1.5.1).
- Navigasi menggunakan **remote D-pad**. UI gelap, landskap dan sesuai untuk TV. Antara muka dalam **Bahasa Melayu dan English**.
- Senarai saluran ialah **pangkalan data JSON di GitHub** (`database/`). Anda boleh mengemas kininya tanpa membina APK baharu.
- Aplikasi tidak memintas DRM, tidak menggunakan akaun berbayar dan tidak mengaktifkan VPN sendiri. Ia juga tidak mereka URL stream palsu.

> **Status stream (pangkalan data v2, 15 Nov 2026):** 9 saluran mempunyai stream terus yang telah diuji ONLINE: TV1, TV2, TV Okey, Berita RTM, TVRI Nasional, TVRI World, TVRI Daerah (Jakarta), Metro TV dan CNA.
> RTB Sukmaindera mempunyai URL, tetapi ia membalas HTTP 403 di luar Brunei.
> Saluran lain hanya mempunyai pautan **BUKA PLATFORM RASMI**.
> Langkah menambah URL baharu ada dalam [documentation/STREAM_VERIFICATION.md](documentation/STREAM_VERIFICATION.md).

## Struktur repository

```
├── lib/                     Kod Flutter
│   ├── core/                polisi URL, rentetan BM/EN, log diagnostik, jambatan Android, klien HTTPS
│   ├── data/                model, pengesah skema JSON, repositori GitHub + cache, storan tempatan
│   ├── services/            pemeriksa kesihatan stream, geo, pengawal main semula (auto-reconnect), logo cache
│   ├── state/               AppState
│   └── ui/                  skrin Utama, Pemain, Tetapan
├── android/                 Projek Android (minSdk 23, Leanback, network security config)
├── database/                channels.json, countries.json, categories.json, epg.json, app_config.json
├── logos/                   malaysia/ indonesia/ singapore/ brunei/
├── assets/certs/            Root CA ISRG (Let's Encrypt) untuk Android 6.0
├── tool/                    validate_db.dart, health_check.dart
├── test/                    ujian unit + widget
├── documentation/           panduan
├── build.ps1                skrip binaan PowerShell (Windows)
└── .github/workflows/       build.yml (APK), database.yml (pengesahan JSON)
```

## Bina dengan cepat

```bash
flutter pub get
```

```bash
flutter test
```

```bash
flutter build apk --release
```

Di Windows: `powershell -ExecutionPolicy Bypass -File .\build.ps1` menghasilkan `dist\MY_ASEAN_TV.apk`.

GitHub Actions membina `MY_ASEAN_TV.apk` pada setiap push dan memuat naiknya sebagai artifact.

## Dokumentasi

| Dokumen | Isi |
|---|---|
| [documentation/INSTALL.md](documentation/INSTALL.md) | Pemasangan, binaan, pemasangan pada TV Box, tandatangan release |
| [documentation/DATABASE.md](documentation/DATABASE.md) | Cara mengurus pangkalan data GitHub (tambah/padam/kemas kini saluran) |
| [documentation/STREAM_VERIFICATION.md](documentation/STREAM_VERIFICATION.md) | Cara mengesahkan dan menambah URL stream secara sah |
| [documentation/ARCHITECTURE.md](documentation/ARCHITECTURE.md) | Seni bina, aliran main semula, geo, VPN, keselamatan |
| [documentation/SOURCES.md](documentation/SOURCES.md) | Senarai sumber/platform rasmi bagi setiap saluran |
| [documentation/TEST_REPORT.md](documentation/TEST_REPORT.md) | Apa yang telah diuji dan apa yang BELUM |
