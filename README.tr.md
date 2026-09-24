<p align="center">
  <img src="docs/images/icon.png" width="112" alt="AndroMac simgesi">
</p>
<h1 align="center">AndroMac</h1>
<p align="center">
  <a href="https://github.com/anilmetin0/AndroMac/releases/latest"><img src="https://img.shields.io/github/v/release/anilmetin0/AndroMac?style=for-the-badge&label=s%C3%BCr%C3%BCm" alt="sürüm"></a>
  <a href="https://github.com/anilmetin0/AndroMac/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/anilmetin0/AndroMac/build.yml?style=for-the-badge&label=build" alt="build"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/anilmetin0/AndroMac?style=for-the-badge&label=lisans" alt="lisans"></a>
  <img src="https://img.shields.io/badge/macOS_14+_%7C_Android_10+-555?style=for-the-badge" alt="platformlar">
</p>
<p align="center">Android telefonun ve Mac'in, kendi Wi-Fi ağın üzerinden eşit. Bulut yok, hesap yok.</p>
<p align="center">
  <a href="https://github.com/anilmetin0/AndroMac/releases/latest">⬇️ İndir</a>
  •
  <a href="docs/GUIDE.tr.md">📖 Rehber</a>
  •
  <a href="README.md">🇬🇧 English</a>
</p>

<table>
<tr>
<td align="center" valign="top"><img src="docs/images/macos-panel.png" alt="macOS'ta AndroMac menü çubuğu paneli" width="360"></td>
<td align="center" valign="top"><img src="docs/images/android-home.png" alt="Android'de AndroMac ana ekranı" width="276"></td>
</tr>
</table>

# AndroMac nedir?

AndroMac, bir Android telefonu bir Mac'e yerel ağ üzerinden doğrudan bağlar. Mac, telefonun pilini,
bildirimlerini, panosunu ve müziğini gösterir, iki yönde dosya gönderir ve telefonun ekranını bir
pencerede gösterebilir. İki uygulama birbirini Bonjour ile bulur, bir kez bir anahtar üzerinde
anlaşır ve o andan sonra yalnızca birbiriyle konuşur. Arada sunucu yoktur.

Telefona neredeyse hiçbir maliyet getirmeyecek şekilde tasarlandı: telefon kendi zamanlayıcısını
çalıştırmaz, bir yerde yapılması gereken işi Mac yapar.

# Özellikler

