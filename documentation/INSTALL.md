# Pemasangan dan binaan

## Keperluan

| Alat | Versi |
|---|---|
| Flutter | **3.32.8** (stable). Flutter 3.35+ menaikkan minSdk lalai ke 24, tetapi projek ini menetapkan `minSdk = 23` secara eksplisit. Versi baharu belum diuji. |
| JDK | 17 (atau 21) |
| Android SDK | platform 35, build-tools 35 |

## Bina APK

Linux/macOS:

```bash
flutter pub get
```

```bash
dart run tool/validate_db.dart
```

```bash
flutter analyze
```

```bash
flutter test
```

```bash
flutter build apk --release
```

APK terhasil di `build/app/outputs/flutter-apk/app-release.apk`. Namakan semula kepada `MY_ASEAN_TV.apk`.

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

Ini menghasilkan `dist\MY_ASEAN_TV.apk`. Tambah `-SplitPerAbi` untuk APK yang lebih kecil; kebanyakan TV Box memerlukan `armeabi-v7a`.

Untuk pangkalan data daripada repository lain:

```bash
flutter build apk --release --dart-define=DB_BASE_URL=https://raw.githubusercontent.com/USERNAME/my-asean-tv/main/database/
```

## GitHub Actions

`.github/workflows/build.yml` menjalankan langkah berikut:

1. checkout
2. Java 17
3. Flutter 3.32.8
4. `pub get`
5. pengesahan JSON
6. `flutter analyze`
7. `flutter test`
8. `build apk --release`
9. semak `sdkVersion:'23'`
10. muat naik artifact **MY_ASEAN_TV**

### Tandatangan release (pilihan)

Tanpa kunci, APK ditandatangani dengan kunci debug. Itu sesuai untuk ujian tetapi **tidak** untuk Play Store.

Cipta kunci sekali sahaja:

```bash
keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias myaseantv
```

- **Lokal:** cipta `android/key.properties` dengan `storeFile`, `storePassword`, `keyAlias` dan `keyPassword`. Fail ini sudah ada dalam `.gitignore`; jangan commit.
- **CI:** tambah secrets `ANDROID_KEYSTORE_BASE64` (`base64 -w0 release.jks`), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` dan `ANDROID_KEY_PASSWORD`.

## Pasang pada Android TV Box

1. Pada TV Box, buka **Settings → Device Preferences → About** dan tekan *Build* 7 kali untuk mengaktifkan Developer options.
2. Hidupkan **USB/Network debugging**.
3. Dari komputer:

```bash
adb connect 192.168.1.50:5555
```

```bash
adb install -r MY_ASEAN_TV.apk
```

Sebagai alternatif, salin APK ke pemacu USB dan pasang melalui pengurus fail. Benarkan "Unknown sources" untuk pengurus fail itu.

Ikon MY ASEAN TV akan muncul di skrin utama Android TV (banner Leanback) dan di pelancar telefon.

## Kawalan remote

| Butang | Skrin utama | Pemain |
|---|---|---|
| ◀ ▶ ▲ ▼ | Gerak fokus | ▲▼ tukar saluran, ◀▶ senarai saluran (apabila kawalan tersembunyi) |
| OK / Enter | Buka saluran | Papar kawalan |
| CH+ / CH- (PageUp/Down) | – | Tukar saluran |
| Play/Pause | – | Main/Jeda |
| BACK | Keluar skrin | Tutup panel → sembunyi kawalan → keluar |
| Volume | Kelantangan sistem | Kelantangan sistem; VOL± dan Mute dalam kawalan |
