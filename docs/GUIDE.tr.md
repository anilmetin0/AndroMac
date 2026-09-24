# AndroMac rehberi

[README](../README.tr.md)'nin dışarıda bıraktığı her şey: adım adım kurulum ve eşleştirme, her
özelliğin ayrıntısı, tüm ayarlar, sorun giderme ve güven modeli. English: [GUIDE.md](GUIDE.md).

## Kurulum

Paketler [yayın sayfasında](https://github.com/anilmetin0/AndroMac/releases/latest), sağlama
toplamları yanlarındaki `SHA256SUMS.txt` dosyasında. Mac paketi yalnızca Apple Silicon (M1 ve
sonrası) içindir, Intel derlemesi yok. APK her telefon için tek dosyadır, çünkü uygulamada yerel
kod yok.

### Mac, macOS 14 Sonoma ve üstü

[Homebrew](https://brew.sh) ile. Tap bu deponun içinde, o yüzden URL ile eklenir; Homebrew 7,
Homebrew dışından gelen bir tap'i ancak ona güvendiğini söyledikten sonra yükler:

```bash
brew tap anilmetin0/andromac https://github.com/anilmetin0/AndroMac
brew trust anilmetin0/andromac
brew install --cask andromac
xattr -dr com.apple.quarantine /Applications/AndroMac.app
```

Homebrew olmadan: `AndroMac-<sürüm>-macOS-arm64.dmg` dosyasını indir, aç, `AndroMac.app`'i
**Uygulamalar**'a sürükle ve yukarıdaki `xattr` satırını çalıştır.

`xattr` satırı bir kez gerekir. Uygulama ad-hoc imzalı ve noter onaylı değil, bu yüzden macOS ilk
açılışı reddeder. Komut yerine uygulamayı bir kez açmayı deneyip reddedilmesini bekleyebilir, sonra
**Sistem Ayarları → Gizlilik ve Güvenlik**'te **Yine de Aç**'a basabilirsin.

İlk açılışta:

1. Keychain sorusuna **Always Allow** de; kimlik anahtarı orada durur. Reddedersen uygulama
   geçici bir anahtarla çalışır ve bunu panelde söyler, eşleştirmen bozulmaz.
2. Yerel Ağ sorusuna **İzin ver** de. Verilmezse telefon Mac'i bulamaz.
3. AndroMac'i Dock'ta değil menü çubuğunda ara. Telefon silüeti paneli açar.
4. İsteğe bağlı: Ayarlar → Genel → **Oturum açınca başlat**.

Bundan sonra uygulama kendini günceller. Yeni bir sürüm çıktığında `brew upgrade --cask andromac`
da ona geçer.

### Android 10 ve üstü

Telefonda [yayın sayfasını](https://github.com/anilmetin0/AndroMac/releases/latest) aç,
`AndroMac-<sürüm>-android.apk` dosyasına dokun ve Android sorduğunda tarayıcından kuruluma izin
ver.

Mac'ten, telefon adb ile bağlıyken ve [GitHub CLI](https://cli.github.com) kuruluyken:

```bash
gh release download --repo anilmetin0/AndroMac --pattern '*-android.apk'
adb install AndroMac-*-android.apk
```

Sonra AndroMac'i aç ve izinleri ver:

1. Uygulama bildirim iznini hemen ister, bildirim erişimi ekranını da gerekçesiyle bir kez önerir.
2. Ana ekrandaki **İzinler** kartı ya "Tüm izinler verildi" yazar ya da eksik olanları söyler. Bir
   satıra dokununca ilgili sistem ekranı açılır. Kartın başlığına dokununca her biri Zorunlu,
   Önerilir ya da İsteğe bağlı olarak işaretli tam liste açılır:
   - **Yerel ağ erişimi**, Android 17 ve üstünde zorunlu. Verilmezse telefon Mac'i ne bulabilir
     ne ona ulaşabilir. Android bunu Yakındaki cihazlar altında gösterir.
   - **Bildirimlere izin ver**, zorunlu; uygulamanın kendi kalıcı ve pano bildirimlerini
     gösterebilmesi için.
   - **Bildirim erişimi**, zorunlu; bildirim aynası ve medya oturumunu okumak için.
   - **Pil optimizasyonu**, önerilir; ekran kapalıyken sistem bağlantıyı kesmesin diye.
   - **Rahatsız Etmeyin erişimi**, isteğe bağlı; Mac'in telefonu sessize alabilmesi için.
   - **Diğer uygulamaların üzerinde göster**, isteğe bağlı; Mac panoyu isteyince sen bildirime
     dokunmadan yanıt gelsin diye.
3. Android 13 ve üstünde, dışarıdan kurulan uygulamalarda bildirim erişimi anahtarı gri görünür ve
   kısıtlı ayarlardan söz eden bir mesaj çıkar. Sistem denemeyi kaydetsin diye bir kez dene, sonra
   **Ayarlar → Uygulamalar → AndroMac → ⋮ → Kısıtlı ayarlara izin ver** yolunu izleyip tekrar dene.

Zorunlu bir izin eksikken ekranın üstünde hangisinin eksik olduğunu söyleyen bir şerit durur.
Dokununca doğru ekranı açar; çarpı, başka bir izin geri alınana kadar gizler.

[Obtainium](https://github.com/ImranR98/Obtainium) APK'yı doğrudan yayın sayfasından kurar ve
günceller. Uygulama olarak `https://github.com/anilmetin0/AndroMac` adresini ekle ya da telefonda
[obtainium://add/github.com/anilmetin0/AndroMac](obtainium://add/https://github.com/anilmetin0/AndroMac)
bağlantısını aç. Yayın APK'sı her sürümde aynı anahtarla imzalanır, güncellemeler yerinde kurulur.
Obtainium kararlı sürümleri izler; beta derlemeleri de almak için **ön sürümleri dahil et**
seçeneğini aç.

### Güncelleme denetimi

İki uygulama da günde bir kez denetler ve bulduğunu kendisi kurabilir. İki tarafta da **Ayarlar →
Güncellemeler**'de bir anahtar ve **Şimdi denetle** düğmesi var. Denetim yalnızca açılışta ve menü
çubuğu paneli açıldığında çalışır; zamanlayıcı yok. Daha yeni bir paket varsa uygulama bunu bir
kez `1.0.0 (fd7d47a)` biçiminde önerir: **Şimdi kur**, **Sonra**, **Bu sürümü atla**. Daha yeni
paket, daha büyük bir sürüm ya da aynı sürümün başka bir commit'ten derlenmiş hali olabilir.

Kurulumu oradan sonra uygulama üstlenir. Yayın dosyasını indirir, o yayınla birlikte yayınlanan
`SHA256SUMS.txt` ile doğrular ve ancak ondan sonra kendini değiştirir. Mac paketini takas edip
yeniden başlar; telefon APK'yı Android'in kurucusuna verir, kurucu sana sorar ve imzayı denetler.
Eksik ya da uyuşmayan bir sağlama toplamı güncellemeyi durdurur.

Uygulamaların bir sunucuyla konuşmasına yol açan tek şey bu denetimdir: api.github.com'a giden,
yalnızca uygulama sürümünü taşıyan tek bir istek. Varsayılan olarak açık, çünkü hiçbir mağazada
olmayan bir uygulamanın sana düzeltme çıktığını söyleyebileceği başka bir yol yok. Anahtarı
kapatırsan ağından hiçbir şey çıkmaz. Bkz. [Gizlilik ve güvenlik](#gizlilik-ve-güvenlik).

## Eşleştirme

1. Mac'te AndroMac'i aç ve iki cihazın da aynı Wi-Fi ağında olduğundan emin ol.
2. Telefonda **Eşleştir**'e dokun.
3. İki ekranda da aynı 6 hane çıkmalı. Aynıysa ikisinde de onayla. Değilse reddet; el sıkışmaya
   biri girmiş demektir.

Sonrası otomatik. Ağ geri geldiğinde telefon kendi başına yeniden bağlanır.

Eşleştirilmemişken iki uygulama da her adımın canlı durumunu gösteren bir rehber sunar; hangi
adımın takıldığını oradan görürsün:

| Adım | Telefonda | Mac'te |
|---|---|---|
| Mac'te uygulama açık mı | `Mac ağda görüldü` ya da `bulunamadı` | `Bu Mac ağda yayında` |
| Aynı ağ | `Telefon: 192.168.1.42` | `Bu Mac: 192.168.1.5` |
| Eşleştirme | `Hazır` ya da `Önceki adımları tamamla` | Telefon bekleniyor |

Yine de bağlanmıyorsa rehberin altındaki **Bağlanamıyorum** canlı tanıyı açar: telefonun adresi
ve alt ağı, Mac görüldü mü, eşleştirme ve bağlantı durumu, uygulama sürümü, ardından belirtiye
göre çözüm listesi. Mac'te Ayarlar → Ağ aynı bilgiyi verir ve Yerel Ağ iznine doğrudan bağlantı
sunar.

Mac'in eşleştirme penceresi de telefonunki de haneleri büyük gruplar hâlinde gösterir. Daha önce
sabitlenmiş anahtar değişmişse telefonda varsayılan düğme **Reddet** olur. Mac'te ilk telefonda
varsayılan **Eşleştir**, sonraki her istekte **Reddet**; beklenmedik bir telefon şüphelidir.

## Özellikler

| Özellik | Yön | Ne yapar |
|---|---|---|
| Pil | Telefondan Mac'e | Seviye, şarj durumu ve sıcaklık. Menü çubuğunda isteğe bağlı yüzde, panelde çubuk, seviye seçtiğin eşiğin altına düşünce tek bir uyarı. Eşik Ayarlar → Eşitleme'de %10, %15, %20 ya da %30 olarak seçilir. |
| Pano | Mac'ten telefona | Kopyaladıkça otomatik ya da yalnızca paneldeki düğmeye basınca; seçim Ayarlar → Pano'da. Elle gönderim telefona "Yapıştır" eylemli sessiz bir bildirim olarak düşer; arka planda panoya yazmayı engelleyen üreticiler için. Parola yöneticisinin gizli işaretlediği pano hiç gönderilmez. |
| Pano | Telefondan Mac'e | Paneli açtığında Mac sorar, telefon yanıtlar. Telefonda AndroMac öne gelince pano kendiliğinden gider. Elle göndermek için Hızlı Ayarlar karesi, kalıcı bildirimdeki düğme ve paylaşım menüsü var. [Bu yön neden istenerek çalışıyor](#pano-neden-tek-yönde-istenerek-çalışıyor). |
| Pano geçmişi | Mac | İki yöndeki son 50 kayıt. Arama, tıklayınca panoya alma, sağ tıkla telefona geri gönderme ya da silme. |
| Bildirimler | Telefondan Mac'e | Uygulamanın kendi ikonuyla Bildirim Merkezi'ne düşer. Yanıt dahil eylemler Mac'ten tetiklenir; hangi cihazda kapatırsan diğerinde de kapanır. |
| Uygulama başına kademe | İki yön | Tam, Sadece başlık ya da Kapalı; iki cihazdan da ayarlanır. Kademe telefonda uygulanır: Kapalı'da o uygulama için radyo hiç uyanmaz, Sadece başlık'ta içerik telefondan çıkmaz. |
| Gürültü elemesi | Telefon | Grup başlıkları, kalıcı ve ön plan servisi bildirimleri, yalnızca cihaza özel bildirimler ve sessiz kanallar gönderilmeden elenir. Aynalama, yalnızca telefon kilitliyken çalışacak biçimde sınırlanabilir. |
| Bildirim geçmişi | Mac | Aranabilir son 200 kayıt, yalnızca Mac'te. |
| Medya | İki yön | Telefonda çalan parçanın başlığı, sanatçısı ve uygulaması; Mac'ten önceki, oynat/duraklat ve sonraki. Yalnızca değişimde gönderilir, ilerleme çubuğu yoktur. |
| Telefonu bul | Mac'ten telefona | Telefon en fazla 30 saniye alarm sesiyle çalar ve titrer. "Buldum", ikinci bir istek ya da süre dolması durdurur. |
| Telefon denetimleri | Mac'ten telefona | Panelden zil modu (zil, titreşim, sessiz) ve medya ses düzeyi; bir de bütün aynalama zincirini dolaşıp geri dönen test bildirimi. Sessize almak telefonda Rahatsız Etmeyin erişimi ister; izin yoksa düğme kapalı görünür. |
| Dosyalar | İki yön | Telefonda paylaşım menüsünden, Mac'te panelin **Dosya gönder…** düğmesinden ya da sürükleyip bırakarak. Alıcıya önce sorulur; otomatik kabul açılabilir ve açıkken eşleşmiş bütün telefonlar için geçerlidir. Dosyalar İndirilenler'e iner, SHA-256 ile doğrulanır ve kendiliğinden açılmaz. Bkz. [diğer araçlarla karşılaştırma](#diğer-araçlarla-karşılaştırma). |
| Birden fazla telefon | Mac | Aynı anda birden fazla Android eşleştirilip bağlanabilir. Panel cihaz kartının üstünde her telefon için bir sekme gösterir; sekmeye tıklamak ayrıntıların, denetimlerin ve pilin hangi telefona ait olduğunu değiştirir. Her cihazın bağlantısı tek tek kesilip yeniden kurulabilir; "Bağlantıyı kes" hem hattı kapatır hem sonraki denemeyi geri çevirir. Her telefonun kendi pano anahtarı vardır. Eşleştirme kaldırma Ayarlar → Cihazlar'da. |
| Doğrulama kodları | Mac | Aynalanan bildirimde tek kullanımlık kod varsa panel kodu bir kopyalama düğmesinin üstünde gösterir. Kopyalamak kodu telefona geri göndermez ve pano geçmişine yazmaz. |
| Bağlantı rehberi | İki taraf | İki uygulama da hangi adımın takıldığını gösterir; telefonda ayrıca canlı bir tanı ekranı var. |
| Ölçümler | Mac | Saatlik mesaj, trafik, yeniden bağlanma sayısı ve en sık mesaj tipleri. Enerji iddiası böylece ölçülebilir. |
| Ekran yansıtma | Telefondan Mac'e | Telefonun ekranı bir pencerede; fare, klavye ve ses ile. Kablosuz hata ayıklama ya da USB üzerinden, paketle gelen scrcpy ile. Bkz. [Ekran yansıtma](#ekran-yansıtma). |
| Güncellemeler | İki taraf | İki uygulama da günde bir kez denetler, bulduğunu açılışta bir kez önerir ve kendisi kurar. İndirilen dosya, hiçbir şey değiştirilmeden önce sürümle yayınlanan sağlama toplamına göre doğrulanır. Tek anahtar denetimi kapatır. |

Kapsam dışı: SMS, arama kontrolü, birden fazla Mac, internet üzerinden erişim. İstediğin kadar
telefon, tek Mac, tek yerel ağ.

### Ekran yansıtma

Mac, telefonun ekranını bir pencerede gösterip fareyi, klavyeyi ve sesi telefona aktarabilir. Bu
işi [scrcpy](https://github.com/Genymobile/scrcpy) yapar; adb ile birlikte Mac paketinin içinde
gelir. AndroMac bağlantısı yerine Android'in kendi hata ayıklama kanalından geçer. Bu yüzden
telefonda hiçbir uygulamanın senin yerine açamayacağı bir anahtar gerekir:

1. Telefonda **Derleme numarası**na yedi kez dokunarak Geliştirici seçeneklerini aç, sonra
   **Kablosuz hata ayıklama**yı aç. USB hata ayıklama açıkken USB kablo da olur.
2. Mac panelinde telefonun kartındaki yansıtma düğmesine bas. İlk seferde panel bir eşleme kodu
   ister. Telefonda Kablosuz hata ayıklama içinden **Cihazı eşleme koduyla eşle**'yi aç ve altı
   haneyi panele yaz. Bu eşleme adb'nin kendisine aittir ve her Mac için bir kez yapılır.
3. Telefonun ekranı bir pencerede açılır. Durdurmak için pencereyi kapat.

Kablosuz hata ayıklama kapalıyken panel bunu söyler; **Telefonda aç** o ayarı telefonda açar.
Telefon anahtarın durumunu bildirdiği için anahtar açılınca Mac kendiliğinden devam eder. Ayarlar
→ Ekran yansıtma'da ses, telefon ekranını kapatma, uyanık tutma ve çözünürlük sınırı var.
AndroMac panoyu eşitlerken scrcpy'nin kendi pano eşitlemesi kapalı kalır, ikisi birbirini
yankılamasın diye.

Kablosuz hata ayıklama, telefonun adb'de güvendiği her bilgisayara telefonu kontrol etme imkânı
verir; işin bitince kapat. Paketlenmiş kopya olmadan kaynaktan derlenen sürüm `brew install
scrcpy` ile kurulanı kullanır. Pakete nelerin hangi lisansla girdiği
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) dosyasında.

### Pano neden tek yönde istenerek çalışıyor

Android 10'dan beri bir uygulama ön planda değilse panoyu okuyamıyor. Bu kasıtlı bir gizlilik
kararı ve desteklenen bir baypası yok. Bu yüzden telefon panosunu yalnızca istendiğinde gönderir.
Mac panelini açmak telefondan panosunu ister; telefon da bir anlığına odağı alan görünmez bir
etkinlikle panoyu okuyup yanıtlar. AndroMac'i telefonda öne getirdiğinde de pano gider, çünkü o
anda uygulama zaten ön plandadır.

O görünmez etkinlik telefonda tek bir izin ister: **Diğer uygulamaların üzerinde göster**. Bu,
sıradan bir uygulamanın Android'in arka planda etkinlik başlatma kuralından tek muafiyeti.
Uygulama SYSTEM_ALERT_WINDOW iznini bildirdiği için Android'in listesinde görünür ve anahtar
açılabilir. İzin yoksa telefon tek düğmeli bir bildirim gösterir; kare ve paylaşım menüsü de
çalışmaya devam eder. Paylaşım menüsü yolu panoya hiç dokunmaz, en temizi odur. İzni vermeyen ve
o bildirime de dokunmayan bir telefon hiçbir şey göndermez; protokolde onun panosunu okuyabilecek
başka bir yol da yok.

## Ayarlar

Telefonun ana ekranı sade kalır. Durum kartı Mac'in adını söyler: "… ile bağlı", "… ile bağlanılıyor"
ya da eşleştirilmemişken ağda gördüğü Mac'ler. Altında **Pil durumu**, **Pano**, **Bildirimler**
ve **Medya** için dört eşitleme anahtarı ve pano geçmişi durur. Bağlantı rehberi yalnızca telefon
eşleşene kadar görünür; sonra üst çubuktaki **ⓘ** düğmesi onu canlı tanıyla birlikte açar. İzinler
kartı yalnızca zorunlu bir izin eksikken çıkar. Geri kalan her şey üst çubuktaki **Ayarlar**
düğmesinin arkasında.

İki uygulama da sürümü aynı biçimde yazar: `1.1.0 (12 · abc1234)`, yani sürüm, derleme numarası ve
derlendiği commit. Telefonda Ayarlar → Hakkında'da durur. Hata bildirirken bu satırın tamamını yaz.

| Ekran | İçinde ne var |
|---|---|
| Ayarlar | Bağlantı, Bildirimler, Pano, Dosya aktarımı, İzinler, Dil, Güncellemeler ve Hakkında; her biri tek satırlık bir özetle. |
| Pano geçmişi | Mac'e giden ya da Mac'ten gelen son 20 metin, en yenisi üstte. Dokununca panoya alınır, gönder düğmesi yeniden gönderir. Yalnızca bellekte tutulur, depolamaya hiç yazılmaz; hassas kayıtlar tutulmaz. |
| İzinler | Altı iznin tamamı, "Verildi" ya da "Verilmedi" durumu ve Zorunlu, Önerilir ya da İsteğe bağlı notuyla. Ayarlar'dan açılır. |
| Bağlantı | Durum, Mac'in adı ve son adresi, **Otomatik yeniden bağlan**, **Şimdi bağlan** ve **Bu Mac'i unut**. |
| Bildirim ayarları | Neyin ayarlı olduğunu özetleyen **Uygulama filtresi**, **Sessiz bildirimler** ve **Sadece telefon kilitliyken**. Her zaman elenenleri de listeler. |
| Uygulama filtresi | Telefonun gördüğü her uygulama için üç kademeli seçici; Bildirim ayarları'ndan açılır. |
| Pano ayarları | Gelen: **Panoya otomatik yaz**, **Bildirim göster**. Giden: **Hassas içeriği gönderme**. Bir de **Panoyu Mac'e gönder**. |
| Bağlantı yardımı | Canlı tanı, sık karşılaşılan sorunlar ve işin nasıl yürüdüğü. **ⓘ** düğmesinden ya da eşleştirme rehberindeki **Bağlanamıyorum**'dan açılır. |
| Güncellemeler | Günlük güncelleme denetimi: anahtar, **Şimdi denetle** ve yeni paketi indirip doğrulayarak kuran **Kur** düğmesi. |
| Dosyalar | **Dosya al** ve **Dosyaları otomatik kabul et**. Gelen dosyalar İndirilenler'e iner; gönderme herhangi bir uygulamanın paylaşım menüsünden yapılır. |
| Dil | Android'in uygulama başına dil seçicisini açar; İngilizce ve Türkçe sunar. |

Mac'te menü çubuğu paneli göz atmak içindir. Birden fazla telefon eşliyse üstteki sekmeler
aralarında geçiş yapar. Telefonun kartı adını ve durumunu, tek bir pil satırını, çalan parçayı, zil
modu ile ses düzeyini tek satırda gösterir. Altında tek sıra düğme var: telefonu çaldır, test
bildirimi gönder, ekranı yansıt ve **Panomu buraya gönder**, **Cihaz ayarları…** ile **Bağlantıyı
kes**'i taşıyan bir **⋯** menüsü. Telefonun adına tıklamak ayarlarını açar. Sonra son pano kaydı
gelir; yanındaki düğmeler telefondan panoyu ister, Mac'inkini gönderir ya da dosya gönderir.
Üzerine gelince metnin tamamı görünür, ⌘C kopyalar. Paneli en son dört bildirim kapatır. Dosya
giderken bir ilerleme satırı, yalnızca hiç eşleştirme yokken ya da dinleyici kapalıyken bir durum
satırı, AndroMac için macOS bildirimleri kapalıyken de tek satırlık bir uyarı çıkar. Panelin
üstüne bırakılan dosyalar gönderilir. ⌘, Ayarlar'ı açar; menü çubuğu simgesine sağ tıklamak
AndroMac'i aç, Ayarlar ve Çık menüsünü açar.

Pencerenin tek bir kenar çubuğu var: üstte **Bildirimler**, **Pano** ve **Uygulamalar**, altında
bütün ayar bölümleri.

| Sayfa | İçinde ne var |
|---|---|
| Bildirimler | Geçmiş; arama ve temizleme düğmesi. |
| Pano | Geçmiş; arama, tıklayınca panoya alma, sağ tıkla geri gönderme ya da silme. |
| Uygulamalar | Telefondaki her uygulama için kademe seçici. |
| Ayarlar | Genel, Eşitleme, Pano, Bildirimler, Dosyalar, Ekran yansıtma, Cihazlar, İzinler, Ağ, Güncellemeler, Ölçümler ve Gizlilik. |

Ayarlar → Genel'de **Oturum açınca başlat**, **Menü çubuğunda pil yüzdesi** ve Sistem, İngilizce,
Türkçe seçenekli bir **Dil** seçici var. Dil açılışta okunduğu için değiştirince bir "Yeniden
başlat" düğmesi çıkar. Eşitleme bölümü **Pil**, **Pano**, **Bildirimler** ve **Medya**
anahtarlarını tutar; düşük pil uyarısı anahtarı ve %10, %15, %20 ya da %30 seçenekli eşik seçici
de oradadır. Pano bölümünde **Mac'ten telefona** için otomatik/elle seçimi, gizli pano kuralı ve
panel açılınca telefondan panosunun istenip istenmeyeceği var. Bildirimler bölümünde yansıtılan
bildirimler için ses çalma anahtarı ve geçmişteki kayıt sayısı var. Dosyalar'da **Dosya al** ve
eşleşmiş bütün telefonlar için geçerli **Dosyaları otomatik kabul et** var. Cihazlar bölümü
eşleşmiş bütün telefonları durumlarıyla listeler ve her biri için **Unut** düğmesi verir; birden
fazla telefon varsa **Bütün cihazları unut** da vardır. Bu Mac'in adı ve uygulama sürümü de
oradadır. İzinler bölümü macOS Bildirimler, Yerel Ağ ve Anahtar Zinciri erişiminin durumunu
gösterir; verilmemiş olanın yanında ilgili Sistem Ayarları bölmesini açan bir düğme durur. Ağ,
iki adresi ve Yerel Ağ iznine bir kestirmeyi gösterir. Güncellemeler, [Güncelleme
denetimi](#güncelleme-denetimi) başlığındaki denetimi barındırır ve sürüm sayfasının QR kodunu
çizer; APK'yı telefona kurmak için adres yazman gerekmez. Ölçümler [Enerji](#enerji) başlığında
anlatılıyor. Gizlilik, neyin nerede saklandığını yazar.

## Sorun giderme

| Belirti | Neye bakmalı |
|---|---|
| Telefon Mac'i bulamadığını söylüyor | Mac'te AndroMac açık mı; iki cihaz da aynı Wi-Fi'da mı, misafir ağı ya da AP izolasyonu olan bir ağ değil mi; Mac'te Yerel Ağ izni verildi mi (Ayarlar → Ağ ya da Ayarlar → İzinler); Android 17 ve üstünde telefonda Yerel ağ erişimi verildi mi. |
| Bağlanıyor, sonra kopuyor | Telefonda pil optimizasyonu muafiyeti ve router'daki AP izolasyonu. |
| Bildirimler gelmiyor | Bildirim erişimi, Android 13+ kısıtlı ayarlar akışı dahil; uygulama Kapalı kademesinde olabilir; sessiz bildirimler varsayılan olarak gönderilmez. macOS bildirimleri AndroMac için kapalıysa panel ve Ayarlar → İzinler bunu söyler. |
| Telefonda "Anahtar değişti" uyarısı | Mac uygulamasını yeniden kurduysan normaldir; telefonda eşleştirmeyi kaldırıp yeniden eşleştir. Kurmadıysan reddet. Yeniden kurulan bir telefon ise Mac'e yeni bir cihaz olarak gelir; eski kayıt sen silene kadar durur. |
| Keychain her açılışta soruyor | Ad-hoc imza her derlemede değişir. Yayın paketini kullan ya da `CODESIGN_IDENTITY` ile derle. |
| Pano telefondan kendiliğinden gelmiyor | [Yukarıda anlatılan](#pano-neden-tek-yönde-istenerek-çalışıyor) Android kısıtı. Mac paneli açılınca telefondan ister; telefonda AndroMac'i öne getirmek de gönderir. Anında yanıt için telefonda **Diğer uygulamaların üzerinde göster** iznini ver; yoksa telefonun gösterdiği bildirime, kareye ya da paylaşım menüsüne dokun. |
| Mac'ten telefon sessize alınmıyor | Telefonda **Rahatsız Etmeyin erişimi** ver. O olmadan Android değişikliği reddeder, Mac de düğmeyi kapalı gösterir. |
| Ekran yansıtma Kablosuz hata ayıklama istiyor | Geliştirici seçeneklerinde **Kablosuz hata ayıklama**'yı aç, telefon Mac ile aynı Wi-Fi'da olsun; ya da USB hata ayıklama açıkken kabloyla bağla. İlk seferde **Cihazı eşleme koduyla eşle** ekranındaki kodu panele yaz. |
| Müzik çalarken Mac'te parça görünmüyor | Medya oturumu bildirim erişimiyle okunuyor, önce onu ver. Medya anahtarı da açık olmalı. |

Telefondaki **Bağlanamıyorum**, bu tablonun canlı hâli. Eşleştirme rehberinin içinde durur;
telefon o rehberi yalnızca eşleştirilmemişken gösterir.

## Gizlilik ve güvenlik

Yerel ağdan hiçbir şey çıkmaz. Ulaşılacak bir sunucu, açılacak bir hesap, telemetri ya da
analitik yok. Uygulamalar internete soket açmaz; tek istisna Ayarlar → Güncellemeler'deki,
varsayılan olarak açık güncelleme denetimi. O da `api.github.com`'a günde en fazla bir kez en yeni
sürümü sorar ve `User-Agent` başlığındaki uygulama sürümünden başka bir şey göndermez.
Güncellemeyi kurmak `github.com`'dan indirir: otomatik kurulum açıksa denetimin hemen ardından
(telefon Wi-Fi'ı bekler), değilse sen Kur'a bastığında. Anahtarı kapatınca iki uygulama yine
yalnızca birbiriyle konuşur.

Telefondan neyin çıkacağını, uygulama başına belirlediğin kademe tayin eder. Kapalı'da hiçbir şey
çıkmaz, radyo bile uyanmaz. Sadece başlık'ta yalnızca uygulama adı gider; başlık, gövde ve eylem
adları boş gönderilir, yani içerik telefondan hiç çıkmaz. Tam'da başlık, gövde ve eylem adları
gider. Bir parola yöneticisinin ya da OTP alanının `EXTRA_IS_SENSITIVE` ile işaretlediği pano
içeriği gönderilmez; bu kural varsayılan olarak açıktır. Bonjour kaydı yalnızca cihaz adını ve
protokol sürümünü taşır; anahtar taşımaz.

Ne nerede duruyor:

| Ne | Nerede |
|---|---|
| Mac'in kimlik anahtarı | macOS Keychain |
| Telefonun kimlik anahtarı | Android Keystore'da duran ve dışarı çıkarılamayan bir AES-256-GCM anahtarıyla sarmalanmış. Anahtar değişimi sırasında belleğe açılır; P-256'yı yazılımda yapmanın tavanı bu |
| Sabitlenen karşı anahtar, cihaz adı ve ayarlar | Her cihazda yerel olarak |
| Bildirim ve pano geçmişi, bildirim görselleri | Yalnızca Mac'te, Application Support altında; Anahtar Zinciri'ndeki Mac kimliğinden türetilen bir anahtarla şifreli. Eşleştirmeyi kaldırınca silinir |

Diske yazılan tek şey dosyalar. Bir transfer ancak alıcı kabul ettikten sonra ya da eşleşmiş
cihazlar için otomatik kabulü açtıysan başlar; ondan önce hiçbir şey yazılmaz. Dosya, son adını
almadan önce SHA-256 özetiyle doğrulanır, kendiliğinden açılmaz ve Mac'te tarayıcı indirmesiyle
aynı karantina bayrağını taşır. Ad gelişte temizlenir; gönderen dizin seçemez.

Kablo üzerinde P-256 anahtar anlaşması, HKDF-SHA256 ve nonce olarak yön başına sayaç kullanan
AES-256-GCM var; tekrarlanan bir çerçeve bağlantıyı kapatır. Çerçeveler 1 MiB ile sınırlı ve
alıcı her alan için kendi uzunluk sınırını uygular. Mac, bir bağlantıya el sıkışmayı bitirmesi
için 10 saniye tanır ve aynı anda yalnızca birkaç doğrulanmamış bağlantı tutar. Eşleştirme
sorusunu hız sınırına bağlar, özel adres aralıklarının dışındaki bağlantıları reddeder ve kurulu
bir oturumu ancak yeni bağlantının el sıkışması bittikten sonra bırakır. Wi-Fi'ndeki başka bir
cihaz soket açarak telefonunu düşüremez. Hiçbir kayıt satırı mesaj içeriği ya da anahtar taşımaz.

### Kendin doğrulaman

Kripto iki kez ve birbirinden bağımsız yazıldı: macOS'ta CryptoKit, Android'de JCE. İkisinin
uyuştuğunu iki betik kanıtlıyor; betikler her push'ta CI'da da çalışıyor:

```bash
scripts/verify-crypto.sh       # aynı vektörler: anahtar kodlaması, HKDF, nonce düzeni, GCM etiketi, SAS
scripts/verify-handshake.sh    # gerçek Swift ve Kotlin oturum kodu, loopback üzerinden
```

İlki iki gerçeklemeyi vektör vektör karşılaştırır. İkincisi Swift'teki gerçek `Session.accept` ile
Kotlin'deki gerçek `Session.connect`'i konuşturur ve şunlara bakar: çerçeve sırası, doğrulama
turu, sabitlenen anahtar kontrolü, 6 haneli kodun iki tarafta da tutması ve her yönde 12
çerçevenin sayaç sırasına göre gelmesi.

İkisi birden var çünkü birinin geçmesi diğerini garanti etmiyor. Geliştirme sırasında vektörler
tutarken el sıkışma başarısızdı; macOS'ta ikinci ve üçüncü Diffie-Hellman işlemlerinin sırası
ters yazılmıştı.

Güvenlik açığı bildirmek için herkese açık bir issue açma; [SECURITY.md](../SECURITY.md)'de anlatılan
özel bildirim yolunu kullan.

## Nasıl çalışır

Sunucu Mac tarafı. `_andromac._tcp` servisini, sistemin verdiği bir portta Bonjour ile duyurur.
Telefon istemcidir; önce en son çalışan adresi dener, o tutmazsa servisi aramaya başlar.

```mermaid
sequenceDiagram
    participant P as Android telefon
    participant M as Mac

    Note over M: _andromac._tcp servisini Bonjour ile duyurur
    P->>M: TCP bağlantısı, önce son bilinen adres
    P->>M: protokol sürümü, geçici anahtar A
    M->>P: protokol sürümü, geçici anahtar B, şifreli(kalıcı anahtar B, nonce B taahhüdü)
    Note over P: ECDH(eA, eB) ile açar, kalıcı anahtar B'yi sabitlenenle karşılaştırır<br/>Uyuşmazsa burada kapatır; telefonun anahtarı telefondan çıkmaz
    P->>M: şifreli(kalıcı anahtar A), yalnızca Mac'in kalıcı gizli anahtarıyla okunur
    Note over P,M: dh1 = ECDH(eA, eB) ileri gizlilik<br/>dh2 = ECDH(sA, eB) telefonu doğrular<br/>dh3 = ECDH(eA, sB) Mac'i doğrular<br/>HKDF-SHA256 her yön için bir anahtar türetir
    P->>M: AES-256-GCM(transcript ‖ nonce A), nonce 0
    M->>P: AES-256-GCM(transcript ‖ nonce B), nonce 0
    Note over P,M: Uyuşmazlık ya da taahhüdüne uymayan nonce B bağlantıyı burada kapatır
    Note over P,M: İki ekranda da aynı 6 hane çıkar; transcript ‖ nonce A ‖ nonce B'den türetilir
    P-->>M: Kullanıcı telefonda onaylar
    M-->>P: Kullanıcı Mac'te onaylar
    Note over P,M: Her taraf diğerinin kalıcı anahtarını sabitler
    P->>M: hello, pil, bildirim, medya, pano
    M->>P: 240 sn'de bir ping, pano, eylemler, kontroller
```

### Güven modeli

El sıkışma, NIST P-256 üzerinde bir Noise-KK deseni. Her cihazın uzun ömürlü bir anahtar çifti
var; her oturumda ayrıca yeni bir geçici çift üretiliyor. Bugün kaydedilen bir oturum, yarın
cihazlardan biri ele geçse bile çözülemez. Açıkta yalnızca geçici anahtarlar gider. Mac'in uzun
ömürlü anahtarı geçici sırla şifrelenmiş olarak gelir. Telefon kendi anahtarını ancak Mac'inkini
sabitlenenle karşılaştırdıktan sonra gönderir ve onu yalnızca gerçek Mac'in okuyabileceği biçimde
şifreler. Ağı dinleyen biri iki rastgele oturum anahtarı görür; porta cevap veren bir yabancı
telefon hakkında hiçbir şey öğrenmez. Üç Diffie-Hellman sonucu, bir transcript özetiyle birlikte
HKDF-SHA256'dan geçirilip her yön için birer AES-256-GCM anahtarına dönüşür. Ardından iki taraf
da transcript'i şifreleyip diğerinin gönderdiğini kontrol eder. Uyuşmazsa bağlantı, hiçbir
uygulama mesajı okunmadan kapanır.

Buraya kadarı araya kimsenin girmediğini gösterir ama hangi cihazların konuştuğunu kanıtlamaz.
6 haneli kod bunun için var. Kod, el sıkışmanın tüm transcript'inden ve iki tarafın birer
rastgele nonce'undan türetilir. Mac, telefon kendi nonce'unu açıklamadan önce kendi nonce'una bir
özetle taahhüt verir. Araya giren bir cihaz, her kodun kendi yarısını diğer yarıyı görmeden
sabitlemek zorunda kalır. Deneme başına şansı milyonda birdir ve her başarısız deneme ekranlarda
görünür bir uyuşmazlık bırakır. Yalnızca kalıcı anahtarlardan türetilen bir kodda bu özellik
olmazdı; saldırgan iki ekran aynı sayıyı gösterene kadar çevrimdışı anahtar çifti üretebilirdi.
KDE Connect'in 2025'te düzelttiği zafiyet bu sınıftandı. Haneleri karşılaştır, iki cihazda da
onayla; her taraf diğerinin kalıcı açık anahtarını kalıcı olarak sabitler.

Bundan sonrası sabitlenen anahtarın işi. Telefon tek bir Mac'i sabitler ve orada kural mutlaktır.
Mac bir telefon kümesi sabitler; orada tanımadığı bir anahtar bilinmeyen bir cihaz sayılır ve
sıradan bir ilk temas isteği çıkarır. Bayt bayt uyuşmayan bir anahtar reddedilir ve "anahtar
değişti" diye bildirilir. Kabul edilmez, yeniden sabitlenmez; tekrar Eşleştir'e dokunmak da bunu
temizlemez. Uygulamalardan birini yeniden kurmadığın hâlde bu uyarıyı görüyorsan bir sorun var
demektir, reddet. Mac'te bir kodu reddetmek o anahtarı giderek uzayan bir süre susturur; süre bir
dakikadan başlar ve bir saate kadar ikiye katlanır. Yabancı biri eşleştirme penceresini dırdıra
çeviremez. Bonjour kaydında anahtar yok ve kaydın bu kararda payı yok; yalnızca el sıkışma
sırasında kanıtlanan anahtar sayılır. Adlar için de aynısı geçerli. Bonjour kaydındaki ad yalnızca
Mac'i bulmaya yarar; bağlandıktan sonra gösterilen ad şifreli oturumun içinden gelir.

Kablo üzerindeki biçimin tamamı [docs/PROTOCOL.md](PROTOCOL.md) dosyasında.

### Diğer araçlarla karşılaştırma

Dosya transferi eklenmeden önce Syncthing, LocalSend, KDE Connect, Quick Share, AirDrop, Magic
Wormhole ve Blip'in güven modelleri ile transfer protokolleri yan yana okundu. Belgelenmiş bir
zayıflığı ya da yayımlanmış bir güvenlik duyurusu olan her tasarımda AndroMac farklı davranır.

| Soru | Diğerlerinde | AndroMac'te |
|---|---|---|
| Uygulamayla kim konuşabilir? | LocalSend, isteğe bağlı bir PIN'in ardında yerel ağdaki her cihazdan transfer kabul eder; parmak izi hatırlanır ama doğrulanmaz ([issue #162](https://github.com/localsend/localsend/issues/162)). KDE Connect ve Syncthing doğrulanmamış keşif paketlerini kabul edip güvene sonra karar verir. | El sıkışmayı yalnızca sabitlenmiş anahtar tamamlayabilir. Transfer başına PIN yok; eşleştirme zaten PIN'dir. Keşif yalnızca bir ipucudur, kanıtı el sıkışma verir. |
| Eşleştirmede gösterilen kod sahte olabilir mi? | KDE Connect'in 8 onaltılık karakterlik kodu iki sertifikanın özetiydi ve kaba kuvvetle bulunabiliyordu ([duyuru, Nisan 2025](https://kde.org/info/security/advisory-20250418-3.txt)); düzeltme özete zaman damgası karıştırıyor. | Kod, taze bir transcript'e ve taahhütle değiş tokuş edilen nonce'lara bağlı. Çevrimdışı üretilemez ve her deneme görünür bir uyuşmazlığa mal olur. |
| Gösterilen cihaz adına güvenilir mi? | KDE Connect, eşleşmiş cihazlar için bile adı düz metin keşif paketinden gösteriyordu; sahtesi yapılabiliyordu. AirDrop, telefon numaranın ve e-postanın özetlerini yakındaki herkese yayınlar; bunlar milisaniyeler içinde geri çözülür ([PrivateDrop, USENIX 2021](https://privatedrop.github.io/)). | Bağlandıktan sonra gösterilen ad şifreli `hello` mesajından gelir. Bonjour kaydında yalnızca bir ad ve protokol sürümü var; anahtar yok, hesaba ya da kişiye bağlı hiçbir şey yok. |
| Kabul'e basmadan önce ne olur? | Quick Share, kabul yanıtından önce yük çerçevelerini işliyordu; bu, uzaktan kod çalıştırmaya kadar zincirlendi ([CVE-2024-38272](https://www.safebreach.com/blog/rce-attack-chain-on-quick-share/)). LocalSend'in Hızlı Kaydet'i herkesten kabul eder. | `file_accept`'ten önce diske hiçbir şey yazılmaz; kabul edilmemiş bir kimliğe ait parça bellek ayrılmadan atılır. Otomatik kabul var ama yalnızca sabitlenmiş cihaz için. |
| Dosya doğrulanır mı? | KDE Connect yalnızca TLS'ye güvenir, uygulama katmanında özet yok. Syncthing her bloğu özetler. LocalSend'de özet isteğe bağlı. | Her parça 512 KiB ile sınırlı. Dosyanın tamamı, son adını almadan önce SHA-256 ile doğrulanır; o ana kadar bir `.part` dosyası ya da bekleyen bir medya kaydıdır. |
| Dosya adı ne olacak? | Quick Share zincirinde alıcı tarafında bir yol geçişi (path traversal) vardı. AirDrop, bilinmeyen türlerde uzantının arkasına " 2" ekler. | Alıcı yalnızca son yol bileşenini tutar, denetim karakterlerini ve baştaki noktaları atar, uzunluğu sınırlar ve kopyaları uzantıdan önce numaralar. |
| Gelen dosya açılır mı? | KDE Connect'in `open` bayrağı dosyayı gelir gelmez başlatır. | Hiçbir zaman. macOS, tarayıcı indirmesine konan karantina bayrağının aynısını koyar. Android dosyayı MediaStore üzerinden İndirilenler'e yazar; uygulamanın depolama iznine ihtiyacı yoktur. |
| Bir yabancı uygulamayı tüketebilir mi? | KDE Connect doğrulanmamış bağlantılarla açık tutulabiliyordu ([CVE-2020-26164](https://nvd.nist.gov/vuln/detail/CVE-2020-26164)). | En fazla dört bekleyen el sıkışma, her biri 10 saniye. 30 saniyede bir eşleştirme sorusu, yön başına tek transfer ve 8 parçalık (4 MiB) sınırlı pencere; karşı taraf telefonun belleğini şişiremez. |
| Yerel ağdan bir şey çıkar mı? | Blip ve Magic Wormhole doğrudan yol bulunamayınca internet üzerinden aktarır; Syncthing'de küresel keşif ve aktarıcılar var. | Hiçbir zaman. Geri düşülecek bir aktarıcı yok. |

Olduğu gibi alınanlar da var. LocalSend'in transfer başına kimlikli teklif-sonra-kabul akışı,
Syncthing'in parçala-ve-özetle disiplini ile geçici dosya sonra yeniden adlandırma yaklaşımı,
Quick Share'in iki ekranda onaylanan kısa sayı fikri ve bir şey olmadan önce göndereni ve boyutu
söyleyen kabul penceresi. Magic Wormhole'un parolayla doğrulanmış anahtar değişimi iki yabancı
için uygun ama burada gereksiz. Sabitlenmiş uzun ömürlü anahtarlarla karşılıklı doğrulama zaten
çözülmüş durumda; transfer başına bir kod yalnızca fazladan dokunuş eklerdi.

Ağın hâlâ gördüğü şunlar: Bonjour kaydındaki Mac adı ve ona bir telefonun bağlandığı. İki uzun
ömürlü anahtar da el sıkışmada şifreli gittiği için pasif bir dinleyici hangi telefon olduğunu
anlayamaz. Aktif biri yalnızca Mac'in anahtarını öğrenir; keşfedilebilir taraf olmanın bedeli bu.
O da rastgele bir anahtardır, içinde ad ya da hesap yoktur.

## Enerji

Telefon pilini veri miktarından çok radyonun uyanma sıklığı tüketir. Bu yüzden telefonda hiç
periyodik zamanlayıcı yok. Mac prize takılı olduğu için canlılık kontrolünü Mac yapar: 240
saniyede bir ping atar, telefon yalnızca cevap verir. Pil raporları sistemin zaten yayınladığı bir
broadcast'e biner, dakikada en fazla bir kez. Bildirim ve medya olay tabanlı, kısa birleştirme
pencereleriyle. Eleme radyo uyanmadan önce telefonda yapılır ve bağlantı kurulur kurulmaz mDNS
taraması durur.

Kuralların tamamı ve `dumpsys batterystats` ile nasıl ölçüleceği [docs/ENERGY.md](ENERGY.md)
dosyasında. Mac'te Ayarlar → Ölçümler, boştayken bağlı her telefon için saatte yaklaşık 30 mesaj
göstermeli. Belirgin biçimde fazlası, kurallardan birinin çiğnendiği anlamına gelir.

## Ekran görüntüleri

<table>
<tr>
<td align="center"><img src="images/android-home.png" alt="Android ana ekranı" width="230"></td>
<td align="center"><img src="images/android-home-dark.png" alt="Android ana ekranı, koyu tema" width="230"></td>
<td align="center"><img src="images/android-permissions.png" alt="Android'de İzinler ekranı" width="230"></td>
<td align="center"><img src="images/android-settings.png" alt="Android'de Ayarlar" width="230"></td>
</tr>
<tr>
<td colspan="2" align="center"><img src="images/android-pairing.png" alt="Android'de eşleştirme kodu" width="230"></td>
<td colspan="2" align="center"><img src="images/macos-pairing.png" alt="macOS'ta eşleştirme kodu penceresi" width="380"></td>
</tr>
<tr>
<td colspan="4" align="center"><img src="images/macos-window.png" alt="macOS'ta AndroMac ana penceresi" width="640"></td>
</tr>
<tr>
<td colspan="4" align="center"><img src="images/macos-settings.png" alt="macOS'ta Ayarlar, Cihazlar" width="640"></td>
</tr>
<tr>
<td colspan="4" align="center"><img src="images/macos-settings-sync.png" alt="macOS'ta Ayarlar, Eşitleme" width="640"></td>
</tr>
</table>

## Derleme ve katkı

Araç zinciri, derleme, testler, depo yapısı ve yeni bir dilin nasıl ekleneceği
[CONTRIBUTING.md](../CONTRIBUTING.md)'de (İngilizce). Yayın hattı [RELEASING.md](RELEASING.md)'de,
kablo protokolü [PROTOCOL.md](PROTOCOL.md)'de, enerji kuralları [ENERGY.md](ENERGY.md)'de.

[MIT Lisansı](../LICENSE) ile lisanslanmıştır.
