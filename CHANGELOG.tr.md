# Değişiklik günlüğü

Biçim [Keep a Changelog](https://keepachangelog.com/tr/1.1.0/), sürüm numaraları
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) kuralına göre.

`VERSION` dosyasındaki sürümle eşleşen `## <sürüm>` bölümü, o sürümün döner paketinin yayın
notlarıdır. Sürüm geliştirmedeyken bu bölüm yerinde düzenlenir; yeni bir sürüm yeni bir bölüm
açar.

## 1.0.0 — 2026-09-07

İlk genel sürüm. Android ve macOS yalnızca yerel ağ üzerinden konuşur: sunucu yok, hesap yok,
iki tarafta da üçüncü parti kütüphane yok.

### Eklendi

- **Eşleştirme.** NIST P-256 üzerinde Noise-KK benzeri el sıkışma, HKDF-SHA256 ile anahtar
  türetme ve AES-256-GCM çerçeveleme. İki ekranda da 6 haneli bir kod çıkar. Kod, oturum
  transcript'ine ve taahhütle değiş tokuş edilen iki nonce'a bağlıdır; bu yüzden ağdaki biri iki
  ekran aynı sayıyı gösterene kadar onu çevrimdışı üretemez. KDE Connect'in 2025'te düzelttiği
  zafiyet sınıfı buydu (CWE-222). İki uzun ömürlü anahtar da şifreli gider: Mac'inki geçici
  sırla, telefonunki yalnızca Mac'in anahtarı sabitlenenle uyuştuktan sonra ve yalnızca o Mac'in
  okuyabileceği şekilde. Bonjour kaydında anahtar yoktur, dolayısıyla ağı dinleyen biri hangi
  telefonun orada olduğunu anlayamaz. Kod onaylanınca karşı tarafın kalıcı açık anahtarı
  sabitlenir; değişen bir anahtar reddedilir ve kullanıcıya bildirilir, sessizce yeniden
  sabitlenmez. Mac'te bir eşleştirme kodunu reddetmek o anahtarı 1, 2, 4 … 60 dakika susturur.
- **Birden fazla telefon.** Bir Mac'e birden fazla Android eşleştirilebilir ve hepsi aynı anda
  bağlı kalabilir. Eşleştirme, bağlanma ve bağlantıyı kesme ayrı şeylerdir: kapalı bir telefon
  "Çevrimdışı"dır, eşleştirmesi silinmez ve 1, 2, 5, 15, 60, 300 saniyelik gecikmelerle kendi
  kendine yeniden bağlanır. Panel bütün cihazları listeler, tıklayınca genişletir; her cihaz
  eşleştirme silinmeden bağlantısı kesilip yeniden kurulabilir. Yeniden kurulan bir telefon yeni bir kodla
  yeni bir cihaz olarak gelir, eski kayıt siz silene kadar görünür kalır; sessizce başarısız olmaz.
- **Cihaz başına pano hedefi.** Birden fazla telefon eşleştirildiğinde her birinin kendi
  "Panomu buraya gönder" anahtarı vardır; kopyalanan metin bir telefona gidip diğerine gitmeyebilir.
- **Pil.** Telefondan seviye, şarj durumu ve sıcaklık. macOS menü çubuğunda isteğe bağlı yüzde,
  panelde çubuk ve seviye %15'in altına düştüğünde tek seferlik uyarı.
- **Pano, Mac'ten telefona.** Kopyaladıkça otomatik ya da yalnızca istediğinde: menü çubuğu
  panelindeki uçak düğmesi panoyu anında gönderir. Seçim Ayarlar → Pano'da. İki durumda da
  üretici kısıtlarını aşmak için ikinci bir yol olarak "Yapıştır" eylemli sessiz bir bildirim
  gelir. Parola yöneticisinin gizli işaretlediği pano (`org.nspasteboard.ConcealedType`) hiç
  gönderilmez; telefonun zaten yaptığı şeyin aynısı.
- **Pano, telefondan Mac'e.** Mac panelini açmak telefondan panosunu ister; telefon da bir anlığına
  odağı alan görünmez bir etkinlikle yanıtlar — "Diğer uygulamaların üzerinde göster" izni varsa
  anında, yoksa tek düğmeli bir bildirimle. Hızlı Ayarlar karesi, kalıcı bildirimdeki düğme ve
  paylaşım menüsü panoyu telefondan göndermeye devam eder. Android arka planda pano okumaya hiç
  izin vermez; bu yönde telefon yanıtlamadan hiçbir şey olmaz.