### Günlük kullanım
- Pil seviyesi, şarj durumu ve menü çubuğunda düşük pil uyarısı
- İki yönde pano, Mac'te aranabilir bir geçmişle
- Bildirim Merkezi'nde bildirimler, eylemler ve satır içi yanıtla, uygulama başına kademe
- Medya denetimleri, zil ve ses düzeyi, kaybolan telefonu çaldıran bir düğme
- İki yönde dosya, saklanmadan önce SHA-256 ile doğrulanır
- Fare, klavye ve sesle ekran yansıtma, pakette gelen [scrcpy](https://github.com/Genymobile/scrcpy) ile
- Tek Mac'te birden fazla telefon, her biri kendi ayarlarıyla

### Tasarımdan gizli
- Yalnızca yerel ağ; ağdan çıkan tek istek günlük güncelleme denetimidir ve tek anahtarla kapanır
- P-256 üzerinde Noise-KK el sıkışması ve AES-256-GCM, iki ekranda 6 haneli kodla onaylanır
- Kripto iki kez yazıldı (CryptoKit ve JCE); iki betik ikisinin uyuştuğunu kanıtlar
- Telemetri yok, analiz yok, iki uygulamada da üçüncü parti kütüphane yok

[Rehber](docs/GUIDE.tr.md) her özelliği, güven modelini ve AndroMac'in KDE Connect, LocalSend ve
Quick Share ile karşılaştırmasını anlatır.

# Kurulum

### Mac · Apple Silicon, macOS 14+

```bash
brew tap anilmetin0/andromac https://github.com/anilmetin0/AndroMac
brew trust anilmetin0/andromac
brew install --cask andromac
xattr -dr com.apple.quarantine /Applications/AndroMac.app
```

Homebrew yok mu? DMG'yi
[yayınlardan](https://github.com/anilmetin0/AndroMac/releases/latest) indir, AndroMac'i
Uygulamalar'a sürükle, sonra son satırı çalıştır. Uygulama noter onaylı olmadığı için bu bir kez gerekir.

### Android · 10+

Telefonda [yayınları](https://github.com/anilmetin0/AndroMac/releases/latest) aç ve
APK'ya dokun. Ya da telefon adb ile bağlıyken:

```bash
gh release download --repo anilmetin0/AndroMac --pattern '*-android.apk'
adb install AndroMac-*-android.apk
```

### Eşleştir

1. İki cihazda da AndroMac'i aç, ikisi aynı Wi-Fi'da olsun.
2. Telefonda **İzinler** kartının listelediklerini ver, sonra **Eşleştir**'e dokun.
3. İki ekranda aynı altı hanenin çıktığını kontrol et ve ikisinde de onayla.

Uygulamalar bundan sonra kendilerini günceller. Her adımın ayrıntısı ve sorun giderme
[rehberde](docs/GUIDE.tr.md#kurulum).

# Derleme

```bash
scripts/verify-crypto.sh && scripts/verify-handshake.sh   # iki gerçekleme uyuşuyor
macos/scripts/fetch-scrcpy.sh && macos/build.sh           # → macos/build/AndroMac.app
android/gradlew -p android :app:assembleDebug             # → APK
```

Xcode 26.6+, JDK 25 ve platform 37'li Android SDK gerekir. Araç zincirinin tamamı, testler ve her
değişikliğin uyması gereken kurallar [CONTRIBUTING.md](CONTRIBUTING.md)'de. Kablo protokolü
[docs/PROTOCOL.md](docs/PROTOCOL.md)'de, enerji kuralları [docs/ENERGY.md](docs/ENERGY.md)'de.

# Lisans

AndroMac [MIT Lisansı](LICENSE) ile lisanslanmıştır. Mac paketi, kendi lisanslarıyla dağıtılan
programlar da taşır; kaynaklarıyla birlikte [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)'de
listelenir:

- [scrcpy](https://github.com/Genymobile/scrcpy), [Apache Lisansı 2.0](https://github.com/Genymobile/scrcpy/blob/master/LICENSE) ile
- Android Açık Kaynak Projesi'nin [adb](https://android.googlesource.com/platform/packages/modules/adb/)'si, Apache Lisansı 2.0 ile
- scrcpy'nin içindeki [FFmpeg](https://ffmpeg.org/legal.html) ve [libusb](https://github.com/libusb/libusb), LGPL 2.1 ile; [SDL](https://github.com/libsdl-org/SDL), zlib Lisansı ile

# Katkıda bulunanlar

<a href="https://github.com/anilmetin0/AndroMac/graphs/contributors"><img src="https://contrib.rocks/image?repo=anilmetin0/AndroMac" alt="Katkıda bulunanlar"></a>

Issue ve pull request'ler memnuniyetle karşılanır; [CONTRIBUTING.md](CONTRIBUTING.md) ile başla.
Güvenlik açıklarını [SECURITY.md](SECURITY.md)'de anlatıldığı gibi gizli olarak bildir.

# Teşekkürler

Bu projelere, belirli bir sıra olmadan teşekkürler:

- **[scrcpy](https://github.com/Genymobile/scrcpy)**, Genymobile ve Romain Vimont; ekran yansıtmanın tamamını o yapar
- **[Android Açık Kaynak Projesi](https://source.android.com/)**, adb ve kablosuz eşleştirmesi için
- **[KDE Connect](https://invent.kde.org/network/kdeconnect-kde)**; telefon ile bilgisayar arasında neler yapılabileceğini gösterdi, 2025 eşleştirme güvenlik bildirimi de AndroMac'in eşleştirme kodunu şekillendirdi
- **[LocalSend](https://github.com/localsend/localsend)**, önce teklif sonra kabul eden dosya akışı için
- **[Syncthing](https://github.com/syncthing/syncthing)**, anahtardan cihaz kimliği fikri ve parça-özet disiplini için
- **[Noise Protokol Çerçevesi](https://noiseprotocol.org/)**, Trevor Perrin; el sıkışmanın izlediği desen
- **[Shizuku](https://github.com/RikkaApps/Shizuku)**, Android'in Kablosuz hata ayıklama anahtarını doğrudan açmanın yolunu gösterdiği için
- **[Obtainium](https://github.com/ImranR98/Obtainium)** ve **[Homebrew](https://brew.sh)**, mağaza dışında kurmayı ve güncellemeyi kolaylaştırdıkları için
- *AndroMac'i deneyen, sorun bildiren ve kullanan herkese ❤️*
