# MyFlutterApp-Assets (templat repositori aset FDAM)

Salin folder ini sebagai repositori GitHub **public** baharu, contohnya
`MyFlutterApp-Assets`. Aplikasi membaca `manifest/manifest.json` melalui URL
raw, dan memuat turun fail dari **GitHub Releases**.

```
MyFlutterApp-Assets/
├── manifest/
│   ├── manifest.json          dibaca oleh aplikasi (dijana — jangan sunting dengan tangan)
│   └── manifest-version.json  ringkasan: versi release, bilangan aset, SHA-256 manifest
├── release-assets/            fail release seterusnya (TIDAK di-commit)
├── tools/
│   ├── generate_manifest.py   jana manifest.json
│   ├── validate_manifest.py   semak manifest sebelum diterbitkan
│   ├── calculate_hash.py      SHA-256 + saiz fail
│   ├── fdam_common.py         peraturan dikongsi (sama seperti dalam aplikasi)
│   └── tests/                 ujian unit alat Python
├── config/assets_config.json  metadata setiap fail (id, kategori, wajib, extract, …)
├── examples/release-assets/   fail contoh kecil (untuk mencuba alat)
├── .github/workflows/publish-assets.yml
└── .gitignore
```

Alat Python hanya menggunakan pustaka standard (Python 3.9+).

## 1. Konfigurasi

`config/assets_config.json` — kunci ialah nama fail dalam `release-assets/`:

```json
{
  "appId": "com.example.myapp",
  "assets": {
    "audio.zip": { "id": "audio_pack_01", "category": "audio", "localPath": "audio/audio.zip",
                   "required": true, "downloadOnStartup": true, "extract": true }
  }
}
```

| Medan | Lalai | Maksud |
|---|---|---|
| `id` | nama fail (slug) | Pengenal tetap aset. Jangan ubah selepas diterbitkan. |
| `category` | ikut extension | `audio`, `image`, `video`, `database`, `resource`, `config`, `data` |
| `localPath` | `<folder kategori>/<nama>` | Lokasi dalam peranti, relatif kepada `assets/` (atau `databases/` untuk `database`). |
| `required` | `false` | Aplikasi tidak dibuka sehingga fail ini dipasang. |
| `downloadOnStartup` | `false` | Dimuat turun automatik selepas fail wajib (tidak menghalang aplikasi). |
| `extract` | `true` untuk `.zip` | ZIP dibuka ke folder `<localPath tanpa .zip>/`. |
| `version` | automatik | Biasanya biarkan: fail berubah → versi release baharu; fail sama → versi lama dikekalkan. |
| `deprecated` | `false` | Aset lapuk: tidak dimuat turun untuk pemasangan baharu. |

Fail tanpa entri config tetap dimasukkan dengan nilai lalai. Nama fail mesti
hanya mengandungi huruf, nombor, `.`, `_`, `-` (URL GitHub yang boleh dijangka).

## 2. Menerbitkan release (dari komputer anda)

Langkah ini hanya memuat naik fail yang **berubah**. Fail yang sama kekal
dengan URL release lama, jadi aplikasi tidak memuat turunnya semula.

1. Letakkan fail dalam `release-assets/`.
2. Jana manifest (gunakan manifest semasa sebagai `--previous`):

```bash
python tools/generate_manifest.py --owner USERNAME --repo MyFlutterApp-Assets --tag v1.1.0 --source release-assets --output manifest/manifest.json --config config/assets_config.json --previous manifest/manifest.json --upload-list upload.txt
```

3. Semak:

```bash
python tools/validate_manifest.py manifest/manifest.json --owner USERNAME --repo MyFlutterApp-Assets --check-files release-assets --tag v1.1.0
```

4. Cipta release dan muat naik fail yang berubah (GitHub CLI):

```bash
gh release create v1.1.0 --title "Assets v1.1.0" --notes "Asset update"
```

```bash
xargs -a upload.txt gh release upload v1.1.0 --clobber
```

5. Sahkan semua URL boleh dimuat turun:

```bash
python tools/validate_manifest.py manifest/manifest.json --check-urls
```

6. **Barulah** commit dan push manifest (aplikasi melihatnya serta-merta):

```bash
git add manifest/ && git commit -m "Assets v1.1.0" && git push
```

> Susunan penting: muat naik fail → sahkan URL → push manifest. Jika manifest
> di-push dahulu, aplikasi akan cuba memuat turun fail yang belum wujud
> (ia akan gagal dengan `FILE_NOT_FOUND` dan mencuba semula kemudian, tetapi
> pengguna akan melihat ralat).

Alternatif: workflow `Publish assets` (Actions → Run workflow) melakukan
langkah 2–6 untuk fail yang berada dalam repositori (contohnya melalui Git LFS).

## 3. Peraturan penting

* Jangan sekali-kali tukar kandungan fail dalam release yang sudah diterbitkan
  tanpa menjana semula manifest: SHA-256 tidak akan sepadan dan aplikasi akan
  menolak fail itu.
* `releaseVersion` mesti meningkat setiap kali ada fail berubah (aplikasi
  menolak manifest yang lebih lama daripada cache — perlindungan replay).
* Untuk "rollback" penerbit: terbitkan versi baharu (contoh `v1.2.1`) yang
  mengandungi fail lama.
* Jangan letak token atau rahsia dalam repositori ini; ia mesti public.
* Had saiz satu fail Release GitHub ialah 2 GiB.

## 4. Menguji alat

```bash
python -m unittest discover -s tools/tests
```

Contoh sebenar (fail kecil dalam `examples/`):

```bash
python tools/generate_manifest.py --owner USERNAME --repo MyFlutterApp-Assets --tag v1.0.0 --source examples/release-assets --output manifest/manifest.json
```
