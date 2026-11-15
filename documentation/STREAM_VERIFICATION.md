# Mengesahkan dan menambah URL stream

Prinsip: **jangan reka URL**, **jangan anggap HTTP 200 = berfungsi**, **jangan pintas DRM, token atau sekatan wilayah**.

## Kenapa pangkalan data awal tidak mempunyai URL stream

Pangkalan data awal dibina dalam container awan **di luar Malaysia**, dan rangkaiannya menyekat semua hos penyiar (rtm.gov.my, tonton.com.my, tvri.go.id, mewatch.sg, rtbgo.bn dan lain-lain). Tiada satu pun URL boleh diuji dari situ. Oleh itu setiap saluran dihantar dengan `stream_url: ""` dan `availability: "unknown"`, dan aplikasi memaparkan **BUKA PLATFORM RASMI** untuk saluran tersebut.

## Syarat sebelum URL boleh dimasukkan

1. **Sumber rasmi.** URL mesti diterbitkan atau dihoskan oleh penyiar itu sendiri (domain atau CDN rasmi penyiar), atau oleh rakan rasmi yang mengedarkannya secara terbuka.
2. **Dibenarkan.** Semak terma penggunaan penyiar. Sesetengah penyiar hanya membenarkan tontonan melalui pemain mereka sendiri. Jika tidak pasti, minta kebenaran bertulis. Jika tiada kebenaran, gunakan `official_url` sahaja.
3. **Tiada token sesi.** Jangan salin URL yang mengandungi token, tandatangan atau masa tamat (`token=`, `hdnts=`, `expires=`, `sig=` ...). URL begitu akan tamat tempoh dan mengambilnya daripada pemain web dikira sebagai pengekstrakan token.
4. **Tiada DRM.** Stream yang dilindungi Widevine atau DRM lain tidak dimasukkan.
5. **HTTPS sahaja.**

## Langkah pengesahan (dari Malaysia)

```bash
git pull
```

1. Tambah domain dalam `allowed_stream_domains` (`app_config.json`).
2. Isi `stream_type: "hls"` dan `stream_url` untuk saluran itu. Biarkan `availability: "unknown"`.
3. Jalankan pemeriksa dari rangkaian Malaysia:

```bash
dart run tool/health_check.dart --country MY --json report.json
```

   Pemeriksa membuat paling banyak 3 permintaan kecil bagi setiap URL: playlist, varian dan 2 KB segmen pertama. Ia menggunakan had 2 sambungan serentak dan jeda antara permintaan.
4. Hanya hasil **ONLINE** menunjukkan playlist dan segmen pertama boleh diambil. Selepas itu, uji main semula sebenar dalam aplikasi pada peranti, termasuk TV Box Android 6.0.
5. Untuk menulis status ke `channels.json`:

```bash
dart run tool/health_check.dart --country MY --write
```

6. Naikkan `database_version` dan `channels.version`, jalankan `dart run tool/validate_db.dart`, kemudian commit.

## Maksud status

| Status | Maksud |
|---|---|
| ONLINE | Playlist sah dan segmen pertama dijawab (200/206) |
| OFFLINE | 404/5xx, ralat rangkaian/TLS, atau playlist tanpa segmen |
| GEO_RESTRICTED | HTTP 451, mesej geo daripada penyedia, atau 403 apabila negara pengguna tiada dalam `geo_allowed` |
| AUTH_REQUIRED | HTTP 401: penyiar memerlukan log masuk. Aplikasi tidak menggunakan akaun. |
| EXPIRED | HTTP 410, atau 403 pada URL bertoken/bertandatangan |
| TIMEOUT | Tiada jawapan dalam `timeout_seconds` |
| UNKNOWN | Belum diuji, 403 tanpa petunjuk, 429, atau kandungan bukan playlist |

Hasil ujian bergantung kepada lokasi. GitHub Actions berjalan di AS/EU, jadi stream yang hanya untuk MY akan dilaporkan GEO_RESTRICTED di sana. Itu bukan tanda stream rosak.