- **Pano koruması.** Parola yöneticisi ya da OTP alanının
  `ClipDescription.EXTRA_IS_SENSITIVE` ile işaretlediği metin telefondan hiç çıkmaz. Varsayılan
  olarak açık, kapatılabilir.
- **Mac'te pano geçmişi.** İki yöndeki son 50 kayıt; arama, tıklayınca panoya alma, sağ tıkla
  telefona geri gönderme ya da silme.
- **Bildirim aynası.** Bildirimler uygulamanın kendi ikonuyla macOS Bildirim Merkezi'ne düşer.
  Yanıt dahil eylemler Mac'ten tetiklenir, kapatma iki yönde de senkronlanır.
- **Uygulama başına bildirim kademesi.** Tam, Sadece başlık ya da Kapalı; iki cihazdan da
  ayarlanır, telefonda uygulanır. Kapalı'da o uygulama için radyo hiç uyanmaz, Sadece başlık'ta
  içerik telefondan çıkmaz.
- **Bildirim gürültü elemesi.** Grup başlıkları, kalıcı bildirimler, ön plan servisi bildirimleri,
  yalnızca cihaza özel bildirimler ve sessiz kanallar gönderilmeden elenir. Bir seçenek aynalamayı
  yalnızca telefon kilitliyken çalışacak biçimde sınırlar.
- **Mac'te bildirim geçmişi.** Aranabilir son 200 kayıt, yalnızca Mac'te saklanır.
- **Bildirimdeki doğrulama kodu.** Aynalanan bir bildirimde tek kullanımlık kod varsa panel kodu
  bir kopyalama düğmesinin üstünde gösterir. Kopyalama, kodu telefona geri göndermeden ve pano
  geçmişine yazmadan Mac panosuna alır.
- **Medya.** Telefonda çalan parçanın başlığı, sanatçısı ve uygulaması; Mac'ten önceki,
  oynat/duraklat ve sonraki. Yalnızca değişimde gönderilir, ilerleme çubuğu yoktur.
- **Mac'ten telefon denetimleri.** Panel telefonun zil modunu (zil, titreşim, sessiz) ve medya ses
  düzeyini ayarlar; bir de bütün aynalama zincirini dolaşıp geri dönen test bildirimi gönderebilir —
  telefondaki bir izin sorunu, hiçbir şeyin gelmemesi olarak görünür ki en işe yarar yanıt budur.
  Sessize almak telefonda Rahatsız Etmeyin erişimi ister; telefon bunun verilip verilmediğini
  bildirir, Mac de yalnızca başarısız olabilecek bir komut göndermek yerine düğmeyi kapatır.
- **Android'de izin şeridi.** Bildirim izni ya da bildirim erişimi eksikken ana ekranın üstünde
  kapatılabilir bir şerit durur; dokununca doğru ayar ekranını açar. Bildirim izni açılışta
  istenir; çalışma zamanı diyaloğu olmayan bildirim erişimi ise bir kez, gerekçesiyle önerilir.
- **Telefonu bul.** Mac, telefonu en fazla 30 saniye boyunca alarm sesiyle ve titreşimle çaldırır.
  "Buldum" ile, ikinci bir istekle ya da kendiliğinden durur.
- **Bağlantı rehberi.** İki uygulama da genel bir hata yerine hangi adımın takıldığını gösterir.
  Telefonda canlı bir tanı ekranı var, Mac ise doğrudan Yerel Ağ iznine bağlantı verir.
- **Mac'te ölçümler.** Çalışma süresi, gönderilen ve alınan mesaj sayısı, saatlik mesaj, trafik,
  yeniden bağlanma sayısı ve en sık mesaj tipleri. Enerji iddiası böylece güvenilmek yerine
  ölçülebilir.
- **macOS'ta girişte başlatma**, Android'de eşleştirme varsa açılışta başlatma.
- **Uygulama ikonu.** Koyu lacivert zeminde karşılıklı iki ok: giden ve dönen. İki platformda da
  aynı çizim, derleme sırasında koddan üretiliyor; depoda ikonun ikili dosyası hâlâ yok.
- **İki uygulamada da İngilizce ve Türkçe.** Android, uygulama başına dil seçicisini kullanır;
  macOS'ta Ayarlar'da Sistem, İngilizce ve Türkçe seçenekleri var. Yeni bir dil, platform başına
  tek dosya ve sıfır kod değişikliği demek.
