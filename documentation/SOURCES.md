# Sumber rasmi setiap saluran

## Stream terus dalam pangkalan data v2

Semua URL di bawah diuji pada 15 Nov 2026 dengan `tool/health_check.dart`, iaitu playlist, varian dan segmen terbaharu. Ujian dibuat dari rangkaian **di luar Malaysia**, tanpa referer, token atau kuki.

Calon URL diambil daripada indeks awam iptv-org. Hanya hos milik penyiar atau CDN pemain rasmi mereka disimpan. URL IP `http://`, restream pihak ketiga, worker proksi dan URL yang memerlukan header palsu ditolak.

| Saluran | Hos | Keputusan |
|---|---|---|
| TV1, TV2, TV Okey, Berita RTM | `d25tgymtnqzu8s.cloudfront.net` (CDN pemain RTMKlik) | ONLINE (TV2 sekali 404 sementara akibat segmen berputar; 3/3 ujian ulang ONLINE) |
| TVRI Nasional, TVRI World, TVRI Jakarta (Daerah) | `ott-balancer.tvri.go.id` (pelayan TVRI) | ONLINE |
| Metro TV | `edge.medcom.id` (Media Group) | ONLINE |
| CNA | `d2e1asnsl7br7b.cloudfront.net` (CDN pemain CNA) | ONLINE |
| RTB Sukmaindera | `d1211whpimeups.cloudfront.net` (CDN RTB Go) | HTTP 403 di luar Brunei; tidak disahkan |
| Suria | `d11h6a6nhl9kj9.cloudfront.net` | Hos tiada lagi (DNS); tidak dimasukkan |

### Ditambah dalam v3 (diuji 15 Nov 2026, kaedah yang sama)

| Saluran | Hos (domain penyiar) | Keputusan |
|---|---|---|
| 29 stesen TVRI daerah (Aceh … Yogyakarta) | `ott-balancer.tvri.go.id` | ONLINE |
| Magna Channel | `edge.medcom.id` | ONLINE (tidak 24 jam) |
| Rodja TV | `rodjatv.com` | ONLINE |
| DAAI TV | `pull.daaiplus.com` | ONLINE |
| UGTV | `cdn.gunadarma.ac.id` | ONLINE |
| Salira TV | `live.salira.tv` | ONLINE |
| Lingkar TV | `lingkartv.my.id` | ONLINE |
| Rinjani TV | `rinjanitv.cloud` | ONLINE |
| Maah TV (MY) | `hls.maahtv.live` | ONLINE |
| meWATCH LIVE 1 (SG) | `tglmp04.akamaized.net` (DASH, tanpa DRM) | ONLINE (saluran acara; mungkin papar slaid antara acara) |

**Ditolak:**
- TVR Parlemen dan TVKU: sambungan diputuskan.
- Al-Iman TV: 404.
- Jogja TV: sijil TLS tidak sah.
- RRI Net: hos bernama `private-streaming`.
- Stream pada vendor yang tidak dapat disahkan (`siar.us`, `streamlock.net`) dan semua restream pihak ketiga.

Bagi saluran v3 selain TVRI dan meWATCH, laman rasmi belum dapat disahkan dari persekitaran pembinaan. Oleh itu `official_url` dibiarkan kosong (tidak diteka).

Pemilikan hos CloudFront tidak dapat dibuktikan melalui nama domain. Ia dikenal pasti sebagai CDN pemain rasmi berdasarkan indeks awam. **Kebenaran penyiar untuk penggunaan dalam aplikasi pihak ketiga belum disahkan**, jadi semak terma penyiar sebelum edaran awam.


Dikumpul pada 15 Nov 2026 daripada sumber awam. **Tiada URL di bawah dapat dibuka dari persekitaran pembinaan** kerana hos penyiar disekat oleh rangkaian, jadi semuanya perlu disemak semula dari Malaysia. Tiada URL stream terus disenaraikan; lihat [STREAM_VERIFICATION.md](STREAM_VERIFICATION.md).

## Malaysia

| Saluran | Penyiar | Platform rasmi | Catatan |
|---|---|---|---|
| TV1, TV2, TV Okey, TV6, Berita RTM, Sukan RTM | RTM | RTMKlik – https://rtmklik.rtm.gov.my/ | Aplikasi RTMKlik (iOS/Android/Android TV) menyenaraikan siaran langsung TV1, TV2, Okey, Berita RTM, Sukan RTM/Sukan+ dan TV6. Siaran dalam talian umumnya terhad kepada Malaysia (`geo_allowed: ["MY"]`). |
| TV3, 8TV, TV9 | Media Prima | Tonton – https://www.tonton.com.my/ | |
| DidikTV | KPM / Media Prima | https://www.tonton.com.my/ (perlu disahkan) | Platform rasmi perlu disahkan oleh penyelenggara |
| Awesome TV | Awesome TV | https://awesometv.my/ | Status siaran tidak pasti: MYTV menggantung siarannya pada Nov 2023 dan siaran Astro dilaporkan tamat Ogos 2024 |

## Indonesia

| Saluran | Penyiar | Platform rasmi |
|---|---|---|
| TVRI Nasional, TVRI World, TVRI Sport, TVRI Daerah | TVRI | https://www.tvri.go.id/ (aplikasi TVRI Klik) |
| RCTI, MNCTV, GTV, iNews | MNC Media | RCTI+ – https://www.rctiplus.com/ |
| SCTV, Indosiar | Emtek | Vidio – https://www.vidio.com/ |
| Trans TV | Trans Media | https://www.transtv.co.id/ |
| Trans7 | Trans Media | https://www.trans7.co.id/ |
| Metro TV | Media Group | https://www.metrotvnews.com/ |
| tvOne | Visi Media Asia | https://www.tvonenews.com/ |
| Kompas TV | Kompas Gramedia | https://www.kompas.tv/ |

## Singapura

| Saluran | Penyiar | Platform rasmi |
|---|---|---|
| Channel 5, Channel 8, Channel U, Suria, Vasantham | Mediacorp | meWATCH – https://www.mewatch.sg/ |
| CNA | Mediacorp | https://www.channelnewsasia.com/ |

## Brunei

| Saluran | Penyiar | Platform rasmi | Catatan |
|---|---|---|---|
| RTB Sukmaindera | RTB | RTB Go – https://www.rtbgo.bn/ | |
| RTB Aneka | RTB | RTB Go | Dilaporkan tidak boleh ditonton di luar Brunei (`geo_allowed: ["BN"]`) |
| RTB Perdana | RTB | https://www.rtb.gov.bn/ | Dilaporkan tiada dalam RTB Go web |
| RTB News | RTB | https://www.rtb.gov.bn/ | Saluran TV "RTB News" yang berasingan **tidak dapat disahkan**; mungkin perkhidmatan berita RTB Perdana |

## Rujukan carian

- RTMKlik di App Store: https://apps.apple.com/my/app/rtmklik/id777391399
- Astro – Sukan+ dan Berita RTM: https://corporate.astro.com.my/mediaroom-releases/astro-deepens-partnership-rtm-offering-new-channels-ahead-glasgow-2026
- Awesome TV: https://en.wikipedia.org/wiki/Awesome_TV ; https://www.thevibes.com/articles/news/99498/mytv-to-suspend-awesome-tv-broadcast-from-nov-2
- RTB: https://en.wikipedia.org/wiki/Radio_Television_Brunei ; https://en.wikipedia.org/wiki/RTB_Sukmaindera
- TVRI: https://en.wikipedia.org/wiki/TVRI_(TV_channel) ; TVRI Klik di App Store: https://apps.apple.com/id/app/tvri-klik/id1157677528
