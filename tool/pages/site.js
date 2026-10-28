// Shared script of all the Zen pages: the header, the footer and the icons,
// the language of the visitor (21 languages; "?lang=xx", the saved choice
// "zen-lang", then the browser's languages) and a few helpers. Every page
// holds its own texts (TEXTS, English and the other languages) and calls
// Zen.init({texts: TEXTS, links: {...}, onLang: function () {...}}); the
// texts shared by all pages are in COMMON below. Elements with data-i="key"
// get the text of that key (markup: **bold**, `code`, [label|key] for a link
// of the page's links, never HTML), data-ia / data-ial / data-it the
// alt / aria-label / title attribute.
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
  var ALIASES = { "in": "id", "iw": "he", "nb": "en", "no": "en" };

  // The texts every page shows (header, footer, the buttons of the home,
  // door and install pages).
  var COMMON = {
    "en": {"navLabel": "Main", "navInstall": "Install", "navGuide": "Guide", "navFeatures": "Features", "navSupport": "Support", "navAbout": "About", "langLabel": "Language", "skip": "Skip to content", "footPrivacy": "Privacy policy", "footTerms": "Terms of use", "footLicense": "License", "footCode": "Source code", "footNote": "Zen is free software (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS and macOS are trademarks of Apple Inc.; Windows is a trademark of Microsoft; Android is a trademark of Google LLC. Zen is not affiliated with or endorsed by them.", "open": "Open in Zen", "copy": "Copy code", "copied": "Copied ✓", "getTitle": "Get Zen", "getLead": "Free, no sign-up, no ads. It takes a minute.", "dlAndroid": "Download for Android", "dlWindows": "Download for Windows", "dlLinux": "Download for Linux", "dlMac": "Download for Mac", "dlIphone": "Download Zen for iPhone", "instIphone": "Install on iPhone", "instMac": "Install on Mac", "otherSystem": "Other system", "otherSystems": "Other systems:", "moreInstall": "All install options and help", "whatIsZen": "What is Zen?", "recommended": "Recommended", "trouble": "If something goes wrong", "otherWays": "Other ways", "allSystems": "All systems", "nextTitle": "Zen is installed. What now?", "nextText": "Add your first friend and learn the basics.", "nextBtn": "How to use Zen", "versionLine": "Latest version: {version} ({date})", "fpUnknown": "shown with each release on GitHub", "tocLabel": "On this page", "honestTitle": "Honestly:", "thanks_t": "Thanks", "thanks_1": "Thanks to **[Yggdrasil|https://yggdrasil-network.github.io/]**, the open, encrypted mesh network Zen runs on, and **[Scarlet|https://usescarlet.com/]**, which makes installing Zen on an iPhone simple."},
    "pl": {"navLabel": "Główne", "navInstall": "Instalacja", "navGuide": "Poradnik", "navFeatures": "Funkcje", "navSupport": "Pomoc", "navAbout": "O Zen", "langLabel": "Język", "skip": "Przejdź do treści", "footPrivacy": "Polityka prywatności", "footTerms": "Regulamin", "footLicense": "Licencja", "footCode": "Kod źródłowy", "footNote": "Zen to wolne oprogramowanie (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS i macOS są znakami towarowymi Apple Inc.; Windows jest znakiem towarowym Microsoftu; Android jest znakiem towarowym Google LLC. Zen nie jest z nimi powiązany ani przez nie popierany.", "open": "Otwórz w Zen", "copy": "Skopiuj kod", "copied": "Skopiowano ✓", "getTitle": "Pobierz Zen", "getLead": "Za darmo, bez rejestracji i reklam. Zajmie minutę.", "dlAndroid": "Pobierz na Androida", "dlWindows": "Pobierz na Windows", "dlLinux": "Pobierz na Linuksa", "dlMac": "Pobierz na Maca", "dlIphone": "Pobierz Zen na iPhone’a", "instIphone": "Zainstaluj na iPhonie", "instMac": "Zainstaluj na Macu", "otherSystem": "Inny system", "otherSystems": "Inne systemy:", "moreInstall": "Wszystkie sposoby instalacji i pomoc", "whatIsZen": "Czym jest Zen?", "recommended": "Polecany sposób", "trouble": "Gdy coś pójdzie nie tak", "otherWays": "Inne sposoby", "allSystems": "Wszystkie systemy", "nextTitle": "Zen jest zainstalowany. Co dalej?", "nextText": "Dodaj pierwszego znajomego i poznaj podstawy.", "nextBtn": "Jak używać Zen", "versionLine": "Najnowsza wersja: {version} ({date})", "fpUnknown": "podany przy każdym wydaniu na GitHubie", "tocLabel": "Na tej stronie", "honestTitle": "Szczerze:", "thanks_t": "Podziękowania", "thanks_1": "Dziękujemy **[Yggdrasil|https://yggdrasil-network.github.io/]**, otwartej, szyfrowanej sieci mesh, na której działa Zen, oraz **[Scarlet|https://usescarlet.com/]**, który ułatwia instalację Zen na iPhonie."},
    "id": {"navLabel": "Utama", "navInstall": "Pasang", "navGuide": "Panduan", "navFeatures": "Fitur", "navSupport": "Bantuan", "navAbout": "Tentang", "langLabel": "Bahasa", "skip": "Langsung ke konten", "footPrivacy": "Kebijakan privasi", "footTerms": "Ketentuan penggunaan", "footLicense": "Lisensi", "footCode": "Kode sumber", "footNote": "Zen adalah perangkat lunak bebas (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS, dan macOS adalah merek dagang Apple Inc.; Windows adalah merek dagang Microsoft; Android adalah merek dagang Google LLC. Zen tidak berafiliasi dengan atau didukung oleh mereka.", "open": "Buka di Zen", "copy": "Salin kode", "copied": "Tersalin ✓", "getTitle": "Dapatkan Zen", "getLead": "Gratis, tanpa pendaftaran, tanpa iklan. Hanya semenit.", "dlAndroid": "Unduh untuk Android", "dlWindows": "Unduh untuk Windows", "dlLinux": "Unduh untuk Linux", "dlMac": "Unduh untuk Mac", "dlIphone": "Unduh Zen untuk iPhone", "instIphone": "Pasang di iPhone", "instMac": "Pasang di Mac", "otherSystem": "Sistem lain", "otherSystems": "Sistem lain:", "moreInstall": "Semua cara memasang dan bantuan", "whatIsZen": "Apa itu Zen?", "recommended": "Disarankan", "trouble": "Jika ada masalah", "otherWays": "Cara lain", "allSystems": "Semua sistem", "nextTitle": "Zen sudah terpasang. Lalu apa?", "nextText": "Tambahkan teman pertama Anda dan pelajari dasarnya.", "nextBtn": "Cara memakai Zen", "versionLine": "Versi terbaru: {version} ({date})", "fpUnknown": "ditampilkan di setiap rilis di GitHub", "tocLabel": "Di halaman ini", "honestTitle": "Jujur saja:", "thanks_t": "Terima kasih", "thanks_1": "Terima kasih kepada **[Yggdrasil|https://yggdrasil-network.github.io/]**, jaringan mesh terbuka dan terenkripsi tempat Zen berjalan, dan **[Scarlet|https://usescarlet.com/]**, yang membuat memasang Zen di iPhone menjadi mudah."},
    "cs": {"navLabel": "Hlavní", "navInstall": "Instalace", "navGuide": "Návod", "navFeatures": "Funkce", "navSupport": "Pomoc", "navAbout": "O Zen", "langLabel": "Jazyk", "skip": "Přejít na obsah", "footPrivacy": "Zásady ochrany soukromí", "footTerms": "Podmínky použití", "footLicense": "Licence", "footCode": "Zdrojový kód", "footNote": "Zen je svobodný software (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS a macOS jsou ochranné známky společnosti Apple Inc.; Windows je ochranná známka společnosti Microsoft; Android je ochranná známka společnosti Google LLC. Zen s nimi není nijak spojen ani jimi podporován.", "open": "Otevřít v Zen", "copy": "Zkopírovat kód", "copied": "Zkopírováno ✓", "getTitle": "Získejte Zen", "getLead": "Zdarma, bez registrace a bez reklam. Zabere to minutu.", "dlAndroid": "Stáhnout pro Android", "dlWindows": "Stáhnout pro Windows", "dlLinux": "Stáhnout pro Linux", "dlMac": "Stáhnout pro Mac", "dlIphone": "Stáhnout Zen pro iPhone", "instIphone": "Instalace na iPhone", "instMac": "Instalace na Mac", "otherSystem": "Jiný systém", "otherSystems": "Jiné systémy:", "moreInstall": "Všechny možnosti instalace a pomoc", "whatIsZen": "Co je Zen?", "recommended": "Doporučeno", "trouble": "Když se něco pokazí", "otherWays": "Jiné způsoby", "allSystems": "Všechny systémy", "nextTitle": "Zen je nainstalovaný. Co dál?", "nextText": "Přidejte prvního přítele a naučte se základy.", "nextBtn": "Jak Zen používat", "versionLine": "Nejnovější verze: {version} ({date})", "fpUnknown": "uvedený u každého vydání na GitHubu", "tocLabel": "Na této stránce", "honestTitle": "Upřímně:", "thanks_t": "Poděkování", "thanks_1": "Děkujeme **[Yggdrasilu|https://yggdrasil-network.github.io/]**, otevřené šifrované síti mesh, na které Zen běží, a **[Scarletu|https://usescarlet.com/]**, díky kterému je instalace Zen na iPhone jednoduchá."},
    "de": {"navLabel": "Hauptmenü", "navInstall": "Installieren", "navGuide": "Anleitung", "navFeatures": "Funktionen", "navSupport": "Hilfe", "navAbout": "Über Zen", "langLabel": "Sprache", "skip": "Zum Inhalt springen", "footPrivacy": "Datenschutzerklärung", "footTerms": "Nutzungsbedingungen", "footLicense": "Lizenz", "footCode": "Quellcode", "footNote": "Zen ist freie Software (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS und macOS sind Marken von Apple Inc.; Windows ist eine Marke von Microsoft; Android ist eine Marke von Google LLC. Zen ist weder mit ihnen verbunden noch von ihnen unterstützt.", "open": "In Zen öffnen", "copy": "Code kopieren", "copied": "Kopiert ✓", "getTitle": "Zen holen", "getLead": "Kostenlos, ohne Anmeldung, ohne Werbung. Es dauert eine Minute.", "dlAndroid": "Für Android herunterladen", "dlWindows": "Für Windows herunterladen", "dlLinux": "Für Linux herunterladen", "dlMac": "Für Mac herunterladen", "dlIphone": "Zen für iPhone herunterladen", "instIphone": "Auf dem iPhone installieren", "instMac": "Auf dem Mac installieren", "otherSystem": "Anderes System", "otherSystems": "Andere Systeme:", "moreInstall": "Alle Installationswege und Hilfe", "whatIsZen": "Was ist Zen?", "recommended": "Empfohlen", "trouble": "Wenn etwas schiefgeht", "otherWays": "Andere Wege", "allSystems": "Alle Systeme", "nextTitle": "Zen ist installiert. Und jetzt?", "nextText": "Füge deinen ersten Freund hinzu und lerne die Grundlagen.", "nextBtn": "So benutzt du Zen", "versionLine": "Neueste Version: {version} ({date})", "fpUnknown": "bei jeder Version auf GitHub angegeben", "tocLabel": "Auf dieser Seite", "honestTitle": "Ehrlich gesagt:", "thanks_t": "Danke", "thanks_1": "Danke an **[Yggdrasil|https://yggdrasil-network.github.io/]**, das offene, verschlüsselte Mesh-Netz, auf dem Zen läuft, und an **[Scarlet|https://usescarlet.com/]**, das die Installation von Zen auf dem iPhone einfach macht."},
    "es": {"navLabel": "Principal", "navInstall": "Instalar", "navGuide": "Guía", "navFeatures": "Funciones", "navSupport": "Ayuda", "navAbout": "Acerca de", "langLabel": "Idioma", "skip": "Saltar al contenido", "footPrivacy": "Política de privacidad", "footTerms": "Términos de uso", "footLicense": "Licencia", "footCode": "Código fuente", "footNote": "Zen es software libre (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS y macOS son marcas registradas de Apple Inc.; Windows es una marca registrada de Microsoft; Android es una marca registrada de Google LLC. Zen no está afiliado a ellas ni cuenta con su respaldo.", "open": "Abrir en Zen", "copy": "Copiar código", "copied": "Copiado ✓", "getTitle": "Consigue Zen", "getLead": "Gratis, sin registro, sin anuncios. Lleva un minuto.", "dlAndroid": "Descargar para Android", "dlWindows": "Descargar para Windows", "dlLinux": "Descargar para Linux", "dlMac": "Descargar para Mac", "dlIphone": "Descargar Zen para iPhone", "instIphone": "Instalar en iPhone", "instMac": "Instalar en Mac", "otherSystem": "Otro sistema", "otherSystems": "Otros sistemas:", "moreInstall": "Todas las formas de instalar y ayuda", "whatIsZen": "¿Qué es Zen?", "recommended": "Recomendado", "trouble": "Si algo sale mal", "otherWays": "Otras formas", "allSystems": "Todos los sistemas", "nextTitle": "Zen está instalado. ¿Y ahora?", "nextText": "Añade a tu primer amigo y aprende lo básico.", "nextBtn": "Cómo usar Zen", "versionLine": "Última versión: {version} ({date})", "fpUnknown": "indicado en cada versión en GitHub", "tocLabel": "En esta página", "honestTitle": "Con sinceridad:", "thanks_t": "Agradecimientos", "thanks_1": "Gracias a **[Yggdrasil|https://yggdrasil-network.github.io/]**, la red mesh abierta y cifrada sobre la que funciona Zen, y a **[Scarlet|https://usescarlet.com/]**, que hace sencillo instalar Zen en un iPhone."},
    "fr": {"navLabel": "Principal", "navInstall": "Installer", "navGuide": "Guide", "navFeatures": "Fonctions", "navSupport": "Aide", "navAbout": "À propos", "langLabel": "Langue", "skip": "Aller au contenu", "footPrivacy": "Politique de confidentialité", "footTerms": "Conditions d’utilisation", "footLicense": "Licence", "footCode": "Code source", "footNote": "Zen est un logiciel libre (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS et macOS sont des marques d’Apple Inc. ; Windows est une marque de Microsoft ; Android est une marque de Google LLC. Zen n’est ni affilié à ces sociétés ni approuvé par elles.", "open": "Ouvrir dans Zen", "copy": "Copier le code", "copied": "Copié ✓", "getTitle": "Obtenir Zen", "getLead": "Gratuit, sans inscription, sans pub. Ça prend une minute.", "dlAndroid": "Télécharger pour Android", "dlWindows": "Télécharger pour Windows", "dlLinux": "Télécharger pour Linux", "dlMac": "Télécharger pour Mac", "dlIphone": "Télécharger Zen pour iPhone", "instIphone": "Installer sur iPhone", "instMac": "Installer sur Mac", "otherSystem": "Autre système", "otherSystems": "Autres systèmes :", "moreInstall": "Toutes les façons d’installer et l’aide", "whatIsZen": "Qu’est-ce que Zen ?", "recommended": "Recommandé", "trouble": "En cas de problème", "otherWays": "Autres façons", "allSystems": "Tous les systèmes", "nextTitle": "Zen est installé. Et maintenant ?", "nextText": "Ajoutez votre premier ami et découvrez les bases.", "nextBtn": "Comment utiliser Zen", "versionLine": "Dernière version : {version} ({date})", "fpUnknown": "indiquée avec chaque version sur GitHub", "tocLabel": "Sur cette page", "honestTitle": "En toute franchise :", "thanks_t": "Remerciements", "thanks_1": "Merci à **[Yggdrasil|https://yggdrasil-network.github.io/]**, le réseau maillé ouvert et chiffré sur lequel Zen fonctionne, et à **[Scarlet|https://usescarlet.com/]**, qui rend l’installation de Zen sur iPhone simple."},
    "it": {"navLabel": "Principale", "navInstall": "Installa", "navGuide": "Guida", "navFeatures": "Funzioni", "navSupport": "Assistenza", "navAbout": "Info", "langLabel": "Lingua", "skip": "Vai al contenuto", "footPrivacy": "Informativa sulla privacy", "footTerms": "Termini d’uso", "footLicense": "Licenza", "footCode": "Codice sorgente", "footNote": "Zen è software libero (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS e macOS sono marchi di Apple Inc.; Windows è un marchio di Microsoft; Android è un marchio di Google LLC. Zen non è affiliato a loro né approvato da loro.", "open": "Apri in Zen", "copy": "Copia il codice", "copied": "Copiato ✓", "getTitle": "Scarica Zen", "getLead": "Gratis, senza registrazione, senza pubblicità. Basta un minuto.", "dlAndroid": "Scarica per Android", "dlWindows": "Scarica per Windows", "dlLinux": "Scarica per Linux", "dlMac": "Scarica per Mac", "dlIphone": "Scarica Zen per iPhone", "instIphone": "Installa su iPhone", "instMac": "Installa su Mac", "otherSystem": "Altro sistema", "otherSystems": "Altri sistemi:", "moreInstall": "Tutti i modi per installare e assistenza", "whatIsZen": "Che cos’è Zen?", "recommended": "Consigliato", "trouble": "Se qualcosa va storto", "otherWays": "Altri modi", "allSystems": "Tutti i sistemi", "nextTitle": "Zen è installato. E ora?", "nextText": "Aggiungi il tuo primo amico e scopri le basi.", "nextBtn": "Come usare Zen", "versionLine": "Ultima versione: {version} ({date})", "fpUnknown": "indicato a ogni versione su GitHub", "tocLabel": "In questa pagina", "honestTitle": "Con franchezza:", "thanks_t": "Ringraziamenti", "thanks_1": "Grazie a **[Yggdrasil|https://yggdrasil-network.github.io/]**, la rete mesh aperta e cifrata su cui funziona Zen, e a **[Scarlet|https://usescarlet.com/]**, che rende semplice installare Zen su iPhone."},
    "hu": {"navLabel": "Főmenü", "navInstall": "Telepítés", "navGuide": "Útmutató", "navFeatures": "Funkciók", "navSupport": "Segítség", "navAbout": "Névjegy", "langLabel": "Nyelv", "skip": "Ugrás a tartalomra", "footPrivacy": "Adatvédelmi irányelvek", "footTerms": "Felhasználási feltételek", "footLicense": "Licenc", "footCode": "Forráskód", "footNote": "A Zen szabad szoftver (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Az Apple, iPhone, iOS és macOS az Apple Inc. védjegyei; a Windows a Microsoft védjegye; az Android a Google LLC védjegye. A Zen nem áll kapcsolatban velük, és nem támogatják.", "open": "Megnyitás a Zenben", "copy": "Kód másolása", "copied": "Másolva ✓", "getTitle": "Szerezd meg a Zent", "getLead": "Ingyenes, regisztráció és reklám nélkül. Egy percet vesz igénybe.", "dlAndroid": "Letöltés Androidra", "dlWindows": "Letöltés Windowsra", "dlLinux": "Letöltés Linuxra", "dlMac": "Letöltés Macre", "dlIphone": "A Zen letöltése iPhone-ra", "instIphone": "Telepítés iPhone-ra", "instMac": "Telepítés Macre", "otherSystem": "Másik rendszer", "otherSystems": "Más rendszerek:", "moreInstall": "Minden telepítési mód és segítség", "whatIsZen": "Mi a Zen?", "recommended": "Ajánlott", "trouble": "Ha valami elromlik", "otherWays": "Más módok", "allSystems": "Minden rendszer", "nextTitle": "A Zen telepítve van. És most?", "nextText": "Add hozzá az első barátodat, és ismerd meg az alapokat.", "nextBtn": "A Zen használata", "versionLine": "Legújabb verzió: {version} ({date})", "fpUnknown": "minden kiadásnál megtalálható a GitHubon", "tocLabel": "Ezen az oldalon", "honestTitle": "Őszintén:", "thanks_t": "Köszönet", "thanks_1": "Köszönet a **[Yggdrasilnek|https://yggdrasil-network.github.io/]**, a nyílt, titkosított mesh hálózatnak, amelyen a Zen fut, és a **[Scarletnek|https://usescarlet.com/]**, amely egyszerűvé teszi a Zen telepítését iPhone-ra."},
    "nl": {"navLabel": "Hoofdmenu", "navInstall": "Installeren", "navGuide": "Handleiding", "navFeatures": "Functies", "navSupport": "Hulp", "navAbout": "Over", "langLabel": "Taal", "skip": "Naar de inhoud", "footPrivacy": "Privacybeleid", "footTerms": "Gebruiksvoorwaarden", "footLicense": "Licentie", "footCode": "Broncode", "footNote": "Zen is vrije software (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS en macOS zijn handelsmerken van Apple Inc.; Windows is een handelsmerk van Microsoft; Android is een handelsmerk van Google LLC. Zen is niet aan hen gelieerd en wordt niet door hen onderschreven.", "open": "Openen in Zen", "copy": "Code kopiëren", "copied": "Gekopieerd ✓", "getTitle": "Haal Zen", "getLead": "Gratis, zonder aanmelden, zonder advertenties. Het kost een minuut.", "dlAndroid": "Downloaden voor Android", "dlWindows": "Downloaden voor Windows", "dlLinux": "Downloaden voor Linux", "dlMac": "Downloaden voor Mac", "dlIphone": "Zen downloaden voor iPhone", "instIphone": "Installeren op iPhone", "instMac": "Installeren op Mac", "otherSystem": "Ander systeem", "otherSystems": "Andere systemen:", "moreInstall": "Alle installatiemogelijkheden en hulp", "whatIsZen": "Wat is Zen?", "recommended": "Aanbevolen", "trouble": "Als er iets misgaat", "otherWays": "Andere manieren", "allSystems": "Alle systemen", "nextTitle": "Zen is geïnstalleerd. En nu?", "nextText": "Voeg je eerste vriend toe en leer de basis.", "nextBtn": "Zen gebruiken", "versionLine": "Nieuwste versie: {version} ({date})", "fpUnknown": "bij elke release op GitHub vermeld", "tocLabel": "Op deze pagina", "honestTitle": "Eerlijk gezegd:", "thanks_t": "Dank", "thanks_1": "Dank aan **[Yggdrasil|https://yggdrasil-network.github.io/]**, het open, versleutelde meshnetwerk waarop Zen draait, en aan **[Scarlet|https://usescarlet.com/]**, dat het installeren van Zen op een iPhone eenvoudig maakt."},
    "pt": {"navLabel": "Principal", "navInstall": "Instalar", "navGuide": "Guia", "navFeatures": "Recursos", "navSupport": "Ajuda", "navAbout": "Sobre", "langLabel": "Idioma", "skip": "Ir para o conteúdo", "footPrivacy": "Política de privacidade", "footTerms": "Termos de uso", "footLicense": "Licença", "footCode": "Código-fonte", "footNote": "O Zen é software livre (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS e macOS são marcas da Apple Inc.; Windows é uma marca da Microsoft; Android é uma marca da Google LLC. O Zen não é afiliado a elas nem endossado por elas.", "open": "Abrir no Zen", "copy": "Copiar código", "copied": "Copiado ✓", "getTitle": "Baixe o Zen", "getLead": "Grátis, sem cadastro, sem anúncios. Leva um minuto.", "dlAndroid": "Baixar para Android", "dlWindows": "Baixar para Windows", "dlLinux": "Baixar para Linux", "dlMac": "Baixar para Mac", "dlIphone": "Baixar o Zen para iPhone", "instIphone": "Instalar no iPhone", "instMac": "Instalar no Mac", "otherSystem": "Outro sistema", "otherSystems": "Outros sistemas:", "moreInstall": "Todas as formas de instalar e ajuda", "whatIsZen": "O que é o Zen?", "recommended": "Recomendado", "trouble": "Se algo der errado", "otherWays": "Outras formas", "allSystems": "Todos os sistemas", "nextTitle": "O Zen está instalado. E agora?", "nextText": "Adicione seu primeiro amigo e aprenda o básico.", "nextBtn": "Como usar o Zen", "versionLine": "Versão mais recente: {version} ({date})", "fpUnknown": "mostrado em cada versão no GitHub", "tocLabel": "Nesta página", "honestTitle": "Com franqueza:", "thanks_t": "Agradecimentos", "thanks_1": "Obrigado ao **[Yggdrasil|https://yggdrasil-network.github.io/]**, a rede mesh aberta e criptografada em que o Zen funciona, e ao **[Scarlet|https://usescarlet.com/]**, que torna simples instalar o Zen no iPhone."},
    "ro": {"navLabel": "Principal", "navInstall": "Instalare", "navGuide": "Ghid", "navFeatures": "Funcții", "navSupport": "Ajutor", "navAbout": "Despre", "langLabel": "Limbă", "skip": "Sari la conținut", "footPrivacy": "Politica de confidențialitate", "footTerms": "Termeni de utilizare", "footLicense": "Licență", "footCode": "Cod sursă", "footNote": "Zen este software liber (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS și macOS sunt mărci ale Apple Inc.; Windows este o marcă a Microsoft; Android este o marcă a Google LLC. Zen nu este afiliat cu ele și nu este susținut de ele.", "open": "Deschide în Zen", "copy": "Copiază codul", "copied": "Copiat ✓", "getTitle": "Ia Zen", "getLead": "Gratuit, fără înregistrare, fără reclame. Durează un minut.", "dlAndroid": "Descarcă pentru Android", "dlWindows": "Descarcă pentru Windows", "dlLinux": "Descarcă pentru Linux", "dlMac": "Descarcă pentru Mac", "dlIphone": "Descarcă Zen pentru iPhone", "instIphone": "Instalează pe iPhone", "instMac": "Instalează pe Mac", "otherSystem": "Alt sistem", "otherSystems": "Alte sisteme:", "moreInstall": "Toate modurile de instalare și ajutor", "whatIsZen": "Ce este Zen?", "recommended": "Recomandat", "trouble": "Dacă ceva nu merge", "otherWays": "Alte moduri", "allSystems": "Toate sistemele", "nextTitle": "Zen este instalat. Și acum?", "nextText": "Adaugă primul prieten și învață bazele.", "nextBtn": "Cum folosești Zen", "versionLine": "Ultima versiune: {version} ({date})", "fpUnknown": "afișată la fiecare versiune pe GitHub", "tocLabel": "Pe această pagină", "honestTitle": "Sincer:", "thanks_t": "Mulțumiri", "thanks_1": "Mulțumim **[Yggdrasil|https://yggdrasil-network.github.io/]**, rețeaua mesh deschisă și criptată pe care rulează Zen, și **[Scarlet|https://usescarlet.com/]**, care face simplă instalarea Zen pe iPhone."},
    "vi": {"navLabel": "Chính", "navInstall": "Cài đặt", "navGuide": "Hướng dẫn", "navFeatures": "Tính năng", "navSupport": "Trợ giúp", "navAbout": "Giới thiệu", "langLabel": "Ngôn ngữ", "skip": "Chuyển đến nội dung", "footPrivacy": "Chính sách quyền riêng tư", "footTerms": "Điều khoản sử dụng", "footLicense": "Giấy phép", "footCode": "Mã nguồn", "footNote": "Zen là phần mềm tự do (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS và macOS là nhãn hiệu của Apple Inc.; Windows là nhãn hiệu của Microsoft; Android là nhãn hiệu của Google LLC. Zen không liên kết với hay được họ bảo trợ.", "open": "Mở trong Zen", "copy": "Sao chép mã", "copied": "Đã sao chép ✓", "getTitle": "Tải Zen", "getLead": "Miễn phí, không cần đăng ký, không quảng cáo. Chỉ mất một phút.", "dlAndroid": "Tải cho Android", "dlWindows": "Tải cho Windows", "dlLinux": "Tải cho Linux", "dlMac": "Tải cho Mac", "dlIphone": "Tải Zen cho iPhone", "instIphone": "Cài đặt trên iPhone", "instMac": "Cài đặt trên Mac", "otherSystem": "Hệ thống khác", "otherSystems": "Hệ thống khác:", "moreInstall": "Mọi cách cài đặt và trợ giúp", "whatIsZen": "Zen là gì?", "recommended": "Khuyên dùng", "trouble": "Khi có trục trặc", "otherWays": "Cách khác", "allSystems": "Tất cả hệ thống", "nextTitle": "Zen đã được cài. Giờ làm gì?", "nextText": "Thêm người bạn đầu tiên và tìm hiểu những điều cơ bản.", "nextBtn": "Cách dùng Zen", "versionLine": "Phiên bản mới nhất: {version} ({date})", "fpUnknown": "hiển thị cùng mỗi bản phát hành trên GitHub", "tocLabel": "Trên trang này", "honestTitle": "Nói thật:", "thanks_t": "Lời cảm ơn", "thanks_1": "Cảm ơn **[Yggdrasil|https://yggdrasil-network.github.io/]**, mạng lưới mesh mở và được mã hóa mà Zen chạy trên đó, và **[Scarlet|https://usescarlet.com/]**, giúp việc cài Zen trên iPhone trở nên đơn giản."},
    "tr": {"navLabel": "Ana menü", "navInstall": "Kur", "navGuide": "Rehber", "navFeatures": "Özellikler", "navSupport": "Yardım", "navAbout": "Hakkında", "langLabel": "Dil", "skip": "İçeriğe geç", "footPrivacy": "Gizlilik politikası", "footTerms": "Kullanım koşulları", "footLicense": "Lisans", "footCode": "Kaynak kod", "footNote": "Zen özgür bir yazılımdır (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS ve macOS, Apple Inc. şirketinin ticari markalarıdır; Windows, Microsoft’un ticari markasıdır; Android, Google LLC’nin ticari markasıdır. Zen bunlarla bağlantılı değildir ve onlar tarafından onaylanmamıştır.", "open": "Zen’de aç", "copy": "Kodu kopyala", "copied": "Kopyalandı ✓", "getTitle": "Zen’i edin", "getLead": "Ücretsiz, kayıtsız, reklamsız. Bir dakika sürer.", "dlAndroid": "Android için indir", "dlWindows": "Windows için indir", "dlLinux": "Linux için indir", "dlMac": "Mac için indir", "dlIphone": "Zen’i iPhone için indir", "instIphone": "iPhone’a kur", "instMac": "Mac’e kur", "otherSystem": "Başka sistem", "otherSystems": "Diğer sistemler:", "moreInstall": "Tüm kurulum yolları ve yardım", "whatIsZen": "Zen nedir?", "recommended": "Önerilen", "trouble": "Bir şey ters giderse", "otherWays": "Diğer yollar", "allSystems": "Tüm sistemler", "nextTitle": "Zen kuruldu. Şimdi ne yapmalı?", "nextText": "İlk arkadaşını ekle ve temelleri öğren.", "nextBtn": "Zen nasıl kullanılır", "versionLine": "Son sürüm: {version} ({date})", "fpUnknown": "GitHub’da her sürümle birlikte gösterilir", "tocLabel": "Bu sayfada", "honestTitle": "Açık konuşalım:", "thanks_t": "Teşekkürler", "thanks_1": "Zen’in üzerinde çalıştığı açık, şifreli mesh ağı **[Yggdrasil|https://yggdrasil-network.github.io/]**’e ve Zen’i iPhone’a kurmayı kolaylaştıran **[Scarlet|https://usescarlet.com/]**’e teşekkürler."},
    "ru": {"navLabel": "Главное меню", "navInstall": "Установка", "navGuide": "Руководство", "navFeatures": "Возможности", "navSupport": "Помощь", "navAbout": "О Zen", "langLabel": "Язык", "skip": "Перейти к содержимому", "footPrivacy": "Политика конфиденциальности", "footTerms": "Условия использования", "footLicense": "Лицензия", "footCode": "Исходный код", "footNote": "Zen — свободное программное обеспечение (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS и macOS — товарные знаки Apple Inc.; Windows — товарный знак Microsoft; Android — товарный знак Google LLC. Zen не связан с ними и не одобрен ими.", "open": "Открыть в Zen", "copy": "Скопировать код", "copied": "Скопировано ✓", "getTitle": "Получите Zen", "getLead": "Бесплатно, без регистрации и рекламы. Займёт минуту.", "dlAndroid": "Скачать для Android", "dlWindows": "Скачать для Windows", "dlLinux": "Скачать для Linux", "dlMac": "Скачать для Mac", "dlIphone": "Скачать Zen для iPhone", "instIphone": "Установить на iPhone", "instMac": "Установить на Mac", "otherSystem": "Другая система", "otherSystems": "Другие системы:", "moreInstall": "Все способы установки и помощь", "whatIsZen": "Что такое Zen?", "recommended": "Рекомендуем", "trouble": "Если что-то пошло не так", "otherWays": "Другие способы", "allSystems": "Все системы", "nextTitle": "Zen установлен. Что дальше?", "nextText": "Добавьте первого друга и узнайте основы.", "nextBtn": "Как пользоваться Zen", "versionLine": "Последняя версия: {version} ({date})", "fpUnknown": "указан у каждого выпуска на GitHub", "tocLabel": "На этой странице", "honestTitle": "Честно говоря:", "thanks_t": "Благодарности", "thanks_1": "Спасибо **[Yggdrasil|https://yggdrasil-network.github.io/]** — открытой зашифрованной ячеистой сети, на которой работает Zen, и **[Scarlet|https://usescarlet.com/]**, который делает установку Zen на iPhone простой."},
    "uk": {"navLabel": "Головне меню", "navInstall": "Встановлення", "navGuide": "Посібник", "navFeatures": "Можливості", "navSupport": "Допомога", "navAbout": "Про Zen", "langLabel": "Мова", "skip": "Перейти до вмісту", "footPrivacy": "Політика конфіденційності", "footTerms": "Умови використання", "footLicense": "Ліцензія", "footCode": "Вихідний код", "footNote": "Zen — вільне програмне забезпечення (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS і macOS — торгові марки Apple Inc.; Windows — торгова марка Microsoft; Android — торгова марка Google LLC. Zen не пов’язаний з ними і не схвалений ними.", "open": "Відкрити в Zen", "copy": "Скопіювати код", "copied": "Скопійовано ✓", "getTitle": "Отримайте Zen", "getLead": "Безкоштовно, без реєстрації й реклами. Займе хвилину.", "dlAndroid": "Завантажити для Android", "dlWindows": "Завантажити для Windows", "dlLinux": "Завантажити для Linux", "dlMac": "Завантажити для Mac", "dlIphone": "Завантажити Zen для iPhone", "instIphone": "Встановити на iPhone", "instMac": "Встановити на Mac", "otherSystem": "Інша система", "otherSystems": "Інші системи:", "moreInstall": "Усі способи встановлення й допомога", "whatIsZen": "Що таке Zen?", "recommended": "Рекомендуємо", "trouble": "Якщо щось пішло не так", "otherWays": "Інші способи", "allSystems": "Усі системи", "nextTitle": "Zen встановлено. Що далі?", "nextText": "Додайте першого друга й дізнайтеся основи.", "nextBtn": "Як користуватися Zen", "versionLine": "Остання версія: {version} ({date})", "fpUnknown": "вказано в кожному випуску на GitHub", "tocLabel": "На цій сторінці", "honestTitle": "Чесно кажучи:", "thanks_t": "Подяки", "thanks_1": "Дякуємо **[Yggdrasil|https://yggdrasil-network.github.io/]** — відкритій зашифрованій ячеїстій мережі, на якій працює Zen, і **[Scarlet|https://usescarlet.com/]**, який робить встановлення Zen на iPhone простим."},
    "ar": {"navLabel": "الرئيسية", "navInstall": "التثبيت", "navGuide": "الدليل", "navFeatures": "الميزات", "navSupport": "المساعدة", "navAbout": "حول", "langLabel": "اللغة", "skip": "انتقل إلى المحتوى", "footPrivacy": "سياسة الخصوصية", "footTerms": "شروط الاستخدام", "footLicense": "الترخيص", "footCode": "الشيفرة المصدرية", "footNote": "Zen برنامج حر (GPL-3.0). © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple وiPhone وiOS وmacOS علامات تجارية لشركة Apple Inc.؛ وWindows علامة تجارية لشركة Microsoft؛ وAndroid علامة تجارية لشركة Google LLC. لا ينتمي Zen إلى هذه الجهات ولا تؤيده.", "open": "افتح في Zen", "copy": "انسخ الرمز", "copied": "تم النسخ ✓", "getTitle": "احصل على Zen", "getLead": "مجاني، بلا تسجيل، بلا إعلانات. يستغرق دقيقة.", "dlAndroid": "نزّل لنظام Android", "dlWindows": "نزّل لنظام Windows", "dlLinux": "نزّل لنظام Linux", "dlMac": "نزّل لنظام Mac", "dlIphone": "نزّل Zen لـ iPhone", "instIphone": "ثبّت على iPhone", "instMac": "ثبّت على Mac", "otherSystem": "نظام آخر", "otherSystems": "أنظمة أخرى:", "moreInstall": "كل طرق التثبيت والمساعدة", "whatIsZen": "ما هو Zen؟", "recommended": "موصى به", "trouble": "إذا حدث خطأ ما", "otherWays": "طرق أخرى", "allSystems": "كل الأنظمة", "nextTitle": "تم تثبيت Zen. وماذا بعد؟", "nextText": "أضف أول صديق لك وتعرّف على الأساسيات.", "nextBtn": "كيف تستخدم Zen", "versionLine": "أحدث إصدار: {version} ({date})", "fpUnknown": "يظهر مع كل إصدار على GitHub", "tocLabel": "في هذه الصفحة", "honestTitle": "بصراحة:", "thanks_t": "شكر", "thanks_1": "شكرًا لـ **[Yggdrasil|https://yggdrasil-network.github.io/]**، الشبكة المتشابكة المفتوحة والمشفّرة التي يعمل عليها Zen، ولـ **[Scarlet|https://usescarlet.com/]** الذي يجعل تثبيت Zen على iPhone سهلًا."},
    "hi": {"navLabel": "मुख्य", "navInstall": "इंस्टॉल", "navGuide": "गाइड", "navFeatures": "सुविधाएँ", "navSupport": "सहायता", "navAbout": "परिचय", "langLabel": "भाषा", "skip": "सामग्री पर जाएँ", "footPrivacy": "गोपनीयता नीति", "footTerms": "उपयोग की शर्तें", "footLicense": "लाइसेंस", "footCode": "सोर्स कोड", "footNote": "Zen मुक्त सॉफ़्टवेयर है (GPL-3.0)। © 2026 Robert Ostrowski-Jagoda।", "trademark": "Apple, iPhone, iOS और macOS Apple Inc. के ट्रेडमार्क हैं; Windows Microsoft का ट्रेडमार्क है; Android Google LLC का ट्रेडमार्क है। Zen का इनसे कोई संबंध नहीं है और न ही इनका समर्थन प्राप्त है।", "open": "Zen में खोलें", "copy": "कोड कॉपी करें", "copied": "कॉपी हो गया ✓", "getTitle": "Zen पाएँ", "getLead": "मुफ़्त, बिना साइन-अप और बिना विज्ञापन के। बस एक मिनट लगता है।", "dlAndroid": "Android के लिए डाउनलोड करें", "dlWindows": "Windows के लिए डाउनलोड करें", "dlLinux": "Linux के लिए डाउनलोड करें", "dlMac": "Mac के लिए डाउनलोड करें", "dlIphone": "iPhone के लिए Zen डाउनलोड करें", "instIphone": "iPhone पर इंस्टॉल करें", "instMac": "Mac पर इंस्टॉल करें", "otherSystem": "अन्य सिस्टम", "otherSystems": "अन्य सिस्टम:", "moreInstall": "इंस्टॉल के सभी तरीक़े और सहायता", "whatIsZen": "Zen क्या है?", "recommended": "अनुशंसित", "trouble": "अगर कुछ गड़बड़ हो", "otherWays": "अन्य तरीक़े", "allSystems": "सभी सिस्टम", "nextTitle": "Zen इंस्टॉल हो गया। अब क्या?", "nextText": "अपना पहला दोस्त जोड़ें और बुनियादी बातें सीखें।", "nextBtn": "Zen कैसे इस्तेमाल करें", "versionLine": "नवीनतम संस्करण: {version} ({date})", "fpUnknown": "GitHub पर हर रिलीज़ के साथ दिखाया जाता है", "tocLabel": "इस पृष्ठ पर", "honestTitle": "सच कहें तो:", "thanks_t": "आभार", "thanks_1": "**[Yggdrasil|https://yggdrasil-network.github.io/]** का धन्यवाद, जो वह खुला, एन्क्रिप्टेड मेश नेटवर्क है जिस पर Zen चलता है, और **[Scarlet|https://usescarlet.com/]** का, जो iPhone पर Zen इंस्टॉल करना आसान बनाता है।"},
    "zh": {"navLabel": "主导航", "navInstall": "安装", "navGuide": "指南", "navFeatures": "功能", "navSupport": "帮助", "navAbout": "关于", "langLabel": "语言", "skip": "跳到正文", "footPrivacy": "隐私政策", "footTerms": "使用条款", "footLicense": "许可证", "footCode": "源代码", "footNote": "Zen 是自由软件（GPL-3.0）。© 2026 Robert Ostrowski-Jagoda。", "trademark": "Apple、iPhone、iOS 和 macOS 是 Apple Inc. 的商标；Windows 是 Microsoft 的商标；Android 是 Google LLC 的商标。Zen 与它们无关联，也未获其认可。", "open": "在 Zen 中打开", "copy": "复制代码", "copied": "已复制 ✓", "getTitle": "获取 Zen", "getLead": "免费，无需注册，没有广告。只要一分钟。", "dlAndroid": "下载 Android 版", "dlWindows": "下载 Windows 版", "dlLinux": "下载 Linux 版", "dlMac": "下载 Mac 版", "dlIphone": "下载 iPhone 版 Zen", "instIphone": "在 iPhone 上安装", "instMac": "在 Mac 上安装", "otherSystem": "其他系统", "otherSystems": "其他系统：", "moreInstall": "所有安装方式与帮助", "whatIsZen": "Zen 是什么？", "recommended": "推荐", "trouble": "出问题时", "otherWays": "其他方式", "allSystems": "所有系统", "nextTitle": "Zen 已安装。接下来呢？", "nextText": "添加你的第一位好友，了解基本用法。", "nextBtn": "如何使用 Zen", "versionLine": "最新版本：{version}（{date}）", "fpUnknown": "随每个版本发布在 GitHub 上", "tocLabel": "本页内容", "honestTitle": "坦率地说：", "thanks_t": "致谢", "thanks_1": "感谢 **[Yggdrasil|https://yggdrasil-network.github.io/]**，Zen 所运行的开放加密网状网络；也感谢 **[Scarlet|https://usescarlet.com/]**，它让在 iPhone 上安装 Zen 变得简单。"},
    "ja": {"navLabel": "メイン", "navInstall": "インストール", "navGuide": "ガイド", "navFeatures": "機能", "navSupport": "サポート", "navAbout": "概要", "langLabel": "言語", "skip": "本文へ移動", "footPrivacy": "プライバシーポリシー", "footTerms": "利用規約", "footLicense": "ライセンス", "footCode": "ソースコード", "footNote": "Zen はフリーソフトウェア（GPL-3.0）です。© 2026 Robert Ostrowski-Jagoda。", "trademark": "Apple、iPhone、iOS、macOS は Apple Inc. の商標です。Windows は Microsoft の商標です。Android は Google LLC の商標です。Zen はこれらの企業と提携しておらず、承認も受けていません。", "open": "Zen で開く", "copy": "コードをコピー", "copied": "コピーしました ✓", "getTitle": "Zen を入手", "getLead": "無料、登録不要、広告なし。1分で完了します。", "dlAndroid": "Android 版をダウンロード", "dlWindows": "Windows 版をダウンロード", "dlLinux": "Linux 版をダウンロード", "dlMac": "Mac 版をダウンロード", "dlIphone": "iPhone 版 Zen をダウンロード", "instIphone": "iPhone にインストール", "instMac": "Mac にインストール", "otherSystem": "他のシステム", "otherSystems": "その他のシステム：", "moreInstall": "すべてのインストール方法とヘルプ", "whatIsZen": "Zen とは？", "recommended": "おすすめ", "trouble": "うまくいかないとき", "otherWays": "その他の方法", "allSystems": "すべてのシステム", "nextTitle": "Zen をインストールしました。次は？", "nextText": "最初の友だちを追加して、基本を学びましょう。", "nextBtn": "Zen の使い方", "versionLine": "最新バージョン：{version}（{date}）", "fpUnknown": "GitHub の各リリースに記載されています", "tocLabel": "このページの内容", "honestTitle": "正直に言うと：", "thanks_t": "謝辞", "thanks_1": "Zen が動作する、オープンで暗号化されたメッシュネットワーク **[Yggdrasil|https://yggdrasil-network.github.io/]** と、iPhone への Zen のインストールを簡単にしてくれる **[Scarlet|https://usescarlet.com/]** に感謝します。"},
    "ko": {"navLabel": "주 메뉴", "navInstall": "설치", "navGuide": "가이드", "navFeatures": "기능", "navSupport": "도움말", "navAbout": "소개", "langLabel": "언어", "skip": "본문으로 건너뛰기", "footPrivacy": "개인정보 처리방침", "footTerms": "이용 약관", "footLicense": "라이선스", "footCode": "소스 코드", "footNote": "Zen은 자유 소프트웨어(GPL-3.0)입니다. © 2026 Robert Ostrowski-Jagoda.", "trademark": "Apple, iPhone, iOS, macOS는 Apple Inc.의 상표이고, Windows는 Microsoft의 상표이며, Android는 Google LLC의 상표입니다. Zen은 이들과 제휴하지 않았으며 이들의 보증을 받지 않았습니다.", "open": "Zen에서 열기", "copy": "코드 복사", "copied": "복사됨 ✓", "getTitle": "Zen 받기", "getLead": "무료, 가입 없음, 광고 없음. 1분이면 됩니다.", "dlAndroid": "Android용 다운로드", "dlWindows": "Windows용 다운로드", "dlLinux": "Linux용 다운로드", "dlMac": "Mac용 다운로드", "dlIphone": "iPhone용 Zen 다운로드", "instIphone": "iPhone에 설치", "instMac": "Mac에 설치", "otherSystem": "다른 시스템", "otherSystems": "다른 시스템:", "moreInstall": "모든 설치 방법과 도움말", "whatIsZen": "Zen이란?", "recommended": "권장", "trouble": "문제가 생겼을 때", "otherWays": "다른 방법", "allSystems": "모든 시스템", "nextTitle": "Zen을 설치했어요. 이제 무엇을 할까요?", "nextText": "첫 친구를 추가하고 기본을 익혀 보세요.", "nextBtn": "Zen 사용법", "versionLine": "최신 버전: {version} ({date})", "fpUnknown": "GitHub의 각 릴리스에 표시됩니다", "tocLabel": "이 페이지의 내용", "honestTitle": "솔직히 말하면:", "thanks_t": "감사의 말", "thanks_1": "Zen이 동작하는 열린 암호화 메시 네트워크 **[Yggdrasil|https://yggdrasil-network.github.io/]**, 그리고 iPhone에서 Zen 설치를 쉽게 해 주는 **[Scarlet|https://usescarlet.com/]**에 감사드립니다."}
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
    globe2: '<circle cx="12" cy="12" r="10"/><path d="M2 12h20"/>'
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
    ["about", "about/", "info", "navAbout"]
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
    }
    var foot = document.getElementById("zenFoot");
    if (foot) {
      foot.innerHTML = '<div class="foot-links">' +
        '<a href="' + URLS.privacy + '" rel="noopener" data-i="footPrivacy"></a>' +
        '<a href="' + URLS.terms + '" rel="noopener" data-i="footTerms"></a>' +
        '<a href="' + URLS.license + '" rel="noopener" data-i="footLicense"></a>' +
        '<a href="' + URLS.repo + '" rel="noopener" data-i="footCode"></a>' +
        '<a href="' + URLS.discord + '" rel="noopener">Discord</a></div>' +
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

  // All texts of the page; run again when the visitor picks another language.
  function apply() {
    var root = document.documentElement;
    root.lang = lang;
    root.dir = RTL[lang] ? "rtl" : "ltr";
    var title = lookup("title", lang);
    if (title) { document.title = title[0]; }
    var desc = lookup("desc", lang), meta = document.querySelector('meta[name="description"]');
    if (desc && meta) { meta.setAttribute("content", desc[0]); }
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
    var code = document.getElementById("langCode"), name = document.getElementById("langName");
    if (code) { code.textContent = lang.toUpperCase(); }
    if (name) { name.textContent = NAMES[lang] || lang; }
    var sel = document.getElementById("langSel");
    if (sel) { sel.value = lang; }
    showRelease();
    if (opts.onLang) { opts.onLang(lang); }
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
      lang = pickLanguage();
      apply();
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