- **İki doğrulama betiği.** `verify-crypto.sh`, CryptoKit ve JCE gerçeklemelerini vektör vektör
  karşılaştırır; `verify-handshake.sh`, iki platformun gerçek oturum kodunu loopback üzerinden
  birbiriyle konuşturur. İkisi de her push'ta CI'da çalışır.
- **Dosya transferi.** Telefonun paylaşım menüsünden herhangi bir dosyayı paylaş ya da Mac
  panelinde Dosya gönder… ve sürükle-bırak kullan. Alıcıya diske bir şey yazılmadan önce sorulur;
  otomatik kabulü açarsan eşleşmiş bütün telefonlar için kendiliğinden kabul eder. Dosyalar İndirilenler'e
  iner, mevcut şifreli oturum üzerinden 512 KiB'lik parçalar halinde sınırlı 8 parçalık pencereyle
  (uçuşta 4 MiB, parça başına bir onay) gider, son adını almadan önce SHA-256 ile doğrulanır,
  gelişte adı temizlenir ve asla
  kendiliğinden açılmaz. Mac tarayıcı indirmesi karantina bayrağını koyar. İki uygulamada da
  Ayarlar → Dosyalar.
- **Güncellemeler, uygulama içinde denetlenir ve kurulur.** İki tarafta da varsayılan olarak
  açık; anahtar Ayarlar → Güncellemeler'de. Uygulama yalnızca açıldığında ve günde en fazla bir
  kez GitHub yayın API'sine sorar, bulduğunu her sürüm için bir kez önerir: Şimdi kur, Sonra ya da
  Bu sürümü atla. Kurulum, yayın dosyasını indirir, o yayınla yayınlanan `SHA256SUMS.txt` ile
  doğrular ve ancak ondan sonra uygulamayı değiştirir — Mac kendi paketini takas edip yeniden
  başlar, telefon APK'yı Android'in kurucusuna verir; kurucu onay ister ve imzayı denetler. Eksik
  ya da uyuşmayan bir sağlama toplamı güncellemeyi durdurur. Daha yeni paket, daha büyük bir sürüm
  ya da aynı sürümün başka bir commit'ten derlenmiş halidir.
- **APK için QR kod.** Ayarlar → Güncellemeler, sürüm sayfasının QR kodunu çizer; telefona
  kurulum için adres yazmak gerekmez. Kod yerel bir sabitten çizilir, hiçbir şey indirmez, bu
  yüzden güncelleme denetimi kapalıyken de çalışır.
- **Homebrew.** `brew tap anilmetin0/andromac https://github.com/anilmetin0/AndroMac`, ardından
  `brew install --cask andromac`. Cask güncel paketi yayın API'sinden bulur, bu yüzden
  `brew upgrade --cask --greedy-latest andromac` ile güncellenir.
- **Obtainium.** Yayın APK'sı her sürümde aynı anahtarla imzalanır, güncellemeler yerinde kurulur.
  Obtainium etiket adına baktığı için aynı sürümün yeni paketini yalnızca "yayın tarihini sürüm
  olarak kullan" seçeneği açıkken fark eder.
- **Diğer araçlarla karşılaştırma.** README'nin güven modeli bölümü AndroMac'i Syncthing,
  LocalSend, KDE Connect, Quick Share, AirDrop, Magic Wormhole ve Blip ile yan yana koyuyor; her
  kararı şekillendiren güvenlik duyurularıyla birlikte.
- Sürüm sıralaması, güncelleme denetimi, dosya adı temizleme ve parça hesabı için iki tarafta da
  CI'da çalışan **birim testleri**.

### Değişti

- **Telefonda izinler.** Kurulum bölümü yerine ana ekranda her zaman duran bir İzinler kartı var:
  tek satırda "Tümü verildi" ya da kaç iznin eksik olduğu, altında eksik olanlar ve arkasında beş
  iznin tamamını Verildi/Verilmedi ve Zorunlu/Önerilir/İsteğe bağlı notuyla listeleyen İzinler
  ekranı.
- **Telefonda Bağlantı ekranı.** Durum, Mac'in adı ve son adresi, Otomatik yeniden bağlan
  anahtarı, Şimdi bağlan ve Bu Mac'i unut (⋮ menüsünden buraya taşındı).
