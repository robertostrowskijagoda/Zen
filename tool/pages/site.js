// Shared script of all the Zen pages: the header, the footer and the icons,
// the language of the visitor (21 languages; "?lang=xx", the saved choice
// "zen-lang", then the browser's languages) and a few helpers. Every page
// holds its own texts (TEXTS, English and the other languages) and calls
// Zen.init({texts: TEXTS, links: {...}, onLang: function () {...}}); the
// texts shared by all pages are in COMMON below. Elements with data-i="key"
// get the text of that key (markup: **bold**, `code`, [label|key] for a link
// of the page's links, never HTML), data-ia / data-ial / data-it the
// alt / aria-label / title attribute. Screenshots (shots/<lang>/) follow the
// language, and .gallery rows scroll with their buttons and the arrow keys.
(function () {
  "use strict";

  var cur = document.currentScript;
  // The way up to the site's root: "", "../", "../../".
  var ROOT = String((cur && cur.getAttribute("src")) || "site.js").replace(/site\.js(\?.*)?$/, "");
  var STORE_KEY = "zen-lang";
  var REPO = "https://github.com/robertostrowskijagoda/Zen";
  var URLS = {
    repo: REPO,
    issues: REPO + "/issues",
    newIssue: REPO + "/issues/new",
    discord: "https://discord.gg/g4vHvpKV37",
    donate: "https://buycoffee.to/zen",
    releases: REPO + "/releases/latest",
    sums: REPO + "/releases/latest/download/SHA256SUMS",
    docs: REPO + "/blob/main/docs/",
    privacy: REPO + "/blob/main/docs/PRIVACY.md",
    terms: REPO + "/blob/main/docs/TERMS.md",
    license: REPO + "/blob/main/LICENSE"
  };

  // Names of the languages in the picker, each in its own language.
  var NAMES = {
    en: "English", pl: "Polski", id: "Bahasa Indonesia", cs: "Čeština",
    de: "Deutsch", es: "Español", fr: "Français", it: "Italiano",
    hu: "Magyar", nl: "Nederlands", pt: "Português", ro: "Română",
    vi: "Tiếng Việt", tr: "Türkçe", ru: "Русский", uk: "Українська",
    ar: "العربية", hi: "हिन्दी", zh: "中文", ja: "日本語", ko: "한국어"
  };
  var RTL = { ar: true };
  // The languages the app's screenshots are made in (tool/screenshots/shots.dart);
  // every other language shows the English ones.
  var SHOT_LANGS = ["pl", "en"];
  var ALIASES = { "in": "id", "iw": "he", "nb": "en", "no": "en" };
  // The Open Graph locale of each language (og:locale of a page's link
  // preview).
  var LOCALES = {
    en: "en_US", pl: "pl_PL", id: "id_ID", cs: "cs_CZ", de: "de_DE", es: "es_ES",
    fr: "fr_FR", it: "it_IT", hu: "hu_HU", nl: "nl_NL", pt: "pt_BR", ro: "ro_RO",
    vi: "vi_VN", tr: "tr_TR", ru: "ru_RU", uk: "uk_UA", ar: "ar_AR", hi: "hi_IN",
    zh: "zh_CN", ja: "ja_JP", ko: "ko_KR"
  };

  // The texts every page shows (header, footer, the buttons of the home,
  // door and install pages).
  var COMMON = {
    "en": {"navLabel": "Main", "navInstall": "Install", "navGuide": "Guide", "navFeatures": "Features", "navSupport": "Support", "navAbout": "About", "navPromo": "Materials", "langLabel": "Language", "skip": "Skip to content", "footPrivacy": "Privacy policy", "footTerms": "Terms of use", "footLicense": "License", "footCode": "Source code", "footNote": "Zen is free software (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS and macOS are trademarks of Apple Inc.; Windows is a trademark of Microsoft; Android is a trademark of Google LLC. Zen is not affiliated with or endorsed by them.", "open": "Open in Zen", "copy": "Copy code", "copied": "Copied ✓", "getTitle": "Get Zen", "getLead": "Free, no sign-up, no ads. It takes a minute.", "dlAndroid": "Download for Android", "dlWindows": "Download for Windows", "dlLinux": "Download for Linux", "dlMac": "Download for Mac", "dlIphone": "Download Zen for iPhone", "instIphone": "Install on iPhone", "instMac": "Install on Mac", "otherSystem": "Other system", "otherSystems": "Other systems:", "moreInstall": "All install options and help", "whatIsZen": "What is Zen?", "recommended": "Recommended", "trouble": "If something goes wrong", "otherWays": "Other ways", "allSystems": "All systems", "nextTitle": "Zen is installed. What now?", "nextText": "Add your first friend and learn the basics.", "nextBtn": "How to use Zen", "versionLine": "Latest version: {version} ({date})", "fpUnknown": "shown with each release on GitHub", "tocLabel": "On this page", "honestTitle": "Honestly:", "thanks_t": "Thanks", "thanks_1": "Thanks to **[Yggdrasil|https://yggdrasil-network.github.io/]**, the open, encrypted mesh network Zen runs on, and **[SideStore|https://sidestore.io/]**, which installs Zen on an iPhone and keeps it renewed right on the phone.", "shotsTitle": "See it in action", "shotsSub": "Real screens of the app with a made-up demo account, light or dark as your device is set.", "filmsTitle": "In motion", "galleryLabel": "Screenshots of Zen", "galleryPrev": "Previous screenshot", "galleryNext": "Next screenshot", "sh_chats": "Chats", "sha_chats": "The chat list: a group and conversations with friends, their photos, unread counts and who is online.", "sh_conversation": "A conversation", "sha_conversation": "A conversation with a photo, a voice message, emoji reactions and the delivery ticks.", "sh_group": "Group chat", "sha_group": "A group chat of four friends with a photo and reactions.", "sh_feed": "Feed", "sha_feed": "The feed: friends' posts in order, one with a photo.", "sh_graph": "Friends graph", "sha_graph": "The friends graph in presence mode: who is online, in the background or offline, and friends of friends around them.", "sh_graphTimeline": "Graph timeline", "sha_graphTimeline": "The friends graph's timeline: a slider through the days the circle of friends grew.", "sh_nearby": "People nearby", "sha_nearby": "People nearby: friends passed yesterday with the times, and how many other Zen users were around, kept only on the phone.", "sh_notifications": "Notifications and sounds", "sha_notifications": "Notification and sound settings: what a notification shows, in-app sounds and which kinds notify.", "sh_storage": "Data and storage", "sha_storage": "Data and storage: how much space Zen takes, split into posts, media, backups and other data, with the limit.", "sh_lock": "Lock screen", "sha_lock": "The lock screen: Zen is locked and asks for the app password, while messages keep arriving.", "sh_desktop": "On a computer", "sha_desktop": "Zen on a computer: the side rail and the chat list in a wide window.", "fl_send": "Sending a message", "fla_send": "A short animation: typing a message to a friend and sending it.", "fl_graph": "The graph growing", "fla_graph": "A short animation: the friends graph growing over a year, friend by friend.", "footPromo": "Promo materials"},
    "pl": {"navLabel": "Główne", "navInstall": "Instalacja", "navGuide": "Poradnik", "navFeatures": "Funkcje", "navSupport": "Pomoc", "navAbout": "O Zen", "navPromo": "Materiały", "langLabel": "Język", "skip": "Przejdź do treści", "footPrivacy": "Polityka prywatności", "footTerms": "Regulamin", "footLicense": "Licencja", "footCode": "Kod źródłowy", "footNote": "Zen to wolne oprogramowanie (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS i macOS są znakami towarowymi Apple Inc.; Windows jest znakiem towarowym Microsoftu; Android jest znakiem towarowym Google LLC. Zen nie jest z nimi powiązany ani przez nie popierany.", "open": "Otwórz w Zen", "copy": "Skopiuj kod", "copied": "Skopiowano ✓", "getTitle": "Pobierz Zen", "getLead": "Za darmo, bez rejestracji i reklam. Zajmie minutę.", "dlAndroid": "Pobierz na Androida", "dlWindows": "Pobierz na Windows", "dlLinux": "Pobierz na Linuksa", "dlMac": "Pobierz na Maca", "dlIphone": "Pobierz Zen na iPhone’a", "instIphone": "Zainstaluj na iPhonie", "instMac": "Zainstaluj na Macu", "otherSystem": "Inny system", "otherSystems": "Inne systemy:", "moreInstall": "Wszystkie sposoby instalacji i pomoc", "whatIsZen": "Czym jest Zen?", "recommended": "Polecany sposób", "trouble": "Gdy coś pójdzie nie tak", "otherWays": "Inne sposoby", "allSystems": "Wszystkie systemy", "nextTitle": "Zen jest zainstalowany. Co dalej?", "nextText": "Dodaj pierwszego znajomego i poznaj podstawy.", "nextBtn": "Jak używać Zen", "versionLine": "Najnowsza wersja: {version} ({date})", "fpUnknown": "podany przy każdym wydaniu na GitHubie", "tocLabel": "Na tej stronie", "honestTitle": "Szczerze:", "thanks_t": "Podziękowania", "thanks_1": "Dziękujemy **[Yggdrasil|https://yggdrasil-network.github.io/]**, otwartej, szyfrowanej sieci mesh, na której działa Zen, oraz **[SideStore|https://sidestore.io/]**, który instaluje Zen na iPhonie i odnawia go na samym telefonie.", "shotsTitle": "Zobacz, jak działa", "shotsSub": "Prawdziwe ekrany aplikacji z wymyślonym kontem pokazowym, jasne albo ciemne, jak w Twoim urządzeniu.", "filmsTitle": "W ruchu", "galleryLabel": "Zrzuty ekranu Zen", "galleryPrev": "Poprzedni zrzut", "galleryNext": "Następny zrzut", "sh_chats": "Czaty", "sha_chats": "Lista czatów: grupa i rozmowy ze znajomymi, ich zdjęcia, nieprzeczytane wiadomości i kto jest w sieci.", "sh_conversation": "Rozmowa", "sha_conversation": "Rozmowa ze zdjęciem, wiadomością głosową, reakcjami emoji i znacznikami doręczenia.", "sh_group": "Czat grupowy", "sha_group": "Czat grupowy czworga znajomych ze zdjęciem i reakcjami.", "sh_feed": "Tablica", "sha_feed": "Tablica: posty znajomych po kolei, jeden ze zdjęciem.", "sh_graph": "Graf znajomych", "sha_graph": "Graf znajomych w trybie obecności: kto jest w sieci, w tle albo poza siecią, a wokół znajomi znajomych.", "sh_graphTimeline": "Oś czasu grafu", "sha_graphTimeline": "Oś czasu grafu znajomych: suwak przez dni, w których rósł krąg znajomych.", "sh_nearby": "Ludzie w pobliżu", "sha_nearby": "Ludzie w pobliżu: znajomi mijani wczoraj z godzinami i ilu innych użytkowników Zen było obok, zapisane tylko w telefonie.", "sh_notifications": "Powiadomienia i dźwięki", "sha_notifications": "Ustawienia powiadomień i dźwięków: co pokazuje powiadomienie, dźwięki w aplikacji i o czym powiadamiać.", "sh_storage": "Dane i pamięć", "sha_storage": "Dane i pamięć: ile miejsca zajmuje Zen, w podziale na posty, multimedia, kopie i inne dane, z limitem.", "sh_lock": "Ekran blokady", "sha_lock": "Ekran blokady: Zen jest zablokowany i prosi o hasło aplikacji, a wiadomości dalej przychodzą.", "sh_desktop": "Na komputerze", "sha_desktop": "Zen na komputerze: pasek boczny i lista czatów w szerokim oknie.", "fl_send": "Wysyłanie wiadomości", "fla_send": "Krótka animacja: pisanie wiadomości do znajomej i wysłanie jej.", "fl_graph": "Rosnący graf", "fla_graph": "Krótka animacja: graf znajomych rośnie przez rok, znajomy po znajomym.", "footPromo": "Materiały promocyjne"},
    "id": {"navLabel": "Utama", "navInstall": "Pasang", "navGuide": "Panduan", "navFeatures": "Fitur", "navSupport": "Bantuan", "navAbout": "Tentang", "navPromo": "Materi", "langLabel": "Bahasa", "skip": "Langsung ke konten", "footPrivacy": "Kebijakan privasi", "footTerms": "Ketentuan penggunaan", "footLicense": "Lisensi", "footCode": "Kode sumber", "footNote": "Zen adalah perangkat lunak bebas (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS, dan macOS adalah merek dagang Apple Inc.; Windows adalah merek dagang Microsoft; Android adalah merek dagang Google LLC. Zen tidak berafiliasi dengan atau didukung oleh mereka.", "open": "Buka di Zen", "copy": "Salin kode", "copied": "Tersalin ✓", "getTitle": "Dapatkan Zen", "getLead": "Gratis, tanpa pendaftaran, tanpa iklan. Hanya semenit.", "dlAndroid": "Unduh untuk Android", "dlWindows": "Unduh untuk Windows", "dlLinux": "Unduh untuk Linux", "dlMac": "Unduh untuk Mac", "dlIphone": "Unduh Zen untuk iPhone", "instIphone": "Pasang di iPhone", "instMac": "Pasang di Mac", "otherSystem": "Sistem lain", "otherSystems": "Sistem lain:", "moreInstall": "Semua cara memasang dan bantuan", "whatIsZen": "Apa itu Zen?", "recommended": "Disarankan", "trouble": "Jika ada masalah", "otherWays": "Cara lain", "allSystems": "Semua sistem", "nextTitle": "Zen sudah terpasang. Lalu apa?", "nextText": "Tambahkan teman pertama Anda dan pelajari dasarnya.", "nextBtn": "Cara memakai Zen", "versionLine": "Versi terbaru: {version} ({date})", "fpUnknown": "ditampilkan di setiap rilis di GitHub", "tocLabel": "Di halaman ini", "honestTitle": "Jujur saja:", "thanks_t": "Terima kasih", "thanks_1": "Terima kasih kepada **[Yggdrasil|https://yggdrasil-network.github.io/]**, jaringan mesh terbuka dan terenkripsi tempat Zen berjalan, dan **[SideStore|https://sidestore.io/]**, yang memasang Zen di iPhone dan memperbaruinya langsung di ponsel.", "shotsTitle": "Lihat cara kerjanya", "shotsSub": "Layar asli aplikasi dengan akun demo rekaan, terang atau gelap sesuai pengaturan perangkatmu.", "filmsTitle": "Dalam gerakan", "galleryLabel": "Tangkapan layar Zen", "galleryPrev": "Tangkapan layar sebelumnya", "galleryNext": "Tangkapan layar berikutnya", "sh_chats": "Obrolan", "sha_chats": "Daftar obrolan: sebuah grup dan percakapan dengan teman, foto mereka, jumlah pesan belum dibaca, dan siapa yang online.", "sh_conversation": "Percakapan", "sha_conversation": "Percakapan dengan foto, pesan suara, reaksi emoji, dan tanda pengiriman.", "sh_group": "Obrolan grup", "sha_group": "Obrolan grup empat teman dengan foto dan reaksi.", "sh_feed": "Beranda", "sha_feed": "Beranda: postingan teman secara berurutan, salah satunya dengan foto.", "sh_graph": "Grafik teman", "sha_graph": "Grafik teman dalam mode kehadiran: siapa yang online, di latar belakang, atau offline, dengan teman dari teman di sekitarnya.", "sh_graphTimeline": "Linimasa grafik", "sha_graphTimeline": "Linimasa grafik teman: penggeser melalui hari-hari saat lingkaran teman bertambah.", "sh_nearby": "Orang di sekitar", "sha_nearby": "Orang di sekitar: teman yang dilewati kemarin beserta jamnya, dan berapa pengguna Zen lain di sekitar, disimpan hanya di ponsel.", "sh_notifications": "Notifikasi dan suara", "sha_notifications": "Pengaturan notifikasi dan suara: apa yang ditampilkan notifikasi, suara dalam aplikasi, dan jenis yang memberi tahu.", "sh_storage": "Data dan penyimpanan", "sha_storage": "Data dan penyimpanan: berapa ruang yang dipakai Zen, dibagi menjadi postingan, media, cadangan, dan data lain, dengan batasnya.", "sh_lock": "Layar kunci", "sha_lock": "Layar kunci: Zen terkunci dan meminta kata sandi aplikasi, sementara pesan tetap masuk.", "sh_desktop": "Di komputer", "sha_desktop": "Zen di komputer: bilah samping dan daftar obrolan di jendela lebar.", "fl_send": "Mengirim pesan", "fla_send": "Animasi singkat: mengetik pesan untuk teman lalu mengirimnya.", "fl_graph": "Grafik yang tumbuh", "fla_graph": "Animasi singkat: grafik teman tumbuh selama setahun, satu teman demi satu teman.", "footPromo": "Materi promosi"},
    "cs": {"navLabel": "Hlavní", "navInstall": "Instalace", "navGuide": "Návod", "navFeatures": "Funkce", "navSupport": "Pomoc", "navAbout": "O Zen", "navPromo": "Materiály", "langLabel": "Jazyk", "skip": "Přejít na obsah", "footPrivacy": "Zásady ochrany soukromí", "footTerms": "Podmínky použití", "footLicense": "Licence", "footCode": "Zdrojový kód", "footNote": "Zen je svobodný software (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS a macOS jsou ochranné známky společnosti Apple Inc.; Windows je ochranná známka společnosti Microsoft; Android je ochranná známka společnosti Google LLC. Zen s nimi není nijak spojen ani jimi podporován.", "open": "Otevřít v Zen", "copy": "Zkopírovat kód", "copied": "Zkopírováno ✓", "getTitle": "Získejte Zen", "getLead": "Zdarma, bez registrace a bez reklam. Zabere to minutu.", "dlAndroid": "Stáhnout pro Android", "dlWindows": "Stáhnout pro Windows", "dlLinux": "Stáhnout pro Linux", "dlMac": "Stáhnout pro Mac", "dlIphone": "Stáhnout Zen pro iPhone", "instIphone": "Instalace na iPhone", "instMac": "Instalace na Mac", "otherSystem": "Jiný systém", "otherSystems": "Jiné systémy:", "moreInstall": "Všechny možnosti instalace a pomoc", "whatIsZen": "Co je Zen?", "recommended": "Doporučeno", "trouble": "Když se něco pokazí", "otherWays": "Jiné způsoby", "allSystems": "Všechny systémy", "nextTitle": "Zen je nainstalovaný. Co dál?", "nextText": "Přidejte prvního přítele a naučte se základy.", "nextBtn": "Jak Zen používat", "versionLine": "Nejnovější verze: {version} ({date})", "fpUnknown": "uvedený u každého vydání na GitHubu", "tocLabel": "Na této stránce", "honestTitle": "Upřímně:", "thanks_t": "Poděkování", "thanks_1": "Děkujeme **[Yggdrasilu|https://yggdrasil-network.github.io/]**, otevřené šifrované síti mesh, na které Zen běží, a **[SideStoru|https://sidestore.io/]**, který Zen instaluje na iPhone a obnovuje ho přímo v telefonu.", "shotsTitle": "Podívejte se, jak funguje", "shotsSub": "Skutečné obrazovky aplikace s vymyšleným ukázkovým účtem, světlé nebo tmavé podle nastavení zařízení.", "filmsTitle": "V pohybu", "galleryLabel": "Snímky obrazovky Zen", "galleryPrev": "Předchozí snímek", "galleryNext": "Další snímek", "sh_chats": "Chaty", "sha_chats": "Seznam chatů: skupina a konverzace s přáteli, jejich fotky, počty nepřečtených zpráv a kdo je online.", "sh_conversation": "Konverzace", "sha_conversation": "Konverzace s fotkou, hlasovou zprávou, reakcemi emoji a značkami doručení.", "sh_group": "Skupinový chat", "sha_group": "Skupinový chat čtyř přátel s fotkou a reakcemi.", "sh_feed": "Zeď", "sha_feed": "Zeď: příspěvky přátel popořadě, jeden s fotkou.", "sh_graph": "Graf přátel", "sha_graph": "Graf přátel v režimu přítomnosti: kdo je online, na pozadí nebo offline, a kolem nich přátelé přátel.", "sh_graphTimeline": "Časová osa grafu", "sha_graphTimeline": "Časová osa grafu přátel: posuvník přes dny, kdy rostl okruh přátel.", "sh_nearby": "Lidé poblíž", "sha_nearby": "Lidé poblíž: přátelé, které jste včera potkali, s časy a kolik dalších uživatelů Zen bylo kolem, uloženo jen v telefonu.", "sh_notifications": "Oznámení a zvuky", "sha_notifications": "Nastavení oznámení a zvuků: co oznámení ukazuje, zvuky v aplikaci a o čem upozorňovat.", "sh_storage": "Data a úložiště", "sha_storage": "Data a úložiště: kolik místa Zen zabírá, rozděleno na příspěvky, média, zálohy a ostatní data, s limitem.", "sh_lock": "Zamykací obrazovka", "sha_lock": "Zamykací obrazovka: Zen je zamčený a žádá heslo aplikace, zatímco zprávy dál přicházejí.", "sh_desktop": "Na počítači", "sha_desktop": "Zen na počítači: boční lišta a seznam chatů v širokém okně.", "fl_send": "Odeslání zprávy", "fla_send": "Krátká animace: psaní zprávy kamarádce a její odeslání.", "fl_graph": "Rostoucí graf", "fla_graph": "Krátká animace: graf přátel roste během roku, přítel po příteli.", "footPromo": "Propagační materiály"},
    "de": {"navLabel": "Hauptmenü", "navInstall": "Installieren", "navGuide": "Anleitung", "navFeatures": "Funktionen", "navSupport": "Hilfe", "navAbout": "Über Zen", "navPromo": "Material", "langLabel": "Sprache", "skip": "Zum Inhalt springen", "footPrivacy": "Datenschutzerklärung", "footTerms": "Nutzungsbedingungen", "footLicense": "Lizenz", "footCode": "Quellcode", "footNote": "Zen ist freie Software (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS und macOS sind Marken von Apple Inc.; Windows ist eine Marke von Microsoft; Android ist eine Marke von Google LLC. Zen ist weder mit ihnen verbunden noch von ihnen unterstützt.", "open": "In Zen öffnen", "copy": "Code kopieren", "copied": "Kopiert ✓", "getTitle": "Zen holen", "getLead": "Kostenlos, ohne Anmeldung, ohne Werbung. Es dauert eine Minute.", "dlAndroid": "Für Android herunterladen", "dlWindows": "Für Windows herunterladen", "dlLinux": "Für Linux herunterladen", "dlMac": "Für Mac herunterladen", "dlIphone": "Zen für iPhone herunterladen", "instIphone": "Auf dem iPhone installieren", "instMac": "Auf dem Mac installieren", "otherSystem": "Anderes System", "otherSystems": "Andere Systeme:", "moreInstall": "Alle Installationswege und Hilfe", "whatIsZen": "Was ist Zen?", "recommended": "Empfohlen", "trouble": "Wenn etwas schiefgeht", "otherWays": "Andere Wege", "allSystems": "Alle Systeme", "nextTitle": "Zen ist installiert. Und jetzt?", "nextText": "Füge deinen ersten Freund hinzu und lerne die Grundlagen.", "nextBtn": "So benutzt du Zen", "versionLine": "Neueste Version: {version} ({date})", "fpUnknown": "bei jeder Version auf GitHub angegeben", "tocLabel": "Auf dieser Seite", "honestTitle": "Ehrlich gesagt:", "thanks_t": "Danke", "thanks_1": "Danke an **[Yggdrasil|https://yggdrasil-network.github.io/]**, das offene, verschlüsselte Mesh-Netz, auf dem Zen läuft, und an **[SideStore|https://sidestore.io/]**, das Zen auf dem iPhone installiert und direkt auf dem Telefon erneuert.", "shotsTitle": "So sieht es aus", "shotsSub": "Echte Bildschirme der App mit einem erfundenen Demokonto, hell oder dunkel wie auf deinem Gerät eingestellt.", "filmsTitle": "In Bewegung", "galleryLabel": "Bildschirmfotos von Zen", "galleryPrev": "Vorheriges Bildschirmfoto", "galleryNext": "Nächstes Bildschirmfoto", "sh_chats": "Chats", "sha_chats": "Die Chatliste: eine Gruppe und Unterhaltungen mit Freunden, ihre Fotos, ungelesene Nachrichten und wer online ist.", "sh_conversation": "Eine Unterhaltung", "sha_conversation": "Eine Unterhaltung mit einem Foto, einer Sprachnachricht, Emoji-Reaktionen und den Zustellhaken.", "sh_group": "Gruppenchat", "sha_group": "Ein Gruppenchat von vier Freunden mit einem Foto und Reaktionen.", "sh_feed": "Pinnwand", "sha_feed": "Die Pinnwand: Beiträge von Freunden der Reihe nach, einer mit Foto.", "sh_graph": "Freundesgraph", "sha_graph": "Der Freundesgraph im Anwesenheitsmodus: wer online, im Hintergrund oder offline ist, und Freunde von Freunden drumherum.", "sh_graphTimeline": "Zeitleiste des Graphen", "sha_graphTimeline": "Die Zeitleiste des Freundesgraphen: ein Schieberegler durch die Tage, an denen der Freundeskreis wuchs.", "sh_nearby": "Leute in der Nähe", "sha_nearby": "Leute in der Nähe: gestern getroffene Freunde mit Uhrzeiten und wie viele andere Zen-Nutzer in der Nähe waren, nur auf dem Telefon gespeichert.", "sh_notifications": "Benachrichtigungen und Töne", "sha_notifications": "Einstellungen für Benachrichtigungen und Töne: was eine Benachrichtigung zeigt, Töne in der App und welche Arten benachrichtigen.", "sh_storage": "Daten und Speicher", "sha_storage": "Daten und Speicher: wie viel Platz Zen belegt, aufgeteilt in Beiträge, Medien, Sicherungen und andere Daten, mit dem Limit.", "sh_lock": "Sperrbildschirm", "sha_lock": "Der Sperrbildschirm: Zen ist gesperrt und fragt nach dem App-Passwort, während weiter Nachrichten ankommen.", "sh_desktop": "Am Computer", "sha_desktop": "Zen am Computer: die Seitenleiste und die Chatliste in einem breiten Fenster.", "fl_send": "Eine Nachricht senden", "fla_send": "Eine kurze Animation: eine Nachricht an eine Freundin tippen und senden.", "fl_graph": "Der Graph wächst", "fla_graph": "Eine kurze Animation: Der Freundesgraph wächst über ein Jahr, Freund um Freund.", "footPromo": "Werbematerial"},
    "es": {"navLabel": "Principal", "navInstall": "Instalar", "navGuide": "Guía", "navFeatures": "Funciones", "navSupport": "Ayuda", "navAbout": "Acerca de", "navPromo": "Materiales", "langLabel": "Idioma", "skip": "Saltar al contenido", "footPrivacy": "Política de privacidad", "footTerms": "Términos de uso", "footLicense": "Licencia", "footCode": "Código fuente", "footNote": "Zen es software libre (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS y macOS son marcas registradas de Apple Inc.; Windows es una marca registrada de Microsoft; Android es una marca registrada de Google LLC. Zen no está afiliado a ellas ni cuenta con su respaldo.", "open": "Abrir en Zen", "copy": "Copiar código", "copied": "Copiado ✓", "getTitle": "Consigue Zen", "getLead": "Gratis, sin registro, sin anuncios. Lleva un minuto.", "dlAndroid": "Descargar para Android", "dlWindows": "Descargar para Windows", "dlLinux": "Descargar para Linux", "dlMac": "Descargar para Mac", "dlIphone": "Descargar Zen para iPhone", "instIphone": "Instalar en iPhone", "instMac": "Instalar en Mac", "otherSystem": "Otro sistema", "otherSystems": "Otros sistemas:", "moreInstall": "Todas las formas de instalar y ayuda", "whatIsZen": "¿Qué es Zen?", "recommended": "Recomendado", "trouble": "Si algo sale mal", "otherWays": "Otras formas", "allSystems": "Todos los sistemas", "nextTitle": "Zen está instalado. ¿Y ahora?", "nextText": "Añade a tu primer amigo y aprende lo básico.", "nextBtn": "Cómo usar Zen", "versionLine": "Última versión: {version} ({date})", "fpUnknown": "indicado en cada versión en GitHub", "tocLabel": "En esta página", "honestTitle": "Con sinceridad:", "thanks_t": "Agradecimientos", "thanks_1": "Gracias a **[Yggdrasil|https://yggdrasil-network.github.io/]**, la red mesh abierta y cifrada sobre la que funciona Zen, y a **[SideStore|https://sidestore.io/]**, que instala Zen en el iPhone y lo renueva en el propio teléfono.", "shotsTitle": "Míralo en acción", "shotsSub": "Pantallas reales de la app con una cuenta de demostración inventada, en claro u oscuro según tu dispositivo.", "filmsTitle": "En movimiento", "galleryLabel": "Capturas de pantalla de Zen", "galleryPrev": "Captura anterior", "galleryNext": "Captura siguiente", "sh_chats": "Chats", "sha_chats": "La lista de chats: un grupo y conversaciones con amigos, sus fotos, los mensajes sin leer y quién está en línea.", "sh_conversation": "Una conversación", "sha_conversation": "Una conversación con una foto, un mensaje de voz, reacciones con emoji y las marcas de entrega.", "sh_group": "Chat de grupo", "sha_group": "Un chat de grupo de cuatro amigos con una foto y reacciones.", "sh_feed": "Muro", "sha_feed": "El muro: las publicaciones de tus amigos en orden, una con foto.", "sh_graph": "Grafo de amigos", "sha_graph": "El grafo de amigos en modo presencia: quién está en línea, en segundo plano o desconectado, y los amigos de amigos alrededor.", "sh_graphTimeline": "Línea de tiempo del grafo", "sha_graphTimeline": "La línea de tiempo del grafo de amigos: un control deslizante por los días en que creció el círculo de amigos.", "sh_nearby": "Gente cerca", "sha_nearby": "Gente cerca: amigos con los que te cruzaste ayer con las horas, y cuántos otros usuarios de Zen había cerca, guardado solo en el teléfono.", "sh_notifications": "Notificaciones y sonidos", "sha_notifications": "Ajustes de notificaciones y sonidos: qué muestra una notificación, los sonidos de la app y qué tipos avisan.", "sh_storage": "Datos y almacenamiento", "sha_storage": "Datos y almacenamiento: cuánto espacio ocupa Zen, dividido en publicaciones, multimedia, copias y otros datos, con el límite.", "sh_lock": "Pantalla de bloqueo", "sha_lock": "La pantalla de bloqueo: Zen está bloqueado y pide la contraseña de la app, mientras siguen llegando mensajes.", "sh_desktop": "En un ordenador", "sha_desktop": "Zen en un ordenador: la barra lateral y la lista de chats en una ventana ancha.", "fl_send": "Enviar un mensaje", "fla_send": "Una animación corta: escribir un mensaje a una amiga y enviarlo.", "fl_graph": "El grafo crece", "fla_graph": "Una animación corta: el grafo de amigos crece durante un año, amigo a amigo.", "footPromo": "Material promocional"},
    "fr": {"navLabel": "Principal", "navInstall": "Installer", "navGuide": "Guide", "navFeatures": "Fonctions", "navSupport": "Aide", "navAbout": "À propos", "navPromo": "Matériel", "langLabel": "Langue", "skip": "Aller au contenu", "footPrivacy": "Politique de confidentialité", "footTerms": "Conditions d’utilisation", "footLicense": "Licence", "footCode": "Code source", "footNote": "Zen est un logiciel libre (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS et macOS sont des marques d’Apple Inc. ; Windows est une marque de Microsoft ; Android est une marque de Google LLC. Zen n’est ni affilié à ces sociétés ni approuvé par elles.", "open": "Ouvrir dans Zen", "copy": "Copier le code", "copied": "Copié ✓", "getTitle": "Obtenir Zen", "getLead": "Gratuit, sans inscription, sans pub. Ça prend une minute.", "dlAndroid": "Télécharger pour Android", "dlWindows": "Télécharger pour Windows", "dlLinux": "Télécharger pour Linux", "dlMac": "Télécharger pour Mac", "dlIphone": "Télécharger Zen pour iPhone", "instIphone": "Installer sur iPhone", "instMac": "Installer sur Mac", "otherSystem": "Autre système", "otherSystems": "Autres systèmes :", "moreInstall": "Toutes les façons d’installer et l’aide", "whatIsZen": "Qu’est-ce que Zen ?", "recommended": "Recommandé", "trouble": "En cas de problème", "otherWays": "Autres façons", "allSystems": "Tous les systèmes", "nextTitle": "Zen est installé. Et maintenant ?", "nextText": "Ajoutez votre premier ami et découvrez les bases.", "nextBtn": "Comment utiliser Zen", "versionLine": "Dernière version : {version} ({date})", "fpUnknown": "indiquée avec chaque version sur GitHub", "tocLabel": "Sur cette page", "honestTitle": "En toute franchise :", "thanks_t": "Remerciements", "thanks_1": "Merci à **[Yggdrasil|https://yggdrasil-network.github.io/]**, le réseau maillé ouvert et chiffré sur lequel Zen fonctionne, et à **[SideStore|https://sidestore.io/]**, qui installe Zen sur iPhone et le renouvelle directement sur le téléphone.", "shotsTitle": "Voyez-le à l’œuvre", "shotsSub": "De vrais écrans de l’app avec un compte de démonstration inventé, en clair ou en sombre selon votre appareil.", "filmsTitle": "En mouvement", "galleryLabel": "Captures d’écran de Zen", "galleryPrev": "Capture précédente", "galleryNext": "Capture suivante", "sh_chats": "Discussions", "sha_chats": "La liste des discussions : un groupe et des conversations avec des amis, leurs photos, les messages non lus et qui est en ligne.", "sh_conversation": "Une conversation", "sha_conversation": "Une conversation avec une photo, un message vocal, des réactions emoji et les coches de remise.", "sh_group": "Discussion de groupe", "sha_group": "Une discussion de groupe entre quatre amis avec une photo et des réactions.", "sh_feed": "Fil", "sha_feed": "Le fil : les publications des amis dans l’ordre, dont une avec photo.", "sh_graph": "Graphe d’amis", "sha_graph": "Le graphe d’amis en mode présence : qui est en ligne, en arrière-plan ou hors ligne, avec les amis d’amis autour.", "sh_graphTimeline": "Chronologie du graphe", "sha_graphTimeline": "La chronologie du graphe d’amis : un curseur à travers les jours où le cercle d’amis a grandi.", "sh_nearby": "Personnes à proximité", "sha_nearby": "Personnes à proximité : les amis croisés hier avec les heures, et combien d’autres utilisateurs de Zen étaient là, gardé seulement sur le téléphone.", "sh_notifications": "Notifications et sons", "sha_notifications": "Réglages des notifications et des sons : ce que montre une notification, les sons de l’app et les types qui notifient.", "sh_storage": "Données et stockage", "sha_storage": "Données et stockage : la place que prend Zen, répartie entre publications, médias, sauvegardes et autres données, avec la limite.", "sh_lock": "Écran de verrouillage", "sha_lock": "L’écran de verrouillage : Zen est verrouillé et demande le mot de passe de l’app, pendant que les messages continuent d’arriver.", "sh_desktop": "Sur un ordinateur", "sha_desktop": "Zen sur un ordinateur : la barre latérale et la liste des discussions dans une fenêtre large.", "fl_send": "Envoyer un message", "fla_send": "Une courte animation : écrire un message à une amie et l’envoyer.", "fl_graph": "Le graphe grandit", "fla_graph": "Une courte animation : le graphe d’amis grandit pendant un an, ami après ami.", "footPromo": "Matériel promotionnel"},
    "it": {"navLabel": "Principale", "navInstall": "Installa", "navGuide": "Guida", "navFeatures": "Funzioni", "navSupport": "Assistenza", "navAbout": "Info", "navPromo": "Materiali", "langLabel": "Lingua", "skip": "Vai al contenuto", "footPrivacy": "Informativa sulla privacy", "footTerms": "Termini d’uso", "footLicense": "Licenza", "footCode": "Codice sorgente", "footNote": "Zen è software libero (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS e macOS sono marchi di Apple Inc.; Windows è un marchio di Microsoft; Android è un marchio di Google LLC. Zen non è affiliato a loro né approvato da loro.", "open": "Apri in Zen", "copy": "Copia il codice", "copied": "Copiato ✓", "getTitle": "Scarica Zen", "getLead": "Gratis, senza registrazione, senza pubblicità. Basta un minuto.", "dlAndroid": "Scarica per Android", "dlWindows": "Scarica per Windows", "dlLinux": "Scarica per Linux", "dlMac": "Scarica per Mac", "dlIphone": "Scarica Zen per iPhone", "instIphone": "Installa su iPhone", "instMac": "Installa su Mac", "otherSystem": "Altro sistema", "otherSystems": "Altri sistemi:", "moreInstall": "Tutti i modi per installare e assistenza", "whatIsZen": "Che cos’è Zen?", "recommended": "Consigliato", "trouble": "Se qualcosa va storto", "otherWays": "Altri modi", "allSystems": "Tutti i sistemi", "nextTitle": "Zen è installato. E ora?", "nextText": "Aggiungi il tuo primo amico e scopri le basi.", "nextBtn": "Come usare Zen", "versionLine": "Ultima versione: {version} ({date})", "fpUnknown": "indicato a ogni versione su GitHub", "tocLabel": "In questa pagina", "honestTitle": "Con franchezza:", "thanks_t": "Ringraziamenti", "thanks_1": "Grazie a **[Yggdrasil|https://yggdrasil-network.github.io/]**, la rete mesh aperta e cifrata su cui funziona Zen, e a **[SideStore|https://sidestore.io/]**, che installa Zen su iPhone e lo rinnova direttamente sul telefono.", "shotsTitle": "Guardalo in azione", "shotsSub": "Schermate reali dell’app con un account dimostrativo inventato, chiare o scure come è impostato il tuo dispositivo.", "filmsTitle": "In movimento", "galleryLabel": "Schermate di Zen", "galleryPrev": "Schermata precedente", "galleryNext": "Schermata successiva", "sh_chats": "Chat", "sha_chats": "L’elenco delle chat: un gruppo e conversazioni con amici, le loro foto, i messaggi non letti e chi è online.", "sh_conversation": "Una conversazione", "sha_conversation": "Una conversazione con una foto, un messaggio vocale, reazioni emoji e le spunte di consegna.", "sh_group": "Chat di gruppo", "sha_group": "Una chat di gruppo di quattro amici con una foto e reazioni.", "sh_feed": "Bacheca", "sha_feed": "La bacheca: i post degli amici in ordine, uno con una foto.", "sh_graph": "Grafo degli amici", "sha_graph": "Il grafo degli amici in modalità presenza: chi è online, in background o offline, con gli amici degli amici intorno.", "sh_graphTimeline": "Cronologia del grafo", "sha_graphTimeline": "La cronologia del grafo degli amici: un cursore attraverso i giorni in cui la cerchia di amici è cresciuta.", "sh_nearby": "Persone vicine", "sha_nearby": "Persone vicine: gli amici incrociati ieri con gli orari, e quanti altri utenti di Zen erano intorno, salvato solo sul telefono.", "sh_notifications": "Notifiche e suoni", "sha_notifications": "Impostazioni di notifiche e suoni: cosa mostra una notifica, i suoni nell’app e quali tipi notificare.", "sh_storage": "Dati e memoria", "sha_storage": "Dati e memoria: quanto spazio occupa Zen, diviso tra post, media, backup e altri dati, con il limite.", "sh_lock": "Schermata di blocco", "sha_lock": "La schermata di blocco: Zen è bloccato e chiede la password dell’app, mentre i messaggi continuano ad arrivare.", "sh_desktop": "Su un computer", "sha_desktop": "Zen su un computer: la barra laterale e l’elenco delle chat in una finestra larga.", "fl_send": "Inviare un messaggio", "fla_send": "Una breve animazione: scrivere un messaggio a un’amica e inviarlo.", "fl_graph": "Il grafo cresce", "fla_graph": "Una breve animazione: il grafo degli amici cresce nel corso di un anno, amico dopo amico.", "footPromo": "Materiale promozionale"},
    "hu": {"navLabel": "Főmenü", "navInstall": "Telepítés", "navGuide": "Útmutató", "navFeatures": "Funkciók", "navSupport": "Segítség", "navAbout": "Névjegy", "navPromo": "Anyagok", "langLabel": "Nyelv", "skip": "Ugrás a tartalomra", "footPrivacy": "Adatvédelmi irányelvek", "footTerms": "Felhasználási feltételek", "footLicense": "Licenc", "footCode": "Forráskód", "footNote": "A Zen szabad szoftver (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Az Apple, iPhone, iOS és macOS az Apple Inc. védjegyei; a Windows a Microsoft védjegye; az Android a Google LLC védjegye. A Zen nem áll kapcsolatban velük, és nem támogatják.", "open": "Megnyitás a Zenben", "copy": "Kód másolása", "copied": "Másolva ✓", "getTitle": "Szerezd meg a Zent", "getLead": "Ingyenes, regisztráció és reklám nélkül. Egy percet vesz igénybe.", "dlAndroid": "Letöltés Androidra", "dlWindows": "Letöltés Windowsra", "dlLinux": "Letöltés Linuxra", "dlMac": "Letöltés Macre", "dlIphone": "A Zen letöltése iPhone-ra", "instIphone": "Telepítés iPhone-ra", "instMac": "Telepítés Macre", "otherSystem": "Másik rendszer", "otherSystems": "Más rendszerek:", "moreInstall": "Minden telepítési mód és segítség", "whatIsZen": "Mi a Zen?", "recommended": "Ajánlott", "trouble": "Ha valami elromlik", "otherWays": "Más módok", "allSystems": "Minden rendszer", "nextTitle": "A Zen telepítve van. És most?", "nextText": "Add hozzá az első barátodat, és ismerd meg az alapokat.", "nextBtn": "A Zen használata", "versionLine": "Legújabb verzió: {version} ({date})", "fpUnknown": "minden kiadásnál megtalálható a GitHubon", "tocLabel": "Ezen az oldalon", "honestTitle": "Őszintén:", "thanks_t": "Köszönet", "thanks_1": "Köszönet a **[Yggdrasilnek|https://yggdrasil-network.github.io/]**, a nyílt, titkosított mesh hálózatnak, amelyen a Zen fut, és a **[SideStore-nak|https://sidestore.io/]**, amely telepíti a Zent iPhone-ra, és magán a telefonon megújítja.", "shotsTitle": "Nézd meg működés közben", "shotsSub": "Az alkalmazás valódi képernyői egy kitalált bemutatófiókkal, világosan vagy sötéten, ahogy az eszközöd be van állítva.", "filmsTitle": "Mozgásban", "galleryLabel": "Képernyőképek a Zenről", "galleryPrev": "Előző képernyőkép", "galleryNext": "Következő képernyőkép", "sh_chats": "Csevegések", "sha_chats": "A csevegések listája: egy csoport és beszélgetések barátokkal, a fotóik, az olvasatlan üzenetek és hogy ki van online.", "sh_conversation": "Egy beszélgetés", "sha_conversation": "Egy beszélgetés fotóval, hangüzenettel, emoji-reakciókkal és a kézbesítési pipákkal.", "sh_group": "Csoportos csevegés", "sha_group": "Négy barát csoportos csevegése egy fotóval és reakciókkal.", "sh_feed": "Hírfolyam", "sha_feed": "A hírfolyam: a barátok bejegyzései sorrendben, az egyik fotóval.", "sh_graph": "Baráti gráf", "sha_graph": "A baráti gráf jelenlét módban: ki van online, a háttérben vagy offline, körülöttük a barátok barátaival.", "sh_graphTimeline": "A gráf idővonala", "sha_graphTimeline": "A baráti gráf idővonala: csúszka azokon a napokon át, amikor a baráti kör nőtt.", "sh_nearby": "Emberek a közelben", "sha_nearby": "Emberek a közelben: a tegnap elhaladó barátok az időpontokkal, és hány másik Zen-felhasználó volt a közelben, csak a telefonon tárolva.", "sh_notifications": "Értesítések és hangok", "sha_notifications": "Értesítési és hangbeállítások: mit mutat egy értesítés, az alkalmazás hangjai és milyen fajták jeleznek.", "sh_storage": "Adatok és tárhely", "sha_storage": "Adatok és tárhely: mennyi helyet foglal a Zen, bejegyzésekre, médiára, mentésekre és egyéb adatokra bontva, a korláttal.", "sh_lock": "Zárolási képernyő", "sha_lock": "A zárolási képernyő: a Zen zárolva van és az alkalmazás jelszavát kéri, közben az üzenetek tovább érkeznek.", "sh_desktop": "Számítógépen", "sha_desktop": "A Zen számítógépen: az oldalsáv és a csevegések listája egy széles ablakban.", "fl_send": "Üzenet küldése", "fla_send": "Rövid animáció: üzenet írása egy barátnak és elküldése.", "fl_graph": "A gráf növekedése", "fla_graph": "Rövid animáció: a baráti gráf egy év alatt növekszik, barátról barátra.", "footPromo": "Promóciós anyagok"},
    "nl": {"navLabel": "Hoofdmenu", "navInstall": "Installeren", "navGuide": "Handleiding", "navFeatures": "Functies", "navSupport": "Hulp", "navAbout": "Over", "navPromo": "Materiaal", "langLabel": "Taal", "skip": "Naar de inhoud", "footPrivacy": "Privacybeleid", "footTerms": "Gebruiksvoorwaarden", "footLicense": "Licentie", "footCode": "Broncode", "footNote": "Zen is vrije software (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS en macOS zijn handelsmerken van Apple Inc.; Windows is een handelsmerk van Microsoft; Android is een handelsmerk van Google LLC. Zen is niet aan hen gelieerd en wordt niet door hen onderschreven.", "open": "Openen in Zen", "copy": "Code kopiëren", "copied": "Gekopieerd ✓", "getTitle": "Haal Zen", "getLead": "Gratis, zonder aanmelden, zonder advertenties. Het kost een minuut.", "dlAndroid": "Downloaden voor Android", "dlWindows": "Downloaden voor Windows", "dlLinux": "Downloaden voor Linux", "dlMac": "Downloaden voor Mac", "dlIphone": "Zen downloaden voor iPhone", "instIphone": "Installeren op iPhone", "instMac": "Installeren op Mac", "otherSystem": "Ander systeem", "otherSystems": "Andere systemen:", "moreInstall": "Alle installatiemogelijkheden en hulp", "whatIsZen": "Wat is Zen?", "recommended": "Aanbevolen", "trouble": "Als er iets misgaat", "otherWays": "Andere manieren", "allSystems": "Alle systemen", "nextTitle": "Zen is geïnstalleerd. En nu?", "nextText": "Voeg je eerste vriend toe en leer de basis.", "nextBtn": "Zen gebruiken", "versionLine": "Nieuwste versie: {version} ({date})", "fpUnknown": "bij elke release op GitHub vermeld", "tocLabel": "Op deze pagina", "honestTitle": "Eerlijk gezegd:", "thanks_t": "Dank", "thanks_1": "Dank aan **[Yggdrasil|https://yggdrasil-network.github.io/]**, het open, versleutelde meshnetwerk waarop Zen draait, en aan **[SideStore|https://sidestore.io/]**, dat Zen op een iPhone installeert en op de telefoon zelf vernieuwt.", "shotsTitle": "Zie het in actie", "shotsSub": "Echte schermen van de app met een verzonnen demo-account, licht of donker zoals je apparaat is ingesteld.", "filmsTitle": "In beweging", "galleryLabel": "Schermafbeeldingen van Zen", "galleryPrev": "Vorige schermafbeelding", "galleryNext": "Volgende schermafbeelding", "sh_chats": "Chats", "sha_chats": "De chatlijst: een groep en gesprekken met vrienden, hun foto's, ongelezen berichten en wie er online is.", "sh_conversation": "Een gesprek", "sha_conversation": "Een gesprek met een foto, een spraakbericht, emoji-reacties en de bezorgvinkjes.", "sh_group": "Groepschat", "sha_group": "Een groepschat van vier vrienden met een foto en reacties.", "sh_feed": "Prikbord", "sha_feed": "Het prikbord: berichten van vrienden op volgorde, één met een foto.", "sh_graph": "Vriendengrafiek", "sha_graph": "De vriendengrafiek in aanwezigheidsmodus: wie online, op de achtergrond of offline is, met vrienden van vrienden eromheen.", "sh_graphTimeline": "Tijdlijn van de grafiek", "sha_graphTimeline": "De tijdlijn van de vriendengrafiek: een schuifregelaar door de dagen waarop de vriendenkring groeide.", "sh_nearby": "Mensen in de buurt", "sha_nearby": "Mensen in de buurt: vrienden die je gisteren tegenkwam met de tijden, en hoeveel andere Zen-gebruikers er waren, alleen op de telefoon bewaard.", "sh_notifications": "Meldingen en geluiden", "sha_notifications": "Instellingen voor meldingen en geluiden: wat een melding toont, geluiden in de app en welke soorten melden.", "sh_storage": "Gegevens en opslag", "sha_storage": "Gegevens en opslag: hoeveel ruimte Zen inneemt, verdeeld over berichten, media, back-ups en andere gegevens, met de limiet.", "sh_lock": "Vergrendelscherm", "sha_lock": "Het vergrendelscherm: Zen is vergrendeld en vraagt om het app-wachtwoord, terwijl berichten blijven binnenkomen.", "sh_desktop": "Op een computer", "sha_desktop": "Zen op een computer: de zijbalk en de chatlijst in een breed venster.", "fl_send": "Een bericht sturen", "fla_send": "Een korte animatie: een bericht aan een vriendin typen en versturen.", "fl_graph": "De grafiek groeit", "fla_graph": "Een korte animatie: de vriendengrafiek groeit in een jaar, vriend voor vriend.", "footPromo": "Promotiemateriaal"},
    "pt": {"navLabel": "Principal", "navInstall": "Instalar", "navGuide": "Guia", "navFeatures": "Recursos", "navSupport": "Ajuda", "navAbout": "Sobre", "navPromo": "Materiais", "langLabel": "Idioma", "skip": "Ir para o conteúdo", "footPrivacy": "Política de privacidade", "footTerms": "Termos de uso", "footLicense": "Licença", "footCode": "Código-fonte", "footNote": "O Zen é software livre (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS e macOS são marcas da Apple Inc.; Windows é uma marca da Microsoft; Android é uma marca da Google LLC. O Zen não é afiliado a elas nem endossado por elas.", "open": "Abrir no Zen", "copy": "Copiar código", "copied": "Copiado ✓", "getTitle": "Baixe o Zen", "getLead": "Grátis, sem cadastro, sem anúncios. Leva um minuto.", "dlAndroid": "Baixar para Android", "dlWindows": "Baixar para Windows", "dlLinux": "Baixar para Linux", "dlMac": "Baixar para Mac", "dlIphone": "Baixar o Zen para iPhone", "instIphone": "Instalar no iPhone", "instMac": "Instalar no Mac", "otherSystem": "Outro sistema", "otherSystems": "Outros sistemas:", "moreInstall": "Todas as formas de instalar e ajuda", "whatIsZen": "O que é o Zen?", "recommended": "Recomendado", "trouble": "Se algo der errado", "otherWays": "Outras formas", "allSystems": "Todos os sistemas", "nextTitle": "O Zen está instalado. E agora?", "nextText": "Adicione seu primeiro amigo e aprenda o básico.", "nextBtn": "Como usar o Zen", "versionLine": "Versão mais recente: {version} ({date})", "fpUnknown": "mostrado em cada versão no GitHub", "tocLabel": "Nesta página", "honestTitle": "Com franqueza:", "thanks_t": "Agradecimentos", "thanks_1": "Obrigado ao **[Yggdrasil|https://yggdrasil-network.github.io/]**, a rede mesh aberta e criptografada em que o Zen funciona, e ao **[SideStore|https://sidestore.io/]**, que instala o Zen no iPhone e o renova no próprio telefone.", "shotsTitle": "Veja em ação", "shotsSub": "Telas reais do app com uma conta de demonstração inventada, claras ou escuras conforme o seu aparelho.", "filmsTitle": "Em movimento", "galleryLabel": "Capturas de tela do Zen", "galleryPrev": "Captura anterior", "galleryNext": "Próxima captura", "sh_chats": "Conversas", "sha_chats": "A lista de conversas: um grupo e conversas com amigos, as fotos deles, mensagens não lidas e quem está online.", "sh_conversation": "Uma conversa", "sha_conversation": "Uma conversa com uma foto, uma mensagem de voz, reações com emoji e as marcas de entrega.", "sh_group": "Conversa em grupo", "sha_group": "Uma conversa em grupo de quatro amigos com uma foto e reações.", "sh_feed": "Mural", "sha_feed": "O mural: as publicações dos amigos em ordem, uma com foto.", "sh_graph": "Grafo de amigos", "sha_graph": "O grafo de amigos no modo presença: quem está online, em segundo plano ou offline, com amigos de amigos ao redor.", "sh_graphTimeline": "Linha do tempo do grafo", "sha_graphTimeline": "A linha do tempo do grafo de amigos: um controle deslizante pelos dias em que o círculo de amigos cresceu.", "sh_nearby": "Pessoas por perto", "sha_nearby": "Pessoas por perto: amigos que você cruzou ontem com os horários, e quantos outros usuários do Zen estavam por perto, guardado só no celular.", "sh_notifications": "Notificações e sons", "sha_notifications": "Configurações de notificações e sons: o que uma notificação mostra, os sons do app e quais tipos avisam.", "sh_storage": "Dados e armazenamento", "sha_storage": "Dados e armazenamento: quanto espaço o Zen ocupa, dividido em publicações, mídia, backups e outros dados, com o limite.", "sh_lock": "Tela de bloqueio", "sha_lock": "A tela de bloqueio: o Zen está bloqueado e pede a senha do app, enquanto as mensagens continuam chegando.", "sh_desktop": "No computador", "sha_desktop": "O Zen no computador: a barra lateral e a lista de conversas numa janela larga.", "fl_send": "Enviando uma mensagem", "fla_send": "Uma animação curta: digitar uma mensagem para uma amiga e enviá-la.", "fl_graph": "O grafo crescendo", "fla_graph": "Uma animação curta: o grafo de amigos cresce ao longo de um ano, amigo a amigo.", "footPromo": "Material de divulgação"},
    "ro": {"navLabel": "Principal", "navInstall": "Instalare", "navGuide": "Ghid", "navFeatures": "Funcții", "navSupport": "Ajutor", "navAbout": "Despre", "navPromo": "Materiale", "langLabel": "Limbă", "skip": "Sari la conținut", "footPrivacy": "Politica de confidențialitate", "footTerms": "Termeni de utilizare", "footLicense": "Licență", "footCode": "Cod sursă", "footNote": "Zen este software liber (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS și macOS sunt mărci ale Apple Inc.; Windows este o marcă a Microsoft; Android este o marcă a Google LLC. Zen nu este afiliat cu ele și nu este susținut de ele.", "open": "Deschide în Zen", "copy": "Copiază codul", "copied": "Copiat ✓", "getTitle": "Ia Zen", "getLead": "Gratuit, fără înregistrare, fără reclame. Durează un minut.", "dlAndroid": "Descarcă pentru Android", "dlWindows": "Descarcă pentru Windows", "dlLinux": "Descarcă pentru Linux", "dlMac": "Descarcă pentru Mac", "dlIphone": "Descarcă Zen pentru iPhone", "instIphone": "Instalează pe iPhone", "instMac": "Instalează pe Mac", "otherSystem": "Alt sistem", "otherSystems": "Alte sisteme:", "moreInstall": "Toate modurile de instalare și ajutor", "whatIsZen": "Ce este Zen?", "recommended": "Recomandat", "trouble": "Dacă ceva nu merge", "otherWays": "Alte moduri", "allSystems": "Toate sistemele", "nextTitle": "Zen este instalat. Și acum?", "nextText": "Adaugă primul prieten și învață bazele.", "nextBtn": "Cum folosești Zen", "versionLine": "Ultima versiune: {version} ({date})", "fpUnknown": "afișată la fiecare versiune pe GitHub", "tocLabel": "Pe această pagină", "honestTitle": "Sincer:", "thanks_t": "Mulțumiri", "thanks_1": "Mulțumim **[Yggdrasil|https://yggdrasil-network.github.io/]**, rețeaua mesh deschisă și criptată pe care rulează Zen, și **[SideStore|https://sidestore.io/]**, care instalează Zen pe iPhone și îl reînnoiește direct pe telefon.", "shotsTitle": "Vezi-l în acțiune", "shotsSub": "Ecrane reale ale aplicației cu un cont demonstrativ inventat, luminoase sau întunecate, după setarea dispozitivului tău.", "filmsTitle": "În mișcare", "galleryLabel": "Capturi de ecran Zen", "galleryPrev": "Captura anterioară", "galleryNext": "Captura următoare", "sh_chats": "Conversații", "sha_chats": "Lista de conversații: un grup și conversații cu prieteni, fotografiile lor, mesajele necitite și cine este online.", "sh_conversation": "O conversație", "sha_conversation": "O conversație cu o fotografie, un mesaj vocal, reacții emoji și bifele de livrare.", "sh_group": "Conversație de grup", "sha_group": "O conversație de grup a patru prieteni cu o fotografie și reacții.", "sh_feed": "Panou", "sha_feed": "Panoul: postările prietenilor în ordine, una cu fotografie.", "sh_graph": "Graful prietenilor", "sha_graph": "Graful prietenilor în modul prezență: cine este online, în fundal sau offline, cu prietenii prietenilor în jur.", "sh_graphTimeline": "Cronologia grafului", "sha_graphTimeline": "Cronologia grafului prietenilor: un glisor prin zilele în care cercul de prieteni a crescut.", "sh_nearby": "Oameni din apropiere", "sha_nearby": "Oameni din apropiere: prietenii pe lângă care ai trecut ieri, cu orele, și câți alți utilizatori Zen erau în jur, păstrat doar pe telefon.", "sh_notifications": "Notificări și sunete", "sha_notifications": "Setările notificărilor și sunetelor: ce arată o notificare, sunetele din aplicație și ce tipuri anunță.", "sh_storage": "Date și stocare", "sha_storage": "Date și stocare: cât spațiu ocupă Zen, împărțit în postări, media, copii de rezervă și alte date, cu limita.", "sh_lock": "Ecran de blocare", "sha_lock": "Ecranul de blocare: Zen este blocat și cere parola aplicației, iar mesajele continuă să sosească.", "sh_desktop": "Pe calculator", "sha_desktop": "Zen pe calculator: bara laterală și lista de conversații într-o fereastră lată.", "fl_send": "Trimiterea unui mesaj", "fla_send": "O animație scurtă: scrierea unui mesaj către o prietenă și trimiterea lui.", "fl_graph": "Graful crește", "fla_graph": "O animație scurtă: graful prietenilor crește pe parcursul unui an, prieten cu prieten.", "footPromo": "Materiale promoționale"},
    "vi": {"navLabel": "Chính", "navInstall": "Cài đặt", "navGuide": "Hướng dẫn", "navFeatures": "Tính năng", "navSupport": "Trợ giúp", "navAbout": "Giới thiệu", "navPromo": "Tài liệu", "langLabel": "Ngôn ngữ", "skip": "Chuyển đến nội dung", "footPrivacy": "Chính sách quyền riêng tư", "footTerms": "Điều khoản sử dụng", "footLicense": "Giấy phép", "footCode": "Mã nguồn", "footNote": "Zen là phần mềm tự do (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS và macOS là nhãn hiệu của Apple Inc.; Windows là nhãn hiệu của Microsoft; Android là nhãn hiệu của Google LLC. Zen không liên kết với hay được họ bảo trợ.", "open": "Mở trong Zen", "copy": "Sao chép mã", "copied": "Đã sao chép ✓", "getTitle": "Tải Zen", "getLead": "Miễn phí, không cần đăng ký, không quảng cáo. Chỉ mất một phút.", "dlAndroid": "Tải cho Android", "dlWindows": "Tải cho Windows", "dlLinux": "Tải cho Linux", "dlMac": "Tải cho Mac", "dlIphone": "Tải Zen cho iPhone", "instIphone": "Cài đặt trên iPhone", "instMac": "Cài đặt trên Mac", "otherSystem": "Hệ thống khác", "otherSystems": "Hệ thống khác:", "moreInstall": "Mọi cách cài đặt và trợ giúp", "whatIsZen": "Zen là gì?", "recommended": "Khuyên dùng", "trouble": "Khi có trục trặc", "otherWays": "Cách khác", "allSystems": "Tất cả hệ thống", "nextTitle": "Zen đã được cài. Giờ làm gì?", "nextText": "Thêm người bạn đầu tiên và tìm hiểu những điều cơ bản.", "nextBtn": "Cách dùng Zen", "versionLine": "Phiên bản mới nhất: {version} ({date})", "fpUnknown": "hiển thị cùng mỗi bản phát hành trên GitHub", "tocLabel": "Trên trang này", "honestTitle": "Nói thật:", "thanks_t": "Lời cảm ơn", "thanks_1": "Cảm ơn **[Yggdrasil|https://yggdrasil-network.github.io/]**, mạng lưới mesh mở và được mã hóa mà Zen chạy trên đó, và **[SideStore|https://sidestore.io/]**, giúp cài Zen trên iPhone và gia hạn ngay trên điện thoại.", "shotsTitle": "Xem cách hoạt động", "shotsSub": "Màn hình thật của ứng dụng với một tài khoản minh họa hư cấu, sáng hoặc tối theo cài đặt thiết bị của bạn.", "filmsTitle": "Chuyển động", "galleryLabel": "Ảnh chụp màn hình Zen", "galleryPrev": "Ảnh trước", "galleryNext": "Ảnh tiếp theo", "sh_chats": "Trò chuyện", "sha_chats": "Danh sách trò chuyện: một nhóm và các cuộc trò chuyện với bạn bè, ảnh của họ, số tin chưa đọc và ai đang trực tuyến.", "sh_conversation": "Một cuộc trò chuyện", "sha_conversation": "Một cuộc trò chuyện có ảnh, tin nhắn thoại, biểu tượng cảm xúc và dấu đã gửi.", "sh_group": "Trò chuyện nhóm", "sha_group": "Một nhóm trò chuyện của bốn người bạn với một bức ảnh và các biểu cảm.", "sh_feed": "Bảng tin", "sha_feed": "Bảng tin: bài đăng của bạn bè theo thứ tự, một bài có ảnh.", "sh_graph": "Đồ thị bạn bè", "sha_graph": "Đồ thị bạn bè ở chế độ hiện diện: ai đang trực tuyến, chạy nền hay ngoại tuyến, cùng bạn của bạn bè xung quanh.", "sh_graphTimeline": "Dòng thời gian đồ thị", "sha_graphTimeline": "Dòng thời gian của đồ thị bạn bè: thanh trượt qua những ngày vòng bạn bè lớn dần.", "sh_nearby": "Người ở gần", "sha_nearby": "Người ở gần: bạn bè đã đi ngang qua hôm qua kèm giờ, và có bao nhiêu người dùng Zen khác quanh đó, chỉ lưu trên điện thoại.", "sh_notifications": "Thông báo và âm thanh", "sha_notifications": "Cài đặt thông báo và âm thanh: thông báo hiển thị gì, âm thanh trong ứng dụng và loại nào được báo.", "sh_storage": "Dữ liệu và bộ nhớ", "sha_storage": "Dữ liệu và bộ nhớ: Zen chiếm bao nhiêu dung lượng, chia theo bài đăng, đa phương tiện, bản sao lưu và dữ liệu khác, kèm giới hạn.", "sh_lock": "Màn hình khóa", "sha_lock": "Màn hình khóa: Zen đang khóa và hỏi mật khẩu ứng dụng, trong khi tin nhắn vẫn tiếp tục đến.", "sh_desktop": "Trên máy tính", "sha_desktop": "Zen trên máy tính: thanh bên và danh sách trò chuyện trong một cửa sổ rộng.", "fl_send": "Gửi tin nhắn", "fla_send": "Một hoạt ảnh ngắn: gõ tin nhắn cho một người bạn rồi gửi đi.", "fl_graph": "Đồ thị lớn dần", "fla_graph": "Một hoạt ảnh ngắn: đồ thị bạn bè lớn dần trong một năm, từng người bạn một.", "footPromo": "Tài liệu quảng bá"},
    "tr": {"navLabel": "Ana menü", "navInstall": "Kur", "navGuide": "Rehber", "navFeatures": "Özellikler", "navSupport": "Yardım", "navAbout": "Hakkında", "navPromo": "Materyaller", "langLabel": "Dil", "skip": "İçeriğe geç", "footPrivacy": "Gizlilik politikası", "footTerms": "Kullanım koşulları", "footLicense": "Lisans", "footCode": "Kaynak kod", "footNote": "Zen özgür bir yazılımdır (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS ve macOS, Apple Inc. şirketinin ticari markalarıdır; Windows, Microsoft’un ticari markasıdır; Android, Google LLC’nin ticari markasıdır. Zen bunlarla bağlantılı değildir ve onlar tarafından onaylanmamıştır.", "open": "Zen’de aç", "copy": "Kodu kopyala", "copied": "Kopyalandı ✓", "getTitle": "Zen’i edin", "getLead": "Ücretsiz, kayıtsız, reklamsız. Bir dakika sürer.", "dlAndroid": "Android için indir", "dlWindows": "Windows için indir", "dlLinux": "Linux için indir", "dlMac": "Mac için indir", "dlIphone": "Zen’i iPhone için indir", "instIphone": "iPhone’a kur", "instMac": "Mac’e kur", "otherSystem": "Başka sistem", "otherSystems": "Diğer sistemler:", "moreInstall": "Tüm kurulum yolları ve yardım", "whatIsZen": "Zen nedir?", "recommended": "Önerilen", "trouble": "Bir şey ters giderse", "otherWays": "Diğer yollar", "allSystems": "Tüm sistemler", "nextTitle": "Zen kuruldu. Şimdi ne yapmalı?", "nextText": "İlk arkadaşını ekle ve temelleri öğren.", "nextBtn": "Zen nasıl kullanılır", "versionLine": "Son sürüm: {version} ({date})", "fpUnknown": "GitHub’da her sürümle birlikte gösterilir", "tocLabel": "Bu sayfada", "honestTitle": "Açık konuşalım:", "thanks_t": "Teşekkürler", "thanks_1": "Zen’in üzerinde çalıştığı açık, şifreli mesh ağı **[Yggdrasil|https://yggdrasil-network.github.io/]**’e ve Zen’i iPhone’a kurup doğrudan telefonda yenileyen **[SideStore|https://sidestore.io/]**’a teşekkürler.", "shotsTitle": "Nasıl çalıştığını görün", "shotsSub": "Uydurma bir tanıtım hesabıyla uygulamanın gerçek ekranları, cihazınızın ayarına göre açık veya koyu.", "filmsTitle": "Hareket hâlinde", "galleryLabel": "Zen ekran görüntüleri", "galleryPrev": "Önceki ekran görüntüsü", "galleryNext": "Sonraki ekran görüntüsü", "sh_chats": "Sohbetler", "sha_chats": "Sohbet listesi: bir grup ve arkadaşlarla sohbetler, fotoğrafları, okunmamış mesajlar ve kimin çevrimiçi olduğu.", "sh_conversation": "Bir sohbet", "sha_conversation": "Fotoğraf, sesli mesaj, emoji tepkileri ve teslim işaretleri içeren bir sohbet.", "sh_group": "Grup sohbeti", "sha_group": "Dört arkadaşın fotoğraflı ve tepkili grup sohbeti.", "sh_feed": "Akış", "sha_feed": "Akış: arkadaşların gönderileri sırayla, biri fotoğraflı.", "sh_graph": "Arkadaş grafiği", "sha_graph": "Varlık modunda arkadaş grafiği: kim çevrimiçi, arka planda veya çevrimdışı, çevrelerinde arkadaşların arkadaşları.", "sh_graphTimeline": "Grafik zaman çizelgesi", "sha_graphTimeline": "Arkadaş grafiğinin zaman çizelgesi: arkadaş çevresinin büyüdüğü günler boyunca bir kaydırıcı.", "sh_nearby": "Yakındaki kişiler", "sha_nearby": "Yakındaki kişiler: dün yanından geçilen arkadaşlar saatleriyle ve çevrede kaç başka Zen kullanıcısı olduğu, yalnızca telefonda saklanır.", "sh_notifications": "Bildirimler ve sesler", "sha_notifications": "Bildirim ve ses ayarları: bir bildirimin ne gösterdiği, uygulama içi sesler ve hangi türlerin bildirdiği.", "sh_storage": "Veri ve depolama", "sha_storage": "Veri ve depolama: Zen'in ne kadar yer kapladığı, gönderiler, medya, yedekler ve diğer veriler olarak ayrılmış, sınırıyla birlikte.", "sh_lock": "Kilit ekranı", "sha_lock": "Kilit ekranı: Zen kilitli ve uygulama parolasını istiyor, bu arada mesajlar gelmeye devam ediyor.", "sh_desktop": "Bilgisayarda", "sha_desktop": "Bilgisayarda Zen: geniş bir pencerede kenar çubuğu ve sohbet listesi.", "fl_send": "Mesaj göndermek", "fla_send": "Kısa bir animasyon: bir arkadaşa mesaj yazıp göndermek.", "fl_graph": "Büyüyen grafik", "fla_graph": "Kısa bir animasyon: arkadaş grafiği bir yıl boyunca arkadaş arkadaş büyüyor.", "footPromo": "Tanıtım malzemeleri"},
    "ru": {"navLabel": "Главное меню", "navInstall": "Установка", "navGuide": "Руководство", "navFeatures": "Возможности", "navSupport": "Помощь", "navAbout": "О Zen", "navPromo": "Материалы", "langLabel": "Язык", "skip": "Перейти к содержимому", "footPrivacy": "Политика конфиденциальности", "footTerms": "Условия использования", "footLicense": "Лицензия", "footCode": "Исходный код", "footNote": "Zen — свободное программное обеспечение (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS и macOS — товарные знаки Apple Inc.; Windows — товарный знак Microsoft; Android — товарный знак Google LLC. Zen не связан с ними и не одобрен ими.", "open": "Открыть в Zen", "copy": "Скопировать код", "copied": "Скопировано ✓", "getTitle": "Получите Zen", "getLead": "Бесплатно, без регистрации и рекламы. Займёт минуту.", "dlAndroid": "Скачать для Android", "dlWindows": "Скачать для Windows", "dlLinux": "Скачать для Linux", "dlMac": "Скачать для Mac", "dlIphone": "Скачать Zen для iPhone", "instIphone": "Установить на iPhone", "instMac": "Установить на Mac", "otherSystem": "Другая система", "otherSystems": "Другие системы:", "moreInstall": "Все способы установки и помощь", "whatIsZen": "Что такое Zen?", "recommended": "Рекомендуем", "trouble": "Если что-то пошло не так", "otherWays": "Другие способы", "allSystems": "Все системы", "nextTitle": "Zen установлен. Что дальше?", "nextText": "Добавьте первого друга и узнайте основы.", "nextBtn": "Как пользоваться Zen", "versionLine": "Последняя версия: {version} ({date})", "fpUnknown": "указан у каждого выпуска на GitHub", "tocLabel": "На этой странице", "honestTitle": "Честно говоря:", "thanks_t": "Благодарности", "thanks_1": "Спасибо **[Yggdrasil|https://yggdrasil-network.github.io/]** — открытой зашифрованной ячеистой сети, на которой работает Zen, и **[SideStore|https://sidestore.io/]**, который устанавливает Zen на iPhone и продлевает его прямо на телефоне.", "shotsTitle": "Посмотрите, как это работает", "shotsSub": "Настоящие экраны приложения с вымышленной демо-учётной записью, светлые или тёмные — как настроено ваше устройство.", "filmsTitle": "В движении", "galleryLabel": "Снимки экрана Zen", "galleryPrev": "Предыдущий снимок", "galleryNext": "Следующий снимок", "sh_chats": "Чаты", "sha_chats": "Список чатов: группа и переписки с друзьями, их фото, непрочитанные сообщения и кто в сети.", "sh_conversation": "Переписка", "sha_conversation": "Переписка с фотографией, голосовым сообщением, реакциями-эмодзи и отметками доставки.", "sh_group": "Групповой чат", "sha_group": "Групповой чат четырёх друзей с фотографией и реакциями.", "sh_feed": "Лента", "sha_feed": "Лента: посты друзей по порядку, один с фотографией.", "sh_graph": "Граф друзей", "sha_graph": "Граф друзей в режиме присутствия: кто в сети, в фоне или не в сети, а вокруг — друзья друзей.", "sh_graphTimeline": "Шкала времени графа", "sha_graphTimeline": "Шкала времени графа друзей: ползунок по дням, когда рос круг друзей.", "sh_nearby": "Люди рядом", "sha_nearby": "Люди рядом: друзья, мимо которых вы прошли вчера, со временем, и сколько других пользователей Zen было рядом; хранится только на телефоне.", "sh_notifications": "Уведомления и звуки", "sha_notifications": "Настройки уведомлений и звуков: что показывает уведомление, звуки в приложении и о чём уведомлять.", "sh_storage": "Данные и память", "sha_storage": "Данные и память: сколько места занимает Zen, по постам, медиа, резервным копиям и прочим данным, с лимитом.", "sh_lock": "Экран блокировки", "sha_lock": "Экран блокировки: Zen заблокирован и просит пароль приложения, а сообщения продолжают приходить.", "sh_desktop": "На компьютере", "sha_desktop": "Zen на компьютере: боковая панель и список чатов в широком окне.", "fl_send": "Отправка сообщения", "fla_send": "Короткая анимация: набор сообщения подруге и его отправка.", "fl_graph": "Граф растёт", "fla_graph": "Короткая анимация: граф друзей растёт в течение года, друг за другом.", "footPromo": "Промоматериалы"},
    "uk": {"navLabel": "Головне меню", "navInstall": "Встановлення", "navGuide": "Посібник", "navFeatures": "Можливості", "navSupport": "Допомога", "navAbout": "Про Zen", "navPromo": "Матеріали", "langLabel": "Мова", "skip": "Перейти до вмісту", "footPrivacy": "Політика конфіденційності", "footTerms": "Умови використання", "footLicense": "Ліцензія", "footCode": "Вихідний код", "footNote": "Zen — вільне програмне забезпечення (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS і macOS — торгові марки Apple Inc.; Windows — торгова марка Microsoft; Android — торгова марка Google LLC. Zen не пов’язаний з ними і не схвалений ними.", "open": "Відкрити в Zen", "copy": "Скопіювати код", "copied": "Скопійовано ✓", "getTitle": "Отримайте Zen", "getLead": "Безкоштовно, без реєстрації й реклами. Займе хвилину.", "dlAndroid": "Завантажити для Android", "dlWindows": "Завантажити для Windows", "dlLinux": "Завантажити для Linux", "dlMac": "Завантажити для Mac", "dlIphone": "Завантажити Zen для iPhone", "instIphone": "Встановити на iPhone", "instMac": "Встановити на Mac", "otherSystem": "Інша система", "otherSystems": "Інші системи:", "moreInstall": "Усі способи встановлення й допомога", "whatIsZen": "Що таке Zen?", "recommended": "Рекомендуємо", "trouble": "Якщо щось пішло не так", "otherWays": "Інші способи", "allSystems": "Усі системи", "nextTitle": "Zen встановлено. Що далі?", "nextText": "Додайте першого друга й дізнайтеся основи.", "nextBtn": "Як користуватися Zen", "versionLine": "Остання версія: {version} ({date})", "fpUnknown": "вказано в кожному випуску на GitHub", "tocLabel": "На цій сторінці", "honestTitle": "Чесно кажучи:", "thanks_t": "Подяки", "thanks_1": "Дякуємо **[Yggdrasil|https://yggdrasil-network.github.io/]** — відкритій зашифрованій ячеїстій мережі, на якій працює Zen, і **[SideStore|https://sidestore.io/]**, який встановлює Zen на iPhone і поновлює його просто на телефоні.", "shotsTitle": "Подивіться, як це працює", "shotsSub": "Справжні екрани застосунку з вигаданим демо-обліковим записом, світлі або темні — як налаштовано ваш пристрій.", "filmsTitle": "У русі", "galleryLabel": "Знімки екрана Zen", "galleryPrev": "Попередній знімок", "galleryNext": "Наступний знімок", "sh_chats": "Чати", "sha_chats": "Список чатів: група й розмови з друзями, їхні фото, непрочитані повідомлення і хто в мережі.", "sh_conversation": "Розмова", "sha_conversation": "Розмова з фотографією, голосовим повідомленням, реакціями-емодзі та позначками доставлення.", "sh_group": "Груповий чат", "sha_group": "Груповий чат чотирьох друзів із фотографією та реакціями.", "sh_feed": "Стрічка", "sha_feed": "Стрічка: дописи друзів по черзі, один із фотографією.", "sh_graph": "Граф друзів", "sha_graph": "Граф друзів у режимі присутності: хто в мережі, у фоні чи поза мережею, а довкола — друзі друзів.", "sh_graphTimeline": "Шкала часу графа", "sha_graphTimeline": "Шкала часу графа друзів: повзунок крізь дні, коли зростало коло друзів.", "sh_nearby": "Люди поруч", "sha_nearby": "Люди поруч: друзі, повз яких ви пройшли вчора, з часом, і скільки інших користувачів Zen було поруч; зберігається лише на телефоні.", "sh_notifications": "Сповіщення і звуки", "sha_notifications": "Налаштування сповіщень і звуків: що показує сповіщення, звуки в застосунку і про що сповіщати.", "sh_storage": "Дані й пам’ять", "sha_storage": "Дані й пам’ять: скільки місця займає Zen, за дописами, медіа, резервними копіями та іншими даними, з лімітом.", "sh_lock": "Екран блокування", "sha_lock": "Екран блокування: Zen заблоковано, і він просить пароль застосунку, а повідомлення далі надходять.", "sh_desktop": "На комп’ютері", "sha_desktop": "Zen на комп’ютері: бічна панель і список чатів у широкому вікні.", "fl_send": "Надсилання повідомлення", "fla_send": "Коротка анімація: набір повідомлення подрузі та його надсилання.", "fl_graph": "Граф зростає", "fla_graph": "Коротка анімація: граф друзів зростає протягом року, друг за другом.", "footPromo": "Промоматеріали"},
    "ar": {"navLabel": "الرئيسية", "navInstall": "التثبيت", "navGuide": "الدليل", "navFeatures": "الميزات", "navSupport": "المساعدة", "navAbout": "حول", "navPromo": "مواد", "langLabel": "اللغة", "skip": "انتقل إلى المحتوى", "footPrivacy": "سياسة الخصوصية", "footTerms": "شروط الاستخدام", "footLicense": "الترخيص", "footCode": "الشيفرة المصدرية", "footNote": "Zen برنامج حر (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple وiPhone وiOS وmacOS علامات تجارية لشركة Apple Inc.؛ وWindows علامة تجارية لشركة Microsoft؛ وAndroid علامة تجارية لشركة Google LLC. لا ينتمي Zen إلى هذه الجهات ولا تؤيده.", "open": "افتح في Zen", "copy": "انسخ الرمز", "copied": "تم النسخ ✓", "getTitle": "احصل على Zen", "getLead": "مجاني، بلا تسجيل، بلا إعلانات. يستغرق دقيقة.", "dlAndroid": "نزّل لنظام Android", "dlWindows": "نزّل لنظام Windows", "dlLinux": "نزّل لنظام Linux", "dlMac": "نزّل لنظام Mac", "dlIphone": "نزّل Zen لـ iPhone", "instIphone": "ثبّت على iPhone", "instMac": "ثبّت على Mac", "otherSystem": "نظام آخر", "otherSystems": "أنظمة أخرى:", "moreInstall": "كل طرق التثبيت والمساعدة", "whatIsZen": "ما هو Zen؟", "recommended": "موصى به", "trouble": "إذا حدث خطأ ما", "otherWays": "طرق أخرى", "allSystems": "كل الأنظمة", "nextTitle": "تم تثبيت Zen. وماذا بعد؟", "nextText": "أضف أول صديق لك وتعرّف على الأساسيات.", "nextBtn": "كيف تستخدم Zen", "versionLine": "أحدث إصدار: {version} ({date})", "fpUnknown": "يظهر مع كل إصدار على GitHub", "tocLabel": "في هذه الصفحة", "honestTitle": "بصراحة:", "thanks_t": "شكر", "thanks_1": "شكرًا لـ **[Yggdrasil|https://yggdrasil-network.github.io/]**، الشبكة المتشابكة المفتوحة والمشفّرة التي يعمل عليها Zen، ولـ **[SideStore|https://sidestore.io/]** الذي يثبّت Zen على iPhone ويجدّده على الهاتف نفسه.", "shotsTitle": "شاهده أثناء العمل", "shotsSub": "شاشات حقيقية من التطبيق بحساب تجريبي مُختلَق، فاتحة أو داكنة حسب إعداد جهازك.", "filmsTitle": "أثناء الحركة", "galleryLabel": "لقطات شاشة من Zen", "galleryPrev": "اللقطة السابقة", "galleryNext": "اللقطة التالية", "sh_chats": "الدردشات", "sha_chats": "قائمة الدردشات: مجموعة ومحادثات مع الأصدقاء وصورهم وعدد الرسائل غير المقروءة ومن المتصل الآن.", "sh_conversation": "محادثة", "sha_conversation": "محادثة فيها صورة ورسالة صوتية وتفاعلات بالرموز التعبيرية وعلامات التسليم.", "sh_group": "دردشة جماعية", "sha_group": "دردشة جماعية لأربعة أصدقاء فيها صورة وتفاعلات.", "sh_feed": "الحائط", "sha_feed": "الحائط: منشورات الأصدقاء بالترتيب، وأحدها مع صورة.", "sh_graph": "مخطط الأصدقاء", "sha_graph": "مخطط الأصدقاء في وضع الحضور: من المتصل أو في الخلفية أو غير المتصل، ومن حولهم أصدقاء الأصدقاء.", "sh_graphTimeline": "الخط الزمني للمخطط", "sha_graphTimeline": "الخط الزمني لمخطط الأصدقاء: شريط تمرير عبر الأيام التي كبرت فيها دائرة الأصدقاء.", "sh_nearby": "أشخاص بالقرب", "sha_nearby": "أشخاص بالقرب: أصدقاء مررت بهم أمس مع الأوقات، وعدد مستخدمي Zen الآخرين حولك، محفوظ على الهاتف فقط.", "sh_notifications": "الإشعارات والأصوات", "sha_notifications": "إعدادات الإشعارات والأصوات: ما يعرضه الإشعار وأصوات التطبيق وأنواع ما يُشعَر به.", "sh_storage": "البيانات والتخزين", "sha_storage": "البيانات والتخزين: المساحة التي يشغلها Zen موزعة على المنشورات والوسائط والنسخ الاحتياطية والبيانات الأخرى، مع الحد الأقصى.", "sh_lock": "شاشة القفل", "sha_lock": "شاشة القفل: Zen مقفل ويطلب كلمة مرور التطبيق، بينما تستمر الرسائل في الوصول.", "sh_desktop": "على الحاسوب", "sha_desktop": "Zen على الحاسوب: الشريط الجانبي وقائمة الدردشات في نافذة عريضة.", "fl_send": "إرسال رسالة", "fla_send": "رسوم متحركة قصيرة: كتابة رسالة إلى صديقة وإرسالها.", "fl_graph": "المخطط يكبر", "fla_graph": "رسوم متحركة قصيرة: مخطط الأصدقاء يكبر على مدى عام، صديقًا بعد صديق.", "footPromo": "مواد ترويجية"},
    "hi": {"navLabel": "मुख्य", "navInstall": "इंस्टॉल", "navGuide": "गाइड", "navFeatures": "सुविधाएँ", "navSupport": "सहायता", "navAbout": "परिचय", "navPromo": "सामग्री", "langLabel": "भाषा", "skip": "सामग्री पर जाएँ", "footPrivacy": "गोपनीयता नीति", "footTerms": "उपयोग की शर्तें", "footLicense": "लाइसेंस", "footCode": "सोर्स कोड", "footNote": "Zen मुक्त सॉफ़्टवेयर है (GPL-3.0)। © 2026 Robert Ostrowski-Jagoda।", "trademark": "Apple, iPhone, iOS और macOS Apple Inc. के ट्रेडमार्क हैं; Windows Microsoft का ट्रेडमार्क है; Android Google LLC का ट्रेडमार्क है। Zen का इनसे कोई संबंध नहीं है और न ही इनका समर्थन प्राप्त है।", "open": "Zen में खोलें", "copy": "कोड कॉपी करें", "copied": "कॉपी हो गया ✓", "getTitle": "Zen पाएँ", "getLead": "मुफ़्त, बिना साइन-अप और बिना विज्ञापन के। बस एक मिनट लगता है।", "dlAndroid": "Android के लिए डाउनलोड करें", "dlWindows": "Windows के लिए डाउनलोड करें", "dlLinux": "Linux के लिए डाउनलोड करें", "dlMac": "Mac के लिए डाउनलोड करें", "dlIphone": "iPhone के लिए Zen डाउनलोड करें", "instIphone": "iPhone पर इंस्टॉल करें", "instMac": "Mac पर इंस्टॉल करें", "otherSystem": "अन्य सिस्टम", "otherSystems": "अन्य सिस्टम:", "moreInstall": "इंस्टॉल के सभी तरीक़े और सहायता", "whatIsZen": "Zen क्या है?", "recommended": "अनुशंसित", "trouble": "अगर कुछ गड़बड़ हो", "otherWays": "अन्य तरीक़े", "allSystems": "सभी सिस्टम", "nextTitle": "Zen इंस्टॉल हो गया। अब क्या?", "nextText": "अपना पहला दोस्त जोड़ें और बुनियादी बातें सीखें।", "nextBtn": "Zen कैसे इस्तेमाल करें", "versionLine": "नवीनतम संस्करण: {version} ({date})", "fpUnknown": "GitHub पर हर रिलीज़ के साथ दिखाया जाता है", "tocLabel": "इस पृष्ठ पर", "honestTitle": "सच कहें तो:", "thanks_t": "आभार", "thanks_1": "**[Yggdrasil|https://yggdrasil-network.github.io/]** का धन्यवाद, जो वह खुला, एन्क्रिप्टेड मेश नेटवर्क है जिस पर Zen चलता है, और **[SideStore|https://sidestore.io/]** का, जो iPhone पर Zen इंस्टॉल करता है और फ़ोन पर ही उसे नवीनीकृत करता है।", "shotsTitle": "इसे काम करते देखें", "shotsSub": "ऐप की असली स्क्रीनें, एक काल्पनिक डेमो खाते के साथ, आपके डिवाइस की सेटिंग के अनुसार हल्की या गहरी।", "filmsTitle": "गति में", "galleryLabel": "Zen के स्क्रीनशॉट", "galleryPrev": "पिछला स्क्रीनशॉट", "galleryNext": "अगला स्क्रीनशॉट", "sh_chats": "चैट", "sha_chats": "चैट सूची: एक समूह और दोस्तों से बातचीत, उनकी फ़ोटो, अपठित संदेश और कौन ऑनलाइन है।", "sh_conversation": "एक बातचीत", "sha_conversation": "फ़ोटो, वॉइस संदेश, इमोजी प्रतिक्रियाओं और डिलीवरी निशानों वाली एक बातचीत।", "sh_group": "समूह चैट", "sha_group": "चार दोस्तों की एक समूह चैट, एक फ़ोटो और प्रतिक्रियाओं के साथ।", "sh_feed": "फ़ीड", "sha_feed": "फ़ीड: दोस्तों की पोस्ट क्रम से, एक फ़ोटो के साथ।", "sh_graph": "दोस्तों का ग्राफ़", "sha_graph": "उपस्थिति मोड में दोस्तों का ग्राफ़: कौन ऑनलाइन, बैकग्राउंड में या ऑफ़लाइन है, और आसपास दोस्तों के दोस्त।", "sh_graphTimeline": "ग्राफ़ की समयरेखा", "sha_graphTimeline": "दोस्तों के ग्राफ़ की समयरेखा: उन दिनों में से एक स्लाइडर जब दोस्तों का दायरा बढ़ा।", "sh_nearby": "आसपास के लोग", "sha_nearby": "आसपास के लोग: कल जिन दोस्तों के पास से गुज़रे, समय के साथ, और आसपास कितने अन्य Zen उपयोगकर्ता थे, केवल फ़ोन पर रखा गया।", "sh_notifications": "सूचनाएँ और ध्वनियाँ", "sha_notifications": "सूचना और ध्वनि सेटिंग्स: सूचना क्या दिखाती है, ऐप की ध्वनियाँ और किन प्रकारों की सूचना मिले।", "sh_storage": "डेटा और स्टोरेज", "sha_storage": "डेटा और स्टोरेज: Zen कितनी जगह लेता है, पोस्ट, मीडिया, बैकअप और अन्य डेटा में बँटा हुआ, सीमा के साथ।", "sh_lock": "लॉक स्क्रीन", "sha_lock": "लॉक स्क्रीन: Zen लॉक है और ऐप पासवर्ड माँगता है, जबकि संदेश आते रहते हैं।", "sh_desktop": "कंप्यूटर पर", "sha_desktop": "कंप्यूटर पर Zen: चौड़ी विंडो में साइड रेल और चैट सूची।", "fl_send": "संदेश भेजना", "fla_send": "एक छोटा एनिमेशन: एक दोस्त को संदेश लिखना और भेजना।", "fl_graph": "बढ़ता ग्राफ़", "fla_graph": "एक छोटा एनिमेशन: दोस्तों का ग्राफ़ एक साल में, एक-एक दोस्त करके बढ़ता है।", "footPromo": "प्रचार सामग्री"},
    "zh": {"navLabel": "主导航", "navInstall": "安装", "navGuide": "指南", "navFeatures": "功能", "navSupport": "帮助", "navAbout": "关于", "navPromo": "素材", "langLabel": "语言", "skip": "跳到正文", "footPrivacy": "隐私政策", "footTerms": "使用条款", "footLicense": "许可证", "footCode": "源代码", "footNote": "Zen 是自由软件（GPL-3.0）。© 2026 Robert Ostrowski-Jagoda。", "trademark": "Apple、iPhone、iOS 和 macOS 是 Apple Inc. 的商标；Windows 是 Microsoft 的商标；Android 是 Google LLC 的商标。Zen 与它们无关联，也未获其认可。", "open": "在 Zen 中打开", "copy": "复制代码", "copied": "已复制 ✓", "getTitle": "获取 Zen", "getLead": "免费，无需注册，没有广告。只要一分钟。", "dlAndroid": "下载 Android 版", "dlWindows": "下载 Windows 版", "dlLinux": "下载 Linux 版", "dlMac": "下载 Mac 版", "dlIphone": "下载 iPhone 版 Zen", "instIphone": "在 iPhone 上安装", "instMac": "在 Mac 上安装", "otherSystem": "其他系统", "otherSystems": "其他系统：", "moreInstall": "所有安装方式与帮助", "whatIsZen": "Zen 是什么？", "recommended": "推荐", "trouble": "出问题时", "otherWays": "其他方式", "allSystems": "所有系统", "nextTitle": "Zen 已安装。接下来呢？", "nextText": "添加你的第一位好友，了解基本用法。", "nextBtn": "如何使用 Zen", "versionLine": "最新版本：{version}（{date}）", "fpUnknown": "随每个版本发布在 GitHub 上", "tocLabel": "本页内容", "honestTitle": "坦率地说：", "thanks_t": "致谢", "thanks_1": "感谢 **[Yggdrasil|https://yggdrasil-network.github.io/]**，Zen 所运行的开放加密网状网络；也感谢 **[SideStore|https://sidestore.io/]**，它在 iPhone 上安装 Zen，并直接在手机上为它续签。", "shotsTitle": "看看实际效果", "shotsSub": "应用的真实界面，使用虚构的演示账户，按你的设备设置显示浅色或深色。", "filmsTitle": "动态演示", "galleryLabel": "Zen 截图", "galleryPrev": "上一张截图", "galleryNext": "下一张截图", "sh_chats": "聊天", "sha_chats": "聊天列表：一个群组和与朋友的对话、他们的照片、未读数量以及谁在线。", "sh_conversation": "一段对话", "sha_conversation": "一段包含照片、语音消息、表情回应和送达标记的对话。", "sh_group": "群聊", "sha_group": "四位朋友的群聊，带有一张照片和回应。", "sh_feed": "动态墙", "sha_feed": "动态墙：朋友的帖子按顺序排列，其中一条带照片。", "sh_graph": "好友图", "sha_graph": "在线状态模式下的好友图：谁在线、在后台或离线，周围是朋友的朋友。", "sh_graphTimeline": "好友图时间线", "sha_graphTimeline": "好友图的时间线：一个滑块，划过朋友圈逐渐扩大的日子。", "sh_nearby": "附近的人", "sha_nearby": "附近的人：昨天擦肩而过的朋友及时间，以及周围还有多少其他 Zen 用户，只保存在手机上。", "sh_notifications": "通知和声音", "sha_notifications": "通知和声音设置：通知显示什么内容、应用内声音以及哪些类型会通知。", "sh_storage": "数据和存储", "sha_storage": "数据和存储：Zen 占用多少空间，按帖子、媒体、备份和其他数据划分，并显示上限。", "sh_lock": "锁屏", "sha_lock": "锁屏：Zen 已锁定并要求输入应用密码，同时消息仍在继续接收。", "sh_desktop": "在电脑上", "sha_desktop": "电脑上的 Zen：宽窗口中的侧边栏和聊天列表。", "fl_send": "发送消息", "fla_send": "一段简短动画：给朋友输入一条消息并发送。", "fl_graph": "好友图的成长", "fla_graph": "一段简短动画：好友图在一年中一位朋友接一位朋友地成长。", "footPromo": "推广材料"},
    "ja": {"navLabel": "メイン", "navInstall": "インストール", "navGuide": "ガイド", "navFeatures": "機能", "navSupport": "サポート", "navAbout": "概要", "navPromo": "素材", "langLabel": "言語", "skip": "本文へ移動", "footPrivacy": "プライバシーポリシー", "footTerms": "利用規約", "footLicense": "ライセンス", "footCode": "ソースコード", "footNote": "Zen はフリーソフトウェア（GPL-3.0）です。© 2026 Robert Ostrowski-Jagoda。", "trademark": "Apple、iPhone、iOS、macOS は Apple Inc. の商標です。Windows は Microsoft の商標です。Android は Google LLC の商標です。Zen はこれらの企業と提携しておらず、承認も受けていません。", "open": "Zen で開く", "copy": "コードをコピー", "copied": "コピーしました ✓", "getTitle": "Zen を入手", "getLead": "無料、登録不要、広告なし。1分で完了します。", "dlAndroid": "Android 版をダウンロード", "dlWindows": "Windows 版をダウンロード", "dlLinux": "Linux 版をダウンロード", "dlMac": "Mac 版をダウンロード", "dlIphone": "iPhone 版 Zen をダウンロード", "instIphone": "iPhone にインストール", "instMac": "Mac にインストール", "otherSystem": "他のシステム", "otherSystems": "その他のシステム：", "moreInstall": "すべてのインストール方法とヘルプ", "whatIsZen": "Zen とは？", "recommended": "おすすめ", "trouble": "うまくいかないとき", "otherWays": "その他の方法", "allSystems": "すべてのシステム", "nextTitle": "Zen をインストールしました。次は？", "nextText": "最初の友だちを追加して、基本を学びましょう。", "nextBtn": "Zen の使い方", "versionLine": "最新バージョン：{version}（{date}）", "fpUnknown": "GitHub の各リリースに記載されています", "tocLabel": "このページの内容", "honestTitle": "正直に言うと：", "thanks_t": "謝辞", "thanks_1": "Zen が動作する、オープンで暗号化されたメッシュネットワーク **[Yggdrasil|https://yggdrasil-network.github.io/]** と、iPhone に Zen をインストールし、端末上で更新し続けてくれる **[SideStore|https://sidestore.io/]** に感謝します。", "shotsTitle": "実際の画面を見る", "shotsSub": "架空のデモアカウントで表示したアプリの実際の画面です。端末の設定に合わせてライトまたはダーク。", "filmsTitle": "動きで見る", "galleryLabel": "Zen のスクリーンショット", "galleryPrev": "前のスクリーンショット", "galleryNext": "次のスクリーンショット", "sh_chats": "チャット", "sha_chats": "チャット一覧：グループと友だちとの会話、写真、未読数、オンラインの人。", "sh_conversation": "会話", "sha_conversation": "写真、ボイスメッセージ、絵文字リアクション、配信マーク付きの会話。", "sh_group": "グループチャット", "sha_group": "写真とリアクションのある、友だち 4 人のグループチャット。", "sh_feed": "フィード", "sha_feed": "フィード：友だちの投稿が順番に並び、1 件は写真付き。", "sh_graph": "友だちグラフ", "sha_graph": "在席モードの友だちグラフ：オンライン、バックグラウンド、オフラインの人と、周りの友だちの友だち。", "sh_graphTimeline": "グラフのタイムライン", "sha_graphTimeline": "友だちグラフのタイムライン：友だちの輪が広がった日々をたどるスライダー。", "sh_nearby": "近くの人", "sha_nearby": "近くの人：昨日すれ違った友だちと時刻、周りにいたほかの Zen ユーザーの数。スマホの中だけに保存。", "sh_notifications": "通知とサウンド", "sha_notifications": "通知とサウンドの設定：通知に表示する内容、アプリ内サウンド、通知する種類。", "sh_storage": "データとストレージ", "sha_storage": "データとストレージ：Zen が使う容量を投稿、メディア、バックアップ、その他のデータに分けて上限とともに表示。", "sh_lock": "ロック画面", "sha_lock": "ロック画面：Zen はロックされアプリのパスワードを求めますが、メッセージは届き続けます。", "sh_desktop": "パソコンで", "sha_desktop": "パソコンの Zen：広いウィンドウにサイドレールとチャット一覧。", "fl_send": "メッセージを送る", "fla_send": "短いアニメーション：友だちにメッセージを入力して送信。", "fl_graph": "広がるグラフ", "fla_graph": "短いアニメーション：友だちグラフが 1 年かけて一人ずつ広がっていきます。", "footPromo": "宣伝素材"},
    "ko": {"navLabel": "주 메뉴", "navInstall": "설치", "navGuide": "가이드", "navFeatures": "기능", "navSupport": "도움말", "navAbout": "소개", "navPromo": "자료", "langLabel": "언어", "skip": "본문으로 건너뛰기", "footPrivacy": "개인정보 처리방침", "footTerms": "이용 약관", "footLicense": "라이선스", "footCode": "소스 코드", "footNote": "Zen은 자유 소프트웨어(GPL-3.0)입니다. © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS, macOS는 Apple Inc.의 상표이고, Windows는 Microsoft의 상표이며, Android는 Google LLC의 상표입니다. Zen은 이들과 제휴하지 않았으며 이들의 보증을 받지 않았습니다.", "open": "Zen에서 열기", "copy": "코드 복사", "copied": "복사됨 ✓", "getTitle": "Zen 받기", "getLead": "무료, 가입 없음, 광고 없음. 1분이면 됩니다.", "dlAndroid": "Android용 다운로드", "dlWindows": "Windows용 다운로드", "dlLinux": "Linux용 다운로드", "dlMac": "Mac용 다운로드", "dlIphone": "iPhone용 Zen 다운로드", "instIphone": "iPhone에 설치", "instMac": "Mac에 설치", "otherSystem": "다른 시스템", "otherSystems": "다른 시스템:", "moreInstall": "모든 설치 방법과 도움말", "whatIsZen": "Zen이란?", "recommended": "권장", "trouble": "문제가 생겼을 때", "otherWays": "다른 방법", "allSystems": "모든 시스템", "nextTitle": "Zen을 설치했어요. 이제 무엇을 할까요?", "nextText": "첫 친구를 추가하고 기본을 익혀 보세요.", "nextBtn": "Zen 사용법", "versionLine": "최신 버전: {version} ({date})", "fpUnknown": "GitHub의 각 릴리스에 표시됩니다", "tocLabel": "이 페이지의 내용", "honestTitle": "솔직히 말하면:", "thanks_t": "감사의 말", "thanks_1": "Zen이 동작하는 열린 암호화 메시 네트워크 **[Yggdrasil|https://yggdrasil-network.github.io/]**, 그리고 iPhone에 Zen을 설치하고 휴대폰에서 바로 갱신해 주는 **[SideStore|https://sidestore.io/]**에 감사드립니다.", "shotsTitle": "실제로 살펴보기", "shotsSub": "가상의 데모 계정으로 보여 주는 앱의 실제 화면이에요. 기기 설정에 따라 밝게 또는 어둡게 보여요.", "filmsTitle": "움직이는 모습", "galleryLabel": "Zen 스크린샷", "galleryPrev": "이전 스크린샷", "galleryNext": "다음 스크린샷", "sh_chats": "채팅", "sha_chats": "채팅 목록: 그룹과 친구들과의 대화, 친구 사진, 읽지 않은 메시지 수, 온라인인 사람.", "sh_conversation": "대화", "sha_conversation": "사진, 음성 메시지, 이모지 반응, 전송 표시가 있는 대화.", "sh_group": "그룹 채팅", "sha_group": "사진과 반응이 있는 친구 네 명의 그룹 채팅.", "sh_feed": "피드", "sha_feed": "피드: 친구들의 게시물이 순서대로, 그중 하나는 사진과 함께.", "sh_graph": "친구 그래프", "sha_graph": "접속 상태 모드의 친구 그래프: 누가 온라인, 백그라운드, 오프라인인지와 주변의 친구의 친구.", "sh_graphTimeline": "그래프 타임라인", "sha_graphTimeline": "친구 그래프의 타임라인: 친구의 범위가 넓어진 날들을 따라가는 슬라이더.", "sh_nearby": "근처 사람들", "sha_nearby": "근처 사람들: 어제 스쳐 지나간 친구와 시간, 주변에 있던 다른 Zen 사용자 수. 휴대폰에만 저장돼요.", "sh_notifications": "알림 및 소리", "sha_notifications": "알림 및 소리 설정: 알림에 보이는 내용, 앱 안의 소리, 알림을 받을 종류.", "sh_storage": "데이터 및 저장 공간", "sha_storage": "데이터 및 저장 공간: Zen이 차지하는 공간을 게시물, 미디어, 백업, 기타 데이터로 나누어 한도와 함께 보여 줘요.", "sh_lock": "잠금 화면", "sha_lock": "잠금 화면: Zen이 잠겨 앱 비밀번호를 묻는 동안에도 메시지는 계속 도착해요.", "sh_desktop": "컴퓨터에서", "sha_desktop": "컴퓨터의 Zen: 넓은 창에 보이는 사이드 레일과 채팅 목록.", "fl_send": "메시지 보내기", "fla_send": "짧은 애니메이션: 친구에게 메시지를 입력해 보내기.", "fl_graph": "자라는 그래프", "fla_graph": "짧은 애니메이션: 친구 그래프가 1년 동안 친구 한 명씩 자라나요.", "footPromo": "홍보 자료"},
  };

  // Icons (Feather-style, 24 px, drawn with the text colour).
  var ICONS = {
    globe: '<circle cx="12" cy="12" r="10"/><path d="M2 12h20"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/>',
    chev: '<polyline points="6 9 12 15 18 9"/>',
    info: '<circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/>',
    download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>',
    open: '<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/>',
    copy: '<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
    list: '<line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/>',
    noserver: '<rect x="3" y="3" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="7" rx="2"/><line x1="7" y1="6.5" x2="7.01" y2="6.5"/><line x1="7" y1="17.5" x2="7.01" y2="17.5"/><line x1="2" y1="22" x2="22" y2="2"/>',
    users: '<path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
    lock: '<rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
    code: '<polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/>',
    phone: '<rect x="5" y="2" width="14" height="20" rx="2"/><line x1="12" y1="18" x2="12.01" y2="18"/>',
    monitor: '<rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/>',
    laptop: '<rect x="3" y="4" width="18" height="12" rx="2"/><line x1="2" y1="20" x2="22" y2="20"/>',
    terminal: '<polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/>',
    heart: '<path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/>',
    coffee: '<path d="M18 8h1a4 4 0 0 1 0 8h-1"/><path d="M2 8h16v9a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4V8z"/><line x1="6" y1="1" x2="6" y2="4"/><line x1="10" y1="1" x2="10" y2="4"/><line x1="14" y1="1" x2="14" y2="4"/>',
    message: '<path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"/>',
    pin: '<path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z"/><circle cx="12" cy="10" r="3"/>',
    calendar: '<rect x="3" y="4" width="18" height="18" rx="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/>',
    wifi: '<path d="M5 12.55a11 11 0 0 1 14.08 0"/><path d="M1.42 9a16 16 0 0 1 21.16 0"/><path d="M8.53 16.11a6 6 0 0 1 6.95 0"/><line x1="12" y1="20" x2="12.01" y2="20"/>',
    shield: '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>',
    book: '<path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/>',
    file: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/>',
    alert: '<path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>',
    tag: '<path d="M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82z"/><line x1="7" y1="7" x2="7.01" y2="7"/>',
    check: '<path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/>',
    mail: '<path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"/><polyline points="22,6 12,13 2,6"/>',
    bell: '<path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/>',
    key: '<path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.78 7.78 5.5 5.5 0 0 1 7.78-7.78zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4"/>',
    eye: '<path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/>',
    video: '<polygon points="23 7 16 12 23 17 23 7"/><rect x="1" y="5" width="15" height="14" rx="2"/>',
    call: '<path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"/>',
    cpu: '<rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><line x1="9" y1="1" x2="9" y2="4"/><line x1="15" y1="1" x2="15" y2="4"/><line x1="9" y1="20" x2="9" y2="23"/><line x1="15" y1="20" x2="15" y2="23"/><line x1="20" y1="9" x2="23" y2="9"/><line x1="20" y1="14" x2="23" y2="14"/><line x1="1" y1="9" x2="4" y2="9"/><line x1="1" y1="14" x2="4" y2="14"/>',
    mesh: '<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><line x1="8.59" y1="13.51" x2="15.42" y2="17.49"/><line x1="15.41" y1="6.51" x2="8.59" y2="10.49"/>',
    layers: '<polygon points="12 2 2 7 12 12 22 7 12 2"/><polyline points="2 17 12 22 22 17"/><polyline points="2 12 12 17 22 12"/>',
    image: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/>',
    arrow: '<line x1="5" y1="12" x2="19" y2="12"/><polyline points="12 5 19 12 12 19"/>',
    refresh: '<polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>',
    grid: '<rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/>',
    bug: '<rect x="8" y="6" width="8" height="14" rx="4"/><path d="M19 7l-3 2M5 7l3 2M19 19l-3-2M5 19l3-2M20 13h-4M4 13h4M10 4l1 2M14 4l-1 2"/>',
    clock: '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
    trend: '<polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/><polyline points="17 6 23 6 23 12"/>',
    bluetooth: '<polyline points="6.5 6.5 17.5 17.5 12 23 12 1 17.5 6.5 6.5 17.5"/>',
    lifebuoy: '<circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="4"/><line x1="4.93" y1="4.93" x2="9.17" y2="9.17"/><line x1="14.83" y1="14.83" x2="19.07" y2="19.07"/><line x1="14.83" y1="9.17" x2="19.07" y2="4.93"/><line x1="4.93" y1="19.07" x2="9.17" y2="14.83"/>',
    package: '<line x1="16.5" y1="9.4" x2="7.5" y2="4.21"/><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/>',
    home: '<path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/>',
    star: '<polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/>',
    globe2: '<circle cx="12" cy="12" r="10"/><path d="M2 12h20"/>',
    eyeoff: '<path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"/><path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"/><path d="M14.12 14.12a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/>',
    gift: '<polyline points="20 12 20 22 4 22 4 12"/><rect x="2" y="7" width="20" height="5"/><line x1="12" y1="22" x2="12" y2="7"/><path d="M12 7H7.5a2.5 2.5 0 0 1 0-5C11 2 12 7 12 7z"/><path d="M12 7h4.5a2.5 2.5 0 0 0 0-5C13 2 12 7 12 7z"/>',
    printer: '<polyline points="6 9 6 2 18 2 18 9"/><path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"/><rect x="6" y="14" width="12" height="8"/>'
  };
  var FILL = {
    discord: ["0 0 24 24", 'M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z'],
    github: ["0 0 16 16", 'M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z']
  };

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }
  function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }

  var pageTexts = {};
  var pageLinks = {};
  var lang = "en";
  var opts = {};

  // A text of the page for [key]: [text, translated?] or null.
  function lookup(key, l) {
    var p = pageTexts[l], c = COMMON[l];
    if (p && has(p, key)) { return [p[key], true]; }
    if (c && has(c, key)) { return [c[key], true]; }
    p = pageTexts.en; c = COMMON.en;
    if (p && has(p, key)) { return [p[key], l === "en"]; }
    if (c && has(c, key)) { return [c[key], l === "en"]; }
    return null;
  }
  function t(key, vars) {
    var r = lookup(key, lang);
    var s = r ? r[0] : "";
    if (vars) {
      Object.keys(vars).forEach(function (k) { s = s.split("{" + k + "}").join(vars[k]); });
    }
    return s;
  }
  // Plain text with **bold**, `code` and [label|key] (a link of the page's
  // links, an address or a path): built from escaped text, never from HTML.
  function render(text) {
    var h = esc(text);
    h = h.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>");
    h = h.replace(/`([^`]+)`/g, "<code>$1</code>");
    h = h.replace(/\[([^|\]]+)\|([^\]]+)\]/g, function (_, label, key) {
      var href = has(pageLinks, key) ? pageLinks[key] : (has(URLS, key) ? URLS[key] : key);
      var ext = /^https?:/.test(href) ? ' rel="noopener"' : "";
      return '<a href="' + esc(href) + '"' + ext + ">" + label + "</a>";
    });
    return h;
  }

  function icon(name, cls) {
    return '<svg class="ico' + (cls ? " " + cls : "") + '" aria-hidden="true"><use href="#i-' + name + '"/></svg>';
  }

  function sprite() {
    var s = '<svg width="0" height="0" style="position:absolute" aria-hidden="true" focusable="false">' +
      '<defs><linearGradient id="zg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6d3df5"/>' +
      '<stop offset="1" stop-color="#b01fc4"/></linearGradient></defs>';
    Object.keys(ICONS).forEach(function (k) {
      s += '<symbol id="i-' + k + '" viewBox="0 0 24 24">' + ICONS[k] + "</symbol>";
    });
    Object.keys(FILL).forEach(function (k) {
      s += '<symbol id="i-' + k + '" viewBox="' + FILL[k][0] + '"><path d="' + FILL[k][1] + '"/></symbol>';
    });
    return s + "</svg>";
  }

  var NAV = [
    ["install", "install/", "download", "navInstall"],
    ["guide", "guide/", "book", "navGuide"],
    ["features", "features/", "layers", "navFeatures"],
    ["support", "support/", "lifebuoy", "navSupport"],
    ["about", "about/", "info", "navAbout"],
    ["promo", "promo/", "image", "navPromo"]
  ];

  function buildChrome() {
    var active = document.body.getAttribute("data-nav") || "";
    document.body.insertAdjacentHTML("afterbegin", sprite() +
      '<a class="skip" href="#main" data-i="skip"></a>');
    var top = document.getElementById("zenTop");
    if (top) {
      var nav = NAV.map(function (n) {
        return '<a href="' + ROOT + n[1] + '"' + (n[0] === active ? ' aria-current="page"' : "") + ">" +
          icon(n[2]) + '<span data-i="' + n[3] + '"></span></a>';
      }).join("");
      top.innerHTML = '<div class="top-in">' +
        '<a class="brand" href="' + ROOT + 'about/"><img src="' + ROOT + 'zen-icon.png" width="32" height="32" alt=""><span>Zen</span></a>' +
        '<nav class="topnav" data-ial="navLabel">' + nav + "</nav>" +
        '<div class="langpick">' + icon("globe") +
        '<span class="lc" id="langCode" aria-hidden="true">EN</span>' +
        '<span class="ln" id="langName" aria-hidden="true">English</span>' + icon("chev", "chev") +
        '<select id="langSel" data-ial="langLabel"></select></div></div>';
      // On a phone the row may scroll: the open page is in view.
      var current = top.querySelector('.topnav [aria-current="page"]');
      if (current) {
        var row = current.parentNode;
        var centre = function () {
          row.scrollLeft = current.offsetLeft - (row.clientWidth - current.offsetWidth) / 2;
        };
        requestAnimationFrame(centre);
        window.addEventListener("load", centre);
      }
    }
    var foot = document.getElementById("zenFoot");
    if (foot) {
      foot.innerHTML = '<div class="foot-links">' +
        '<a href="' + URLS.privacy + '" rel="noopener" data-i="footPrivacy"></a>' +
        '<a href="' + URLS.terms + '" rel="noopener" data-i="footTerms"></a>' +
        '<a href="' + URLS.license + '" rel="noopener" data-i="footLicense"></a>' +
        '<a href="' + URLS.repo + '" rel="noopener" data-i="footCode"></a>' +
        '<a href="' + URLS.discord + '" rel="noopener">Discord</a>' +
        '<a href="' + ROOT + 'promo/" data-i="footPromo"></a></div>' +
        (foot.hasAttribute("data-tm") ? '<p class="tm" data-i="trademark"></p>' : "") +
        '<p data-i="footNote"></p>';
    }
    var main = document.querySelector("main");
    if (main && !main.id) { main.id = "main"; }
    var picker = document.getElementById("langSel");
    if (picker) {
      Object.keys(NAMES).forEach(function (k) {
        var o = document.createElement("option");
        o.value = k;
        o.textContent = NAMES[k];
        picker.appendChild(o);
      });
      picker.addEventListener("change", function () {
        if (!has(NAMES, picker.value)) { return; }
        lang = picker.value;
        try { localStorage.setItem(STORE_KEY, lang); } catch (e) { /* not remembered */ }
        apply();
      });
    }
  }

  function pickLanguage() {
    var wanted = [];
    var m = /(?:^|[?&])lang=([A-Za-z-]+)/.exec(location.search);
    if (m) { wanted.push(m[1]); }
    try {
      var saved = localStorage.getItem(STORE_KEY);
      if (saved) { wanted.push(saved); }
    } catch (e) { /* the storage may be blocked */ }
    var list = navigator.languages && navigator.languages.length
      ? navigator.languages : [navigator.language || "en"];
    for (var i = 0; i < list.length; i++) { wanted.push(list[i]); }
    for (var j = 0; j < wanted.length; j++) {
      var base = String(wanted[j]).toLowerCase().split(/[-_]/)[0];
      base = ALIASES[base] || base;
      if (has(NAMES, base)) { return base; }
    }
    return "en";
  }

  // The canonical address (and og:url) of this very address: "?lang=xx" is
  // the page in another of its languages (the hreflang alternates of the
  // head), its own address; without it, or with English, the page's.
  function canonical() {
    var link = document.querySelector('link[rel="canonical"]');
    if (!link) { return; }
    var base = link.getAttribute("href").replace(/[?#].*$/, "");
    var m = /(?:^|[?&])lang=([A-Za-z-]+)/.exec(location.search);
    var code = m ? m[1].toLowerCase() : "";
    var url = has(NAMES, code) && code !== "en" ? base + "?lang=" + code : base;
    link.setAttribute("href", url);
    var og = document.querySelector('meta[property="og:url"]');
    if (og) { og.setAttribute("content", url); }
  }

  // All texts of the page; run again when the visitor picks another language.
  function apply() {
    var root = document.documentElement;
    root.lang = lang;
    root.dir = RTL[lang] ? "rtl" : "ltr";
    var title = lookup("title", lang);
    if (title) { document.title = title[0]; }
    var desc = lookup("desc", lang);
    // The description and the link preview (Open Graph, Twitter card) follow
    // the language too.
    function content(selector, value) {
      if (!value) { return; }
      Array.prototype.forEach.call(document.querySelectorAll(selector), function (el) {
        el.setAttribute("content", value);
      });
    }
    content('meta[property="og:title"], meta[name="twitter:title"]', title && title[0]);
    content('meta[name="description"], meta[property="og:description"], meta[name="twitter:description"]',
      desc && desc[0]);
    content('meta[property="og:locale"]', LOCALES[lang]);
    var others = Object.keys(LOCALES).filter(function (k) { return k !== lang; });
    Array.prototype.forEach.call(document.querySelectorAll('meta[property="og:locale:alternate"]'), function (el, i) {
      if (others[i]) { el.setAttribute("content", LOCALES[others[i]]); }
    });
    function mark(el, translated) {
      // An English text on a right-to-left page keeps its own direction.
      if (translated || !RTL[lang]) { el.removeAttribute("dir"); } else { el.setAttribute("dir", "ltr"); }
    }
    Array.prototype.forEach.call(document.querySelectorAll("[data-i]"), function (el) {
      var r = lookup(el.getAttribute("data-i"), lang);
      if (!r) { return; }
      el.innerHTML = render(r[0]);
      mark(el, r[1]);
    });
    [["data-ia", "alt"], ["data-ial", "aria-label"], ["data-it", "title"]].forEach(function (p) {
      Array.prototype.forEach.call(document.querySelectorAll("[" + p[0] + "]"), function (el) {
        var r = lookup(el.getAttribute(p[0]), lang);
        if (r) { el.setAttribute(p[1], r[0]); }
      });
    });
    showShots();
    var code = document.getElementById("langCode"), name = document.getElementById("langName");
    if (code) { code.textContent = lang.toUpperCase(); }
    if (name) { name.textContent = NAMES[lang] || lang; }
    var sel = document.getElementById("langSel");
    if (sel) { sel.value = lang; }
    showRelease();
    if (opts.onLang) { opts.onLang(lang); }
  }

  // The screenshots and films (shots/<lang>/...) in the language shown, or in
  // English where there are none in it.
  function showShots() {
    var folder = "shots/" + (SHOT_LANGS.indexOf(lang) >= 0 ? lang : "en") + "/";
    function swap(el, attr) {
      var v = el.getAttribute(attr);
      var n = v.replace(/shots\/[a-z]{2}\//, folder);
      if (n !== v) { el.setAttribute(attr, n); }
    }
    Array.prototype.forEach.call(document.querySelectorAll('img[src*="shots/"]'), function (el) {
      swap(el, "src");
    });
    Array.prototype.forEach.call(document.querySelectorAll('source[srcset*="shots/"]'), function (el) {
      swap(el, "srcset");
    });
  }

  // The galleries (.gallery): a row of screenshots that scrolls sideways on
  // its own (swipe, the arrow buttons, or the arrow keys once it has focus),
  // never the page; each button rests at its end of the row.
  function galleries() {
    // The owner's decision: animations run for every visitor, whatever the system says about reduced motion (prefers-reduced-motion).
    Array.prototype.forEach.call(document.querySelectorAll(".gallery"), function (g) {
      var track = g.querySelector(".gallery-track");
      var prev = g.querySelector(".gallery-prev"), next = g.querySelector(".gallery-next");
      if (!track) { return; }
      // Right to left, the row starts on the right and "next" goes left.
      function sign() { return document.documentElement.dir === "rtl" ? -1 : 1; }
      var items = track.querySelectorAll(".shot");
      // The picture nearest the middle of the row.
      function current() {
        var box = track.getBoundingClientRect(), mid = box.left + box.width / 2;
        var best = 0, far = Infinity;
        Array.prototype.forEach.call(items, function (el, i) {
          var r = el.getBoundingClientRect(), d = Math.abs(r.left + r.width / 2 - mid);
          if (d < far) { far = d; best = i; }
        });
        return best;
      }
      // [n] pictures on in the order of the page (to the left right to left).
      function go(n) {
        var i = Math.max(0, Math.min(items.length - 1, current() + n));
        if (items[i]) {
          items[i].scrollIntoView({ behavior: "smooth", block: "nearest", inline: "center" });
        }
      }
      function ends() {
        var max = track.scrollWidth - track.clientWidth - 2;
        var at = Math.abs(track.scrollLeft);
        if (prev) { prev.disabled = at <= 2; }
        if (next) { next.disabled = at >= max; }
      }
      if (prev) { prev.addEventListener("click", function () { go(-1); }); }
      if (next) { next.addEventListener("click", function () { go(1); }); }
      track.addEventListener("keydown", function (e) {
        var back = sign() > 0 ? "ArrowLeft" : "ArrowRight";
        var on = sign() > 0 ? "ArrowRight" : "ArrowLeft";
        if (e.key === back || e.key === on) {
          e.preventDefault();
          go(e.key === on ? 1 : -1);
        } else if (e.key === "Home" || e.key === "End") {
          e.preventDefault();
          var far = (track.scrollWidth - track.clientWidth) * sign();
          track.scrollTo({ left: e.key === "Home" ? 0 : far, behavior: "smooth" });
        }
      });
      track.addEventListener("scroll", ends, { passive: true });
      window.addEventListener("resize", ends);
      ends();
      // A mouse drags the row as a finger does: snapping is off while it
      // moves and on again after, landing on the nearest picture; a drag
      // is not taken for a click on a picture.
      var drag = null;
      track.addEventListener("pointerdown", function (e) {
        if (e.pointerType !== "mouse" || e.button !== 0) { return; }
        drag = { x: e.clientX, left: track.scrollLeft, moved: false };
        track.classList.add("dragging");
        track.setPointerCapture(e.pointerId);
      });
      track.addEventListener("pointermove", function (e) {
        if (!drag) { return; }
        var dx = e.clientX - drag.x;
        if (Math.abs(dx) > 4) { drag.moved = true; }
        track.scrollLeft = drag.left - dx;
      });
      var dragged = false;
      function release() {
        if (!drag) { return; }
        dragged = drag.moved;
        drag = null;
        track.classList.remove("dragging");
        if (dragged) {
          go(0);
          // The click that ends a drag opens nothing.
          setTimeout(function () { dragged = false; }, 0);
        }
      }
      track.addEventListener("pointerup", release);
      track.addEventListener("pointercancel", release);
      track.addEventListener("click", function (e) {
        if (dragged) { e.preventDefault(); e.stopPropagation(); }
      }, true);
      track.addEventListener("dragstart", function (e) { e.preventDefault(); });
    });
  }

  // The latest release's version pill ([data-version]) and signing
  // certificate ([data-fp]); filled once release.json has come.
  var releaseData = null;
  function showRelease() {
    Array.prototype.forEach.call(document.querySelectorAll("[data-version]"), function (el) {
      el.textContent = releaseData
        ? t("versionLine", { version: releaseData.version, date: releaseData.date || "" }).replace(/ \(\)$/, "")
        : "";
    });
    Array.prototype.forEach.call(document.querySelectorAll("[data-fp]"), function (el) {
      var fp = releaseData && releaseData.apkCertificateSha256;
      el.textContent = fp ? fp.match(/../g).join(":").toUpperCase() : t("fpUnknown");
    });
  }

  function detectOs() {
    var ua = navigator.userAgent || "";
    if (/android/i.test(ua)) { return "android"; }
    if (/iphone|ipad|ipod/i.test(ua) ||
        (/macintosh/i.test(ua) && navigator.maxTouchPoints > 1)) { return "iphone"; }
    if (/windows/i.test(ua)) { return "windows"; }
    if (/macintosh|mac os x/i.test(ua)) { return "macos"; }
    if (/cros/i.test(ua)) { return ""; }
    if (/linux|x11/i.test(ua)) { return "linux"; }
    return "";
  }

  var Zen = {
    root: ROOT,
    urls: URLS,
    names: NAMES,
    os: detectOs(),
    icon: icon,
    t: t,
    render: render,
    esc: esc,
    lang: function () { return lang; },
    init: function (o) {
      opts = o || {};
      pageTexts = opts.texts || {};
      pageLinks = opts.links || {};
      buildChrome();
      canonical();
      lang = pickLanguage();
      apply();
      galleries();
      if (document.querySelector("[data-version], [data-fp]")) {
        Zen.release(function (d) { releaseData = d; showRelease(); });
      }
      return Zen;
    },
    // The version, the date and the signing certificate of the latest
    // release (release.json, made by the Pages workflow); [done] gets null
    // when there is none.
    release: function (done) {
      fetch(ROOT + "release.json", { cache: "no-cache" })
        .then(function (r) { return r.ok ? r.json() : null; })
        .then(function (d) { done(d && d.version ? d : null); })
        .catch(function () { done(null); });
    },
    copy: function (text, done) {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () {});
      }
    },
    // The download buttons of the home and door pages: the visitor's own
    // system gets its button (an unknown system sees all five), and the
    // "Other system" list (#osPick) swaps it for another system's.
    systemButtons: function () {
      var ids = ["android", "windows", "linux", "iphone", "macos"];
      var pick = document.getElementById("osPick");
      function show(system) {
        ids.forEach(function (id) {
          var b = document.getElementById(id);
          b.classList.toggle("hidden", !!system && id !== system);
          if (!system) { b.classList.remove("primary"); b.classList.add("secondary"); }
        });
        var more = document.getElementById("otherAndroid");
        if (more) { more.classList.toggle("hidden", !!system && system !== "android"); }
      }
      show(Zen.os);
      if (!pick) { return; }
      if (!Zen.os) { document.getElementById("others").classList.add("hidden"); return; }
      pick.addEventListener("change", function () { show(pick.value || Zen.os); });
    },
    // The table of contents (.toc): on phones one button with the section
    // being read that opens the list, and the entry of that section marked.
    toc: function () {
      var nav = document.querySelector(".toc");
      var links = Array.prototype.slice.call(document.querySelectorAll(".toc a"));
      if (!nav || !links.length) { return; }
      var list = nav.querySelector("ul");
      list.id = list.id || "toc-list";
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "toc-btn";
      btn.setAttribute("aria-expanded", "false");
      btn.setAttribute("aria-controls", list.id);
      var label = document.createElement("small");
      var current = document.createElement("span");
      btn.appendChild(label);
      btn.appendChild(current);
      nav.insertBefore(btn, list);
      nav.classList.add("js");
      function show(a) {
        label.textContent = nav.getAttribute("aria-label") + (a ? ":" : "");
        current.textContent = a ? a.textContent : "";
      }
      function open(yes) {
        nav.classList.toggle("open", yes);
        btn.setAttribute("aria-expanded", yes ? "true" : "false");
      }
      show(null);
      btn.addEventListener("click", function () { open(!nav.classList.contains("open")); });
      links.forEach(function (a) { a.addEventListener("click", function () { open(false); }); });
      document.addEventListener("keydown", function (e) { if (e.key === "Escape") { open(false); } });
      document.addEventListener("click", function (e) { if (!nav.contains(e.target)) { open(false); } });
      // The language switch rewrites the texts: the button follows.
      var watch = new MutationObserver(function () {
        show(nav.querySelector('a[aria-current="location"]'));
      });
      watch.observe(list, { subtree: true, characterData: true, childList: true });
      watch.observe(nav, { attributes: true, attributeFilter: ["aria-label"] });
      if (!("IntersectionObserver" in window)) { return; }
      var byId = {};
      links.forEach(function (a) { byId[a.getAttribute("href").slice(1)] = a; });
      var observer = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (!e.isIntersecting || !byId[e.target.id]) { return; }
          links.forEach(function (a) { a.removeAttribute("aria-current"); });
          var a = byId[e.target.id];
          a.setAttribute("aria-current", "location");
          show(a);
        });
      }, { rootMargin: "-20% 0px -70% 0px" });
      Object.keys(byId).forEach(function (id) {
        var el = document.getElementById(id);
        if (el) { observer.observe(el); }
      });
    }
  };
  window.Zen = Zen;
})();
