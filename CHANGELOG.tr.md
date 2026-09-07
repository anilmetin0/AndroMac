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
  eşleştirme silinmeden duraklatılıp sürdürülebilir. Yeniden kurulan bir telefon yeni bir kodla
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
- **Pano, telefondan Mac'e.** Hızlı Ayarlar karesinden, kalıcı bildirimdeki düğmeden, Android
  paylaşım menüsünden ya da uygulamanın içinden tek dokunuşla. Android arka planda pano okumaya
  izin vermediği için bu yön bilinçli olarak kullanıcı tetiklidir.
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
  iner, mevcut şifreli oturum üzerinden 512 KiB'lik parçalar halinde pencere-1 akış denetimiyle
  gider, son adını almadan önce SHA-256 ile doğrulanır, gelişte adı temizlenir ve asla
  kendiliğinden açılmaz. Mac tarayıcı indirmesi karantina bayrağını koyar. İki uygulamada da
  Ayarlar → Dosyalar.
- **Güncelleme denetimi.** İki uygulamada da varsayılan olarak kapalı. Ayarlar → Güncellemeler'de
  anahtar ve Şimdi denetle var. Açıkken uygulama yalnızca açıldığında ve günde en fazla bir kez
  GitHub yayın API'sine sorar; daha yeni bir paket varsa, ister daha büyük bir sürüm ister aynı
  sürümün başka bir commit'ten derlenmiş hali olsun, sürümünü ve commit'ini bağlantısıyla
  gösterir. Kendi başına hiçbir şey indirmez ya da kurmaz.
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
