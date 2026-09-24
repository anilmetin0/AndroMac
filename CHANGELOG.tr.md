# Değişiklik günlüğü

Biçim [Keep a Changelog](https://keepachangelog.com/tr/1.1.0/), sürüm numaraları
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) kuralına göre.

`VERSION` dosyasıyla eşleşen `## <sürüm>` bölümü o kararlı sürümün notlarıdır. Yeni kayıtlar
`## Unreleased` altına yazılır; `VERSION` yükseltilince o bölüm yeni sürümün bölümü olur. Beta
derlemeler bunun yerine commit'lerini listeler.

## Unreleased

## 1.1.0 - 2026-09-24

### Eklenenler

- **Telefonunun ekranı Mac'te.** Telefonun kartındaki yansıtma düğmesine bas, ekranı bir
  pencerede açılsın; fare, klavye ve ses de çalışır. Kablosuz hata ayıklama ya da USB kablo
  üzerinden, artık Mac uygulamasının içinde gelen [scrcpy](https://github.com/Genymobile/scrcpy)
  4.1 ile çalışır. Panel tek seferlik kurulumu adım adım gösterir, gereken ayarı telefonda senin
  için açabilir. Mac'te zaten adb kuruluysa AndroMac onu kullanır. Ayarlar → Ekran yansıtma'da ses,
  ekranı kapatma, uyanık tutma ve çözünürlük sınırı var.
- **Okunabilen ve kendi kendine kurulan güncellemeler.** Bir güncelleme kurulmadan önce neyin
  değiştiğini gösteren bir pencere açılıyor; notlar sen açana kadar birkaç satıra katlı duruyor.
  **Güncellemeleri otomatik kur** açıkken (varsayılan)
  Mac hiçbir şey açık ya da çalışır değilken, telefon ise uygulamadan çıktığında ve yalnızca
  Wi-Fi'dayken kuruyor. Telefon kendiliğinden kurmayı Android 12 ve sonrasında yapıyor; daha eski
  telefonlar önce soruyor. Homebrew ile kurulan Mac `brew upgrade` ile güncelleniyor. **Beta
  güncellemeleri**, sürümler arasında yayınlanan test derlemelerini izliyor.
- **Bildirimlerde görseller.** Sohbet mesajındaki fotoğraf, bildirimin büyük resmi ya da gönderenin
  profil fotoğrafı bildirimle birlikte geliyor ve Mac'te uygulamanın ikonunun yanında küçük resim
  olarak görünüyor. Yalnızca Tam ayarlı uygulamalar için, yalnızca görsel değiştiğinde ve en fazla
  96 KB.
- **Bağlantılar bildirimden açılıyor.** Bildirimde bir web adresi varsa Mac bildiriminde Bağlantıyı
  aç düğmesi çıkıyor, geçmişte ve panelde de yanında bir düğme duruyor.
- **Proje bir dokunuş uzakta.** Telefonda Ayarlar, Mac'te Ayarlar → Genel GitHub'daki depoyu
  açıyor; Mac'in Yardım menüsünde Sorun bildir de var.
- **AndroMac'i sıfırla.** İki uygulamada da Ayarlar, uygulamanın tuttuğu her şeyi silip baştan başlatabiliyor.
- **Mac'ini seç.** Aynı ağda AndroMac çalıştıran birden fazla Mac varsa Eşleştir hangisi olduğunu
  soruyor.
- **Android 17'ye hazır.** Android 17, bir uygulama ağındaki cihazlarla konuşmadan önce izin
  istiyor. AndroMac bu izni artık istiyor ve İzinler kartında zorunlu olarak gösteriyor.

### Değişenler

- **Daha sade bir Mac paneli.** Her telefonun pili üç kez yerine bir kez görünüyor, boşluklar
  daha sıkı, denetimler de geri kalanı bir menüde toplayan tek sıra düğmede. macOS 26 ve sonrasında
  panel, düğmeler ve pencere Liquid Glass kullanıyor. Pencerede geçmişler ve bütün ayar sayfaları
  için tek bir kenar çubuğu var, ⌘, Ayarlar'ı açıyor.
- **Material 3 bir telefon uygulaması.** Yeni renkler, kartlar, anahtarlar, düğmeler ve
  diyaloglar; Android 12 ve sonrasında duvar kağıdının renklerini izliyor.
- **Daha sade bir telefon uygulaması.** Ayarlar'ın üst çubuktaki düğmenin arkasında kendi ekranı
  var. Bağlantı rehberi eşleşince kayboluyor ve bilgi düğmesinin altında bir dokunuş uzakta kalıyor.
  Durum, bağlı olunan ya da bağlanılan Mac'in adını söylüyor; eşleştirme de telefonun gördüğü
  Mac'leri gösteriyor. Yeni pano geçmişi gönderilen ya da gelen son 20 metni listeliyor ve yalnızca
  bellekte tutuyor.
- **Mac uygulaması için tek imza sertifikası.** Yayın derlemeleri artık ad-hoc yerine
  AndroMac'in kendinden imzalı sertifikasıyla imzalanıyor. Hâlâ noter onaylı değiller, bu yüzden
  ilk açılış adımı duruyor; Anahtar Zinciri de bir güncellemeden sonra bir kez sorabilir, **Always
  Allow** de.
- **Aynı anda tek AndroMac.** İkinci bir kopyayı açmak, zaten çalışanı öne getiriyor.
- **Sürümler.** Her sürümün tek bir kararlı yayını var, aradaki derlemeler beta olarak
  yayınlanıyor. Sıradan push'lar kararlı yayını yeniden derlemez. Onu yalnızca elle başlatılan
  kararlı bir çalıştırma ya da mesajında `[stable]` geçen bir commit yeniden yayınlar; bu da
  etiketini taşır.
- **Pile daha hafif.** Telefon Mac'i yalnızca Wi-Fi ya da Ethernet'te ve yalnızca onu son bulduğu
  ağda arıyor. Mac uyurken sessiz kalıyor, ekran kapalıyken pil güncellemelerini bekletiyor, tekrar
  eden bildirimleri atlıyor ve ekran kapalıyken gelen pano isteklerini yok sayıyor. Mac de
  kilitliyken ya da uykudayken panoyu izlemeyi bırakıyor ve daha seyrek uyanıyor.
- **Şifreli geçmiş.** Mac'teki bildirim ve pano geçmişi artık Anahtar Zinciri'ndeki Mac kimliğine
  bağlı bir anahtarla şifreleniyor. 1.0'dan kalan geçmiş, 1.1 onu ilk açtığında dönüştürülüyor.
- **Eşleştirme soruları Mac'te varsayılan olarak Reddet'te**, çünkü ağda biri kapıyı çaldığında
  kendiliğinden açılabiliyorlar.

### Düzeltilenler

- Bir uygulamanın iki adımda yayınladığı bildirim (önce yazı, sonra gönderenin fotoğrafı) önce
  yarım görünmek yerine tek seferde, tam haliyle geliyor. Yeniden bağlanınca gelen tekrar,
  bildirimi yerinde güncelliyor ve saatini koruyor; metni uzayan bir geçmiş satırı da artık
  kaydırılana kadar yarım görünmüyor.
- Mac'te bildirim ya da pano geçmişini temizlemek artık uygulamayı çökertmiyor.
- Birden fazla telefon bağlıyken dosyalar, bildirim yanıtları, kapatmalar ve medya denetimleri
  doğru telefon yerine hepsine gidiyordu. İkinci bir telefon ilkinin adını da değiştirebiliyordu,
  tanımadığın bir telefonun eşleştirme sorusu da eşleşmiş bir telefonun adını gösterebiliyordu.
- Mac'inle eşleşmiş bir telefon, aynı Wi-Fi'daki başka birinin Mac'ini kendi Mac'i sanıp
  anahtarın değiştiği uyarısını verebiliyordu. Artık başka Mac'leri sessizce atlıyor.
- Mac, telefonun adı yerine "SM S926B" gibi model kodunu gösteriyordu.
- Mac penceresinde bir sayfaya tıklamak kenar çubuğunu başlık çubuğunun altına kaydırabiliyordu,
  telefon kartındaki ⋯ menüsü açılmıyordu ve Çık iki saniye sürüyordu.
- Dosya aktarımının ortasında yeniden bağlanan bir telefon aktarımı takılı bırakıyordu.
- Mac'te tek bir telefonu unutmak hepsinin bağlantısını kesiyordu.
- Mac bağlandıktan hemen sonra kapattığında telefon durmadan yeniden arayabiliyordu.
- Android'deki herhangi bir sistem ayarının her değişikliği Mac'e gidiyordu. Artık yalnızca zil,
  ses düzeyi ve Kablosuz hata ayıklama gidiyor.
- Aynı anda gönderilen iki mesaj sırasız ulaşıp bağlantıyı düşürebiliyordu.
- Tekrar dene ya da eşleştirme kaldırma sonrası Mac iki kez dinlemeye başlayabiliyordu; oturum
  açılışında kilitli kalan Anahtar Zinciri de telefonlarda "anahtar değişti" uyarısına yol
  açıyordu.

### Güvenlik

- Telefonlar kısa, 32 bitlik bir parmak iziyle ayırt ediliyordu; eşleşmiş bir cihaz bunu kaba
  kuvvetle bulup başka bir telefonun yerine geçebilirdi. Artık anahtarın tam özeti kullanılıyor.
- El sıkışmanın ortasında unutulan bir telefon gizli bir oturum tutabiliyordu. Güven artık el
  sıkışma bitince yeniden denetleniyor.
- Telefon, Yalnızca başlık ya da Kapalı ayarlı uygulamalarda bile Mac'in istediği bildirim
  eylemlerini çalıştırıyordu.
- Bir dosya adı, gerçek uzantısını Unicode yön işaretlerinin arkasına saklayabiliyordu. İki taraf
  da artık bunları siliyor; Android'de alınan bir APK ya da türü bilinmeyen bir dosya, dosyanın
  kendisi yerine İndirilenler'i açıyor.
- Android 10-12L'de "Hassas içeriği asla gönderme" kuralı parola yöneticilerinin koyduğu işareti
  görmüyordu.
- Güncelleyiciler sağlama dosyasında yanlış satırı eşleyebiliyordu. Artık dosya adının birebir
  tutması gerekiyor; Android'de yükleyici de yalnızca bu uygulamayı kabul ediyor.
- Uygulama ikonları artık yalnızca bildirimi gönderen telefondan isteniyor ve kabul ediliyor.

## 1.0.0 - 2026-09-07

İlk genel sürüm. Android telefonun ve Mac'in doğrudan kendi ağın üzerinden konuşur: sunucu yok,
hesap yok, iki tarafta da üçüncü parti kütüphane yok.

### Eklenenler

- **Pil.** Telefonun şarj seviyesi, şarj durumu ve sıcaklığı; menü çubuğunda isteğe bağlı yüzde
  ve pil azaldığında bir uyarı.
- **İki yönde pano.** Mac'te kopyaladığın, otomatik olarak ya da düğmeye bastığında telefona
  gider. Mac panelini açmak telefondan panosunu ister; Hızlı Ayarlar karosu, bildirimdeki düğme ve
  paylaşım menüsü de gönderir. Parola yöneticisinin hassas diye işaretlediği hiçbir şey yerinden
  çıkmaz. Mac son 50 kaydı aranabilir şekilde tutar.
- **Bildirimler.** Telefon bildirimleri, uygulamanın ikonuyla Bildirim Merkezi'ne gelir. Mac'ten
  yanıtla, eylemleri çalıştır ve kapat; bir tarafta kapatmak diğerinde de temizler. Her uygulama
  için Tam, Yalnızca başlık ya da Kapalı seç. Eleme telefonda yapılır, yani Kapalı gerçekten hiçbir
  şey gönderilmemesi demektir. Mac son 200 bildirimi aranabilir şekilde tutar, tek kullanımlık
  kodları da bir kopyalama düğmesine koyar.
- **Medya ve telefon denetimleri.** Çalan parçayı gör, Mac'ten geç, duraklat ya da oynat. Zili ve
  medya sesini ayarla, bir test bildirimi gönder ya da kaybolan telefonu 30 saniyeye kadar çaldır.
- **Dosyalar.** Telefonun paylaşım menüsünden gönder ya da dosyaları Mac paneline bırak. Otomatik
  kabulü açmadıysan alıcı önce onay verir, her dosya SHA-256 ile doğrulanır ve hiçbir şey senin
  yerine açılmaz.
- **Birden fazla telefon.** Aynı Mac'e birden fazla Android eşleştir. Her birinin kendi sekmesi
  ve kendi pano anahtarı olur, bağlantısı ayrı ayrı kesilebilir.
- **Güncellemeler.** İki uygulama da GitHub'ı günde en fazla bir kez denetler, indirdiğini
  yayınlanan sağlama toplamıyla doğrular ve kendisi kurar. Tek bir anahtar bunu kapatır. Mac
  uygulaması Homebrew'da, APK Obtainium'da da var.
- **Pile hafif.** Telefonda hiç zamanlayıcı çalışmaz: bağlantıyı Mac 240 saniyede bir denetler,
  telefon yalnızca yanıt verir. Bunun gerçekte ne kadar trafik olduğunu Mac'te Ayarlar → Ölçümler
  gösterir.
- İki uygulamada da **İngilizce ve Türkçe**. Yeni bir dil, platform başına tek dosya.

### Güvenlik

- Eşleştirme, P-256 üzerinde Noise-KK benzeri bir el sıkışma ve AES-256-GCM kullanır. İki ekranda
  6 haneli bir kodu onaylarsın; kod, ağdaki kimsenin çevrimdışı eşleşme üretemeyeceği şekilde
  kurulur. Bu, KDE Connect'in 2025'te düzelttiği zayıflık.
- Eşleştirmeden sonra iki taraf birbirinin anahtarını sabitler. Değişen bir anahtar reddedilir ve
  bildirilir, asla sessizce kabul edilmez.
- Her oturum yeni anahtarlar kullanır, bu yüzden kaydedilen trafik sonradan çözülemez; tekrar
  oynatılan bir mesaj bağlantıyı kapatır.
- Mac doğrulanmamış bağlantıları ve eşleştirme sorularını sınırlar; Wi-Fi'ındaki bir yabancı
  eşleşmiş telefonu bağlantıdan düşüremez ya da seni sorulara boğamaz.
- Anahtarlar macOS Anahtar Zinciri'nde ve Android Keystore'da durur. Geçmiş yalnızca Mac'te
  tutulur ve eşleştirmeyi kaldırınca silinir. Günlüklerde hiçbir zaman mesaj içeriği bulunmaz.
- Kripto iki kez yazıldı, CryptoKit'te ve JCE'de; iki betik her push'ta iki yarının uyuştuğunu
  denetler.