- **Yeniden bağlanma.** Bekleme tavanı ekran açıkken 60 sn, kapalıyken 300 sn; ekranı açmak hemen
  bir deneme başlatır. Kalıcı bildirim artık geri sayım göstermiyor, "Mac bekleniyor" yazıyor.
- **Telefondan Mac'e pano.** Telefonda AndroMac'i açmak mevcut panoyu, her kopya için bir kez,
  Mac'e gönderir; öteki yollar duruyor.
- **Mac'te cihaz sekmeleri.** Birden fazla telefon eşliyken panel onları genişleyen satırlar yerine
  cihaz kartının üstünde sekmeler olarak gösterir.
- **Mac'te Ayarlar.** Genel, Eşitleme, Pano, Bildirimler, Dosyalar, Cihazlar, İzinler, Ağ,
  Güncellemeler, Ölçümler ve Gizlilik bölümlü bir kenar çubuğu. Eşitleme'ye düşük pil eşiği
  (%10, %15, %20 ya da %30), Bildirimler'e ses anahtarı eklendi; İzinler, Bildirimler, Yerel Ağ ve
  Anahtar Zinciri erişiminin durumunu ilgili Sistem Ayarları bölmesine giden düğmeyle gösterir.
  AndroMac için macOS bildirimleri kapalıyken panel tek satırlık uyarı verir.
- **Hareket.** Telefonda ayrıntı ekranları kayarak açılıp kapanır; Mac'te cihaz sekmesi, pencere
  sekmesi ya da ayar bölümü değişince geçiş solarak olur. Mac'teki köşe yarıçapları tek ölçekten gelir.
- **Menü çubuğu simgesi.** Sağ tıklama AndroMac'i aç, Ayarlar ve Çık seçeneklerini açar.
- **Yayın dosyaları.** Apple Silicon için tek DMG, `AndroMac-<sürüm>-macOS-arm64.dmg`, ve her
  telefon için tek APK, `AndroMac-<sürüm>-android.apk`. Yayın başlığı `AndroMac <sürüm>`; iki
  güncelleme denetimi de commit'i etiketin hedefinden okur. Mac güncelleyicisi DMG'den kurar.

### Düzeltildi

- **Diğer uygulamaların üzerinde göster** hiç çalışmıyordu: uygulama `SYSTEM_ALERT_WINDOW` iznini
  bildirmediği için Android'in listesinde yoktu ve denetim hep başarısızdı.
- Mac uygulamasından çıkmak her seferinde iki saniye sürüyordu: kapanış ana iş parçacığını
  beklerken ona geçmeye de çalışıyordu. Artık anında kapanıyor.
- Anahtar Zinciri sorusu açıkken menü çubuğu donabiliyordu; cihaz listesi ile kimlik okuması
  aynı kilidi paylaşıyordu. Artık ayrı kilitler var.
- Mac aranırken ana ekran artık titremiyor: aynı bağlantı durumu art arda yayınlanmıyor.

### Güvenlik

- Her oturumda geçici anahtarlar kullanılır, bu da ileri gizlilik sağlar. Nonce'lar yön başına
  sayaçtır; tekrar saldırısı bağlantıyı kapatır ve nonce tekrarı imkânsızdır.
- El sıkışma bitmeden hiçbir uygulama mesajı işlenmez. macOS tarafında 10 saniyelik el sıkışma
  zaman aşımı, eşzamanlı doğrulanmamış bağlantı sınırı ve eşleştirme sorusu için hız sınırı var;
  özel adres aralıklarının dışından gelen bağlantılar reddedilir. Kurulu bir oturum ancak yeni
  bağlantının el sıkışması başarıyla bittikten sonra bırakılır, yani ağdaki başka bir cihaz
  eşleşmiş telefonu düşüremez.
- Çerçeveler 1 MiB ile sınırlı ve alıcı, gönderene güvenmek yerine her alan için kendi uzunluk
  sınırlarını uygular.
- Kimlik anahtarı macOS'ta Keychain'de; Android'de ise Android Keystore'da duran, dışarı
  çıkarılamayan bir AES-256-GCM anahtarıyla sarmalanmış olarak saklanır.
- Geçmişler yalnızca Mac'te tutulur ve eşleştirme kaldırılınca silinir. Kayıtlar hiçbir zaman
  mesaj içeriği ya da anahtar taşımaz.
- İş akışı yayın işi dışında salt okunur izinle çalışır. Dependabot action'ları ve Gradle
  eklentilerini haftalık izler.
