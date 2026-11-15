# Mengurus pangkalan data GitHub

Aplikasi membaca lima fail daripada:

```
https://raw.githubusercontent.com/cdsouthernjhr-gif/teleM/main/database/
```

URL ini ditetapkan dalam `lib/core/constants.dart`. Ia boleh ditukar semasa binaan dengan `--dart-define=DB_BASE_URL=...`.

**Repository mesti awam** supaya `raw.githubusercontent.com` boleh dibaca tanpa token. Jangan sekali-kali letak token atau kata laluan dalam repository ini.

## Bagaimana kemas kini berfungsi

1. Semasa aplikasi dibuka, ia memuatkan cache tempatan. Jika tiada cache, ia memuatkan salinan yang terbina dalam APK.
2. Ia memuat turun `app_config.json` dan membandingkan `database_version` dengan versi semasa.
3. Jika versi lebih tinggi, keempat-empat fail lain dimuat turun.
4. Kesemua fail disahkan oleh `SchemaValidator`, iaitu pengesah yang sama dengan `tool/validate_db.dart`.
5. Jika sah, cache baharu disimpan secara atomik.
6. Jika muat turun atau pengesahan gagal, **cache lama dikekalkan**.

Butang **KEMAS KINI** (skrin utama) dan **KEMAS KINI MANUAL** (Tetapan) memaksa muat turun penuh walaupun nombor versi sama.

GitHub CDN mungkin menyimpan salinan lama sehingga ~5 minit selepas commit.

## Peraturan wajib setiap perubahan

1. Naikkan `database_version` dalam `app_config.json`.
2. Gunakan **nombor yang sama** untuk `version` dalam `channels.json`. Pengesah akan menolak jika kedua-duanya berbeza.
3. Kemas kini `updated_at`.
4. Jalankan `dart run tool/validate_db.dart`. Workflow `database.yml` juga menjalankannya secara automatik.

## Medan saluran (`channels.json`)

| Medan | Wajib | Keterangan |
|---|---|---|
| `id` | ✔ | Unik. Format `<kod negara>_<nama>`, contoh `my_tv1`. **Jangan tukar** ID yang sedia ada kerana kegemaran dan sejarah pengguna merujuknya. |
| `name` | ✔ | Nama paparan |
| `provider` | | Penyiar, contoh RTM |
| `type` | | `FTA` atau `Digital` |
| `category` | ✔ | ID daripada `categories.json`: `general`, `news`, `entertainment`, `sports`, `education`, `kids`, `islamic`, `documentary` |
| `logo` | | Laluan relatif dalam repo, contoh `logos/malaysia/tv1.png`. Kosong bermaksud monogram dipaparkan. |
| `stream_type` | ✔ | `hls`, `dash`, `mp4` (boleh dimainkan dalam aplikasi), `web`, `platform` atau `none` |
| `stream_url` | | URL stream utama. **HTTPS sahaja** dan domainnya mesti ada dalam `allowed_stream_domains`. |
| `secondary_url` | | URL sandaran yang disahkan secara berasingan |
| `official_url` | ✔* | Laman/platform rasmi (dibuka di pelayar). Domainnya mesti ada dalam `allowed_official_domains`. |
| `official_platform` | | Nama platform, contoh `RTMKlik` |
| `availability` | ✔ | `online`, `offline`, `geo_restricted`, `auth_required`, `expired`, `timeout` atau `unknown`. **`online` memerlukan `last_checked` dan URL stream.** |
| `last_checked` | | Tarikh ujian terakhir `YYYY-MM-DD`, atau `null` |
| `enabled` | ✔ | `false` menyembunyikan saluran tanpa memadamnya |
| `geo_allowed` | | Negara yang dibenarkan penyiar, contoh `["MY"]` |
| `alternatives` | | ID saluran alternatif mengikut keutamaan |
| `epg_id` | | Kunci dalam `epg.json` (lalai: `id`) |
| `verification`, `notes` | | Catatan cara pengesahan dilakukan |

## Operasi biasa

**Tambah saluran:** salin satu objek saluran ke senarai negara yang betul, beri `id` baharu, isi medan, kemudian naikkan versi.

**Padam saluran:** buang objeknya. Jika saluran itu disenaraikan dalam `alternatives` saluran lain, buang rujukan tersebut juga; pengesah akan menolak rujukan yang tergantung.

**Nyahaktif:** tetapkan `"enabled": false`.

**Tukar URL stream:** kemas kini `stream_url` dan `secondary_url`. Jika domain baharu, tambah domain itu dalam `allowed_stream_domains` (`app_config.json`). Ikut [STREAM_VERIFICATION.md](STREAM_VERIFICATION.md).

**Tukar logo:** letak PNG (≤300 KB, disyorkan 256×256, latar telus) dalam `logos/<negara>/`, kemudian kemas kini `logo`. Gunakan hanya logo yang anda dibenarkan gunakan.

**Tukar kategori:** tukar `category`. Untuk kategori baharu, tambah dahulu dalam `categories.json`.

## EPG (`epg.json`)

```json
{
  "version": 2,
  "updated_at": "2026-11-20",
  "programs": {
    "my_tv1": [
      {"start": "2026-11-20T20:00:00+08:00", "end": "2026-11-20T20:30:00+08:00",
       "title": "Berita Perdana", "description": "..."}
    ]
  }
}
```

Masa mesti ISO-8601 dengan zon waktu, dan `start` mesti lebih awal daripada `end`. Gunakan hanya data EPG yang anda berhak terbitkan semula.

## `app_config.json`

- `database_version`: nombor versi pangkalan data.
- `min_app_build`: binaan aplikasi minimum. Jika aplikasi lebih lama, kemas kini pangkalan data tidak digunakan.
- `allowed_stream_domains`: senarai domain yang dibenarkan untuk stream. Subdomain turut dibenarkan.
- `allowed_official_domains`: senarai domain yang dibenarkan untuk butang platform rasmi.
- `test_stream`: stream ujian HLS awam (contoh rasmi Apple) untuk butang **UJI PEMAIN HLS** dalam Tetapan.
- `geo.endpoints`: perkhidmatan pengesanan negara. Hanya kod negara yang disimpan.
- `health`: `timeout_seconds` dan `max_concurrency`.
- `playback`: `max_retries_per_source`, `retry_base_seconds` dan `stall_timeout_seconds`.
- `announcement`: mesej yang dipaparkan di skrin utama (`ms` / `en`).
