# Changelog

<!--
Before every release, fill in "What's new" under "## Unreleased". That's the
short note people see in the app next to "New version available", so write it
for them, not for developers: one to three lines about what they will notice,
English first, then Polish. Plain text, no links. The release script won't go
ahead without it. More in docs/RELEASES.md, section 3.5.
-->

## Unreleased

### Fixes and changes
- **A locked phone no longer carries strangers' traffic, which drained its battery**: a phone whose Zen received in the background kept two public peers, and a node with two peerings can become the shortest way between them on the mesh. One locked phone passed 1-6 KB/s of strangers' traffic in and out (34 MB in, 43 MB out) for seven hours and lost a third of its battery in a day; the transit guard never stepped in, as its limits (64 KB/s, 32 MB an hour) were made for data, not for the radio, which such a trickle keeps awake all the time. A node that only receives (the locked receiver, the other accounts' nodes in the service) now dials one public peer: a node with one peering is nobody's shortcut. When that peer goes down, two stand-ins are dialled at once, not after the five seconds a phone without network waits. The app on screen keeps four.
- **Mutation testing runs on three runners**: on one, the list of targets grew past its 45-minute limit and the job was cancelled (`tool/mutation.dart --shard PART/PARTS`).
- **Tests**: a phone that only receives, between two peers with no other way to each other, dials one and nothing passes through it from the start (with two it did); its lone peer going down with up to three dead candidates in line, back to one peer within seconds.
- **A save on Windows never leaves a file empty or half-written for a reader**: a small file (the update check, the language, the background kits, the sealed inbox) is written beside the old one and moved over it in one step. On Windows that move is refused while anyone has the file open, and after a quarter of a second of refusals the save wrote into the file in place, so on a busy machine a reader could find it empty (a test of two isolates saving at once caught it during the release of 1.15.9). The move is tried again for up to three seconds, at growing intervals; only a file held for longer is written in place, with a warning in the log.
- **Tests**: a move refused twelve times (the file holds the whole old save until the new one replaces it), a file held open on Windows for longer than the old quarter second, a file held for longer than the wait, a save into folders not made yet. Mutation target: the atomic save (2 of 5 changes caught; the three left are the flushes to the disk, which only a power cut shows, and a millisecond of the wait's random part).

## 1.15.9 — 08.11.2026

### What's new
- [en] Video calls show all their buttons and the picture from the start, your camera reaches the other side, and the picture is sharper.
- [en] In the car the Speaker button goes back to the car's speakers, and the floating window closes when the call ends.
- [en] Messages reach friends whose Zen runs in the background within minutes, pebble designs arrive whole, and your profile shows at once.
- [pl] Rozmowy wideo od początku mają wszystkie przyciski i obraz, Twoja kamera dociera do rozmówcy, a obraz jest ostrzejszy.
- [pl] W samochodzie przycisk Głośnik wraca na głośniki auta, a pływające okienko zamyka się po zakończeniu rozmowy.
- [pl] Wiadomości do znajomych z Zen w tle docierają w kilka minut, wygląd kamyczków dochodzi w całości, a profil pokazuje się od razu.

### Fixes and changes
- **Friends' statuses straight from the service when Zen opens**: the background service (Android, and an iPhone receiving in the background) keeps the newest status of each friend in a sealed file of its own (`presence.zbox`, next to the inbox and sealed for the same key), written again as soon as a friend's status comes. The app reads it the moment the friends are read after the unlock, before its node is up, and shows them at once. Before, the service handed the statuses over only when it stopped (as the app took the node back) and the app read them only after its core had started, which waits for the node, so statuses still took seconds. Statuses taken from the service are not answered and do not count as heard in this run: the start's pings still go to those friends.
- **The update's progress bar no longer jumps**: a second tap on "Aktualizuj" while the release's files were still being asked for (a version known from GitHub's release page alone, its API out of requests) started a second download into the same file, and the bar jumped between the two. "Aktualizuj" now waits from the first tap. The bar glides from one value to the next, never goes back, and stays full while the file is checked and installed (it ran across the bar from the start again before).
- **A call that is talking shows all its buttons, its time and the other side's video**: now and then (often the first call after Zen started) a call stayed on "Łączenie…" for good while both sides talked: the call screen had only "Rozłącz", the floating window said "Łączenie…" without the video, and the other side turning its camera on was taken for a new incoming call and never shown. The call became active only from one "connected" event of its media, which could be lost or undone by a write that read the call a moment before. The call now follows its media's own state: whenever the media is connected the call is active, checked at every change of the media and of the call, and an offer for a call whose media is connected is always a renegotiation (a camera, a shared screen).
- **The caller's camera turned on right after the answer reaches the other side**: the caller's call is active the moment the answer comes, a second or two before the media on the answering side connect; a camera turned on in that moment was taken there for a new incoming call and never applied, so one side saw the other and not the other way round. An offer for a call whose media already run it is a renegotiation now, and the same offer delivered twice by the mesh is applied once (its answer only goes again).
- **"Czeka u Ciebie — odbiorca offline" while the recipient's Zen receives in the background**: a phone that was off the network for a while and came back with its service running says nothing by itself, and the sender's next try was 10 minutes, half an hour or an hour away (in a simulation with no mailboxes, a message for a phone back after 5 or 20 minutes was still waiting an hour later). While Zen runs, each recipient with messages waiting on a long backoff now gets the oldest small one again every 2 minutes, one frame; its confirmation counts as hearing from it and everything else goes at once. Taken within 2 minutes of the recipient coming back, however long it was away.
- **The floating window closes with the call**: a call ended while it floated in Android's picture-in-picture left the small window up, with a corner of the app in it. It goes with the call now, and the person stays in the app they were in.
- **"Głośnik" in a car goes back to the car**: the call started in the car's speakers, "Głośnik" off and on again moved it to the phone's loudspeaker. "Głośnik" on is now the sound out loud, hands free: a connected headset (a car's Bluetooth, earphones) when there is one, the loudspeaker otherwise; off is the phone at the ear (the earpiece). A call whose sound went to the car shows "Głośnik" on. The loudspeaker with a headset connected is still in the list of outputs, which now sets exactly the one picked.
- **A sharper picture in video calls**: the camera sends 960 x 540 (up to 1280 x 720) at 24 frames, up to 1.8 Mbit/s, instead of 640 x 360 at 900 kbit/s, soft even when both sides had a fast connection. It is a ceiling: on a tight path WebRTC still lowers the resolution before the frames.
- **A kept or collected pebble's full design arrives while both are online**: the design (up to 64 KB) went in one message of some 70 mesh fragments, and one lost fragment lost it all, again at every try, a quarter of an hour apart: "Pełny wygląd jeszcze w drodze" stayed. It goes in parts of about three fragments now (`pbl_part`), the missing ones are asked for alone within seconds, and a keeper who just agreed asks again in a minute and whenever the author is heard from. An older Zen asks without saying it takes parts and gets the whole design as before.
- **The profile and the feed show at once when Zen opens**: on Android the ledger (your posts, the gallery, thanks, followers, the feed) was not read at all until the background service had let go of the node, which takes a few seconds after the unlock, so the profile stayed empty meanwhile. The service has not touched the ledger since it receives without the key, so the ledger is now read the moment Zen opens and shows at once; only its network part (greeting friends, syncing, telling the account's devices) waits for the service as before, and nothing of the ledger is sent before that.
- **Tests**: the upgrade fixture of 1.15.8.
- **Tests**: the service's statuses kept as they come and read before the node is up (not answered, the start still pings), a second "Aktualizuj" during the release's details, a late progress count, an inbox in folders not made yet, a call whose "connected" was lost, came late or was undone, and the other side's camera while the call still said "connecting", "Głośnik" with every set of outputs (a car, earphones, a phone alone, a tablet) and a call whose sound went to the car, a large pebble design over a mesh that loses fragments and an older Zen still getting it whole; a two-phone call matrix (108 combinations of a lost, late or undone "connected" on either side, the caller's camera before or after the answering side connected, an offer delivered twice, audio and video), two calls in a row, a snapshot read mid-call, a network blip, cameras switched many times; the floating window disarmed with every end of a call; routing on the phone step by step (a car, earphones, an iPhone, a computer, a failure) and all 32 sets of outputs; pebble designs of every size at 0–10% fragment loss with repeats (48 runs), forged, malformed and out-of-order parts, parts nobody asked for, a keeper whose door already runs; a message for a locked phone back after 1 minute to 3 hours taken within 2 minutes, and what the asking costs while it stays away; a phone with its service on and the app locked answering everything at once: pings from several friends again and again ("w tle"), a message, a group message, a reaction and a friend's invitation confirmed within seconds and in the app once after the unlock, a call that rings, five senders at once with 5% and 15% of datagrams lost and repeated, six hours locked, and the network gone for 3, 12 and 40 minutes. Mutation targets: the call audio route (14 of 15 changes caught; the one left reads WebRTC's device list, which needs a phone) and the pebble hosting (20 of 25; the five left are in the older door, redraw and blocked-keeper code, one of them pinned now), the ledger read before the service lets go (own posts on the profile, nothing sent, online once after it, also when it lets go while the ledger is still being read, and the safety start). Mutation target: the sealed inbox (19 of 20 changes caught; the one left, the folders, is pinned now).

## 1.15.8 — 07.11.2026

### What's new
- [en] Frame your photo and cover before they are saved, and use a GIF for either.
- [en] Messages and statuses come through faster while friends' Zen runs in the background, and a like opens your post.
- [en] Backups save to Downloads on Android, pebbles move to a new phone, and zooming the graph keeps people their size.
- [pl] Kadrujesz zdjęcie i tło przed zapisem, a na oba możesz dać GIF-a.
- [pl] Wiadomości i statusy docierają szybciej, gdy Zen znajomych działa w tle, a polubienie otwiera Twój post.
- [pl] Kopia zapisze się w Pobranych na Androidzie, kamyczki przechodzą na nowy telefon, a przybliżanie grafu nie powiększa ludzi.

### Fixes and changes
- **The iPhone install guide, so nothing is left to guess**: the install page says before the steps, as a warning, to connect LocalDevVPN (in its own app, **Connect**) before SideStore signs in, installs, renews or updates anything; step 3 says that the e-mail under "VPN & Device Management" is your own Apple Account, the developer, so you trust yourself; step 4 links to a new first answer under "If something goes wrong", opened by its link: error **-80045** when signing in to SideStore (Apple turns down SideStore's default anisette since October 2026), fixed once in SideStore's settings (On-Device Anisette off, the "SideStore (New)" server without auto rotation, Remote Server Sync, Reset adi.pb), with what to do on ADP, 502 or a -80045 that stays, and on iloader. Another new answer: SideStore or Zen doesn't open because the developer isn't trusted. In all 21 languages; the app's own iPhone steps (and docs/INSTALL.md, the guide) say the same in short.
- **The fix of -80045 in step 4 itself**: right now signing in to SideStore fails with -80045 almost every time, so the fix is no longer folded away under "If something goes wrong" but a warning box right under signing in, in step 4 ("Signing in ends with -80045? Right now it almost always does."); the answer under "If something goes wrong" points there.
- **"Najpierw: otwórz LocalDevVPN i stuknij Connect" in every step that needs it**: a warning at the very top of steps 4 (SideStore), 5 (installing Zen) and 7 (new versions), and in step 5, right after installing, **"Po instalacji zaufaj też Zen"**: Settings → General → VPN & Device Management → your e-mail → trust it, or Zen doesn't open. The app's own step 5 and docs/INSTALL.md say the same.
- **Framing the photo and the cover, and GIFs for both**: a picked picture opens on a framing screen first (a circle for the photo, the 3:1 band for the cover): move it and zoom with two fingers, the mouse wheel, the slider or + and −, then "Gotowe". The part in the frame is what is kept (a photo turned upright, at most 1024 px, without its metadata; a GIF cut and still playing); the cover was always the middle band, the photo the whole picture. Besides the gallery, the camera and a file there is "Wyszukaj GIF" (the GIF search of the chats, when it is on) and, on a phone, "GIF z klawiatury" (the keyboard's GIFs, or "Wklej obrazek" on an iPhone).
- **A tap on "… polubił(a) Twój post" opens that post in your profile**: the profile scrolls to it and marks it for a moment (`zen://post?p=…`). It opened the plain Tablica, where your own posts are not at all (they are in the profile), so it looked empty. A new post's or a mention's notification opens the Tablica with that post at the very top under "Z powiadomienia" until "Pokaż całą Tablicę", instead of scrolling to look for it.
- **Chats and friends by the latest conversation**: a new message (sent or received) moves its friend, and its group, to the top; friends never written to come after, online first.
- **A backup into Downloads on Android**: "Wybierz folder" (and saving) offers "Pobrane" first, written through the system's downloads without its folder chooser, which refuses to pick Downloads itself ("to protect your privacy, choose another folder"); "Inny folder…" opens the chooser as before.
- **Pebbles move to a new phone**: a copy of the account (a backup file, a move to a new device) takes the pebbles along with "Profil i galeria": the made, collected and kept ones with their full designs (not the old phone's own pebble door). A new phone had only the list in the profile and waited for the designs from the old phone, often gone by then.
- **The graph keeps the people's size when zoomed**: zooming in spreads friends apart; their dots, rings, lines and names stay the size they were on the screen (drawn again in small steps of the zoom) instead of growing like a picture.
- **"Ustaw krąg odzyskiwania" after it was set**: the reminder was worked out before the account had loaded (no circle known yet) and never again; it waits for the account now, as do "Zabezpiecz konto" and the backup reminder.
- **When a friend last had Zen open**: each of a friend's devices tells its own last opening (a computer in the tray where Zen was on the screen a week ago), and the last word counted, so a friend seen online today showed "7 dni temu". The newest one counts now and never goes back; Zen on the screen now is now.
- **"Czeka u Ciebie — odbiorca offline" right after sending**: a recipient heard from in the last 2 minutes is not offline, so a message younger than a minute shows "Wysyłanie…" while its confirmation is on the way.
- **Three tries at once, then the backoff**: a message goes right away, again after 1 s and 1 s more, then after 3 s, 10 s, 30 s, 2 min…; the relay ticks when a try is due instead of every 5 s. A small payload tried fewer than six times also goes again whenever its recipient says anything, once its last try is 4 seconds ago. A first try lost while the mesh found the way no longer waits half a minute or more.
- **"Czeka na doręczenie" piling up while everyone runs the service**: a phone whose Zen is in the background or locked (its service) dropped friends' posts, comments and likes pushed to it (`lg_push`) and mentions (`lg_mention`) without confirming them, so each one waited at its sender, and with the sender's mailboxes, for two weeks, tried again and again, and woke the phone each time. They are kept like messages now (sealed, confirmed once on the disk, taken by the app after unlock).
- **A message to a phone with Zen in the background looked late**: its service showed one message notification a minute; a message within that minute (from anyone) left the first one's notification as it was, so the new one looked as if it had not come. It updates the notification now, silently: the shade shows the newest, with one sound a minute as before.
- **Friends' statuses the moment Zen opens**: what the background service heard from friends is shown as soon as the app is unlocked and the friends are read, not once the app's own node is up (seconds later) and the whole inbox is opened.
- **"Zrzut grafu" above the navigation bar**: "Wyślij znajomemu" and "Zapisz" were under the system's navigation bar.
- **Nothing waits for a friend's unlinked device**: what was queued for a device its owner unlinked (a lost, stolen or replaced phone), and what this phone held for it as a mailbox, is dropped; it was retried and counted in "Czeka na doręczenie" and "Przechowujesz dla znajomych" for two weeks.
- **Failures of background work are logged, not left unhandled**: work started in the background with a result (a check that returns a count) threw an error of its own when it failed, in place of logging the failure; the reactions seen of a damaged file start afresh instead of failing the reaction notices (the persistence fuzz test caught it).
- **The framing screen reads a picture's size first**: a small file that claims a huge picture (from a file, the keyboard or the GIF search) is not decoded at all, and others are shown at most 2048 px a side.
- **Security review** (dependencies: `osv-scanner` on `pubspec.lock` and `go.mod`, `govulncheck` on the Go bridge: nothing that affects Zen; the one advisory, `golang.org/x/crypto/openpgp`, is in a package the bridge never uses). Fixed: an attachment's name that is a Windows device name (`CON.txt`, `NUL`, `COM1.png`) gets a `_` in front, so saving it on a computer writes a file, not to the device; `/private/` is in `.gitignore`, not only in the local excludes; the update service's comment said the maintainers' signature was not checked yet (it is).
- **Tests**: the upgrade fixture of 1.15.7.
- **Tests**: framing (the region, the photo, the cover, a GIF, the screen), a GIF cover from the GIF search, the own post in the profile, a friend's post from a notification, the order of chats and groups, Downloads on Android, pebbles in a copy, the graph's zoom and its snapshot sheet, the circle reminder, the last opening (a hidden one stays hidden), statuses before the node is up, posts and mentions kept by the service, the silent update of a notification, sending while the recipient is around, three quick tries and the quick retry. Mutation targets: the reaction notifier, the photo's sanitizer, the crop region.

## 1.15.7 — 05.11.2026

### What's new
- [en] "Waiting for your reply" can be hidden for one chat at a time, and a friend's card on the graph lets you write to them or remove them.
- [en] The setup keeps your choice of gates at once, and "Skip setup" is away from the Back and Next buttons.
- [pl] „Czekają na Twoją odpowiedź” ukryjesz dla jednej rozmowy, a z karty znajomego na grafie napiszesz do niego albo go usuniesz.
- [pl] Konfiguracja od razu zapamiętuje wybór bram, a „Pomiń konfigurację” jest z dala od „Wstecz” i „Dalej”.

### Fixes and changes
- **The setup's gate choice holds**: "Otwarte za darmo", "Za moją zgodą" or a price is saved for every tier at once and told to the friends in the background. It set one tier after another, each waiting until every friend was told; with friends slow to answer the gates stayed mixed (no choice shown as chosen) and the next tap seemed not to take.
- **"Pomiń konfigurację" at the top** of the setup, away from "Wstecz" and "Dalej" (it sat right under them).
- **The graph: a friend's card** has "Napisz" and "Profil" right under the name (they were at the very end of the card, under all it tells) and "Usuń znajomego" at its end, asked once more first.
- **"Czekają na Twoją odpowiedź" one by one**: a cross beside each waiting chat hides that one until a newer message comes from that friend; "Ukryj wszystkie" (with more than one) hides them all, as "Ukryj" did.
- **No error when the ledger stops mid-announce**: the ledger node's callbacks (friends, own address, session key, auto-download, bridges) answer empty once its provider is gone, instead of reading through a disposed ref; an announce scheduled just before a restart threw (CI's crash end-to-end test caught it).
- **Tests**: the upgrade fixture of 1.15.6.

## 1.15.6 — 05.11.2026

### What's new
- [en] A poll can close by itself after an hour, a day or a week, or when you end it; the leading answer shows at the top.
- [en] Sharing your location live ends with "I'm here", which marks where you arrived.
- [en] Send later works in groups too, all scheduled messages are in one place to change, and a poll shows who has not voted yet.
- [pl] Ankieta może zamknąć się sama po godzinie, dniu lub tygodniu albo gdy ją zakończysz; prowadząca odpowiedź jest na górze.
- [pl] Udostępnianie położenia na żywo kończysz przyciskiem „Jestem na miejscu”, który zaznacza, gdzie jesteś.
- [pl] „Wyślij później” działa też w grupach, wszystkie zaplanowane wiadomości zmienisz w jednym miejscu, a ankieta pokazuje, kto jeszcze nie głosował.

### Fixes and changes
- **Polls end**: the poll composer offers "Głosowanie trwa": without a time limit, 1 hour, 1 day or 1 week; its author can also "Zakończ ankietę" at any time. The ending travels as an edit of the poll's message (`msg_edit` with the poll and its `c`, ended at; the time limit is `d`), only its author's counts and only once; a Zen without this shows the poll's text with "Ankieta zakończona." under it. After the end no vote is cast, changed or taken back, also when one arrives from a Zen that does not know it ended. The card shows "Prowadzi: …", "Remis: …" or, ended, "Wynik: …" at the top, and the time limit or "Ankieta zakończona". At its time limit the card turns ended by itself.
- **"Jestem na miejscu"**: beside "Przestań udostępniać" on one's own live location: the sharing ends with where the phone is now (or the last position), marked as arrived (`ar`); the card says "Na miejscu", a Zen without this shows "📍 Jestem na miejscu: <map link>".
- **Wyślij później in groups**: holding a group's send button schedules the text for the group, with whom it mentions (the chat's own send then); a friend's and a group's waiting messages keep apart. Stored as before for friends (a group's is `group:<id>` with its mentions under `m`).
- **Zaplanowane wiadomości**: every waiting message in one place (from "Wszystkie zaplanowane" in the send-later sheet, and a card on the chats list saying how many wait): where it goes, when, "Zmień treść" (not for a text with mentions), "Zmień godzinę" and "Anuluj wysłanie".
- **Who has not voted**: a poll names the members without a vote yet ("Jeszcze nie głosowali: …"), once ended who did not ("Nie zagłosowali: …").
- **More pinned by mutation testing**: a save asked for before the stored state was read waits for it (the empty start never goes over the stored friends), removing a friend drops only their queued signals. The pebble QR test keeps the picture the scanner got when it cannot read it, and CI keeps it (`build/test_failures`) from a failing shard.
- **Tests keep up by themselves**: `test/fuzz_coverage_test.dart` fails while a frame type or a field the parser reads is not fuzzed (26 fields were not); the fuzzer sends polls and locations of every shape and aims frames at a friend's live location and poll, from a stranger and from another friend. Mutation testing covers 19 files (the chat extras logic too) (the 1.15.5 features, the parser, the social controller, the update notice and more; 10 changes per file per run), and `release.dart prepare` names the changed logic with a fast test of its own that it does not cover yet (docs/TESTING.md, sections 11.2 and 11.4). The start is tested on the data of 1.15.5 too (its upgrade fixture).

## 1.15.5 — 05.11.2026

### What's new
- [en] Each kind of notification has its own switch and its own level of what it shows, and a new version of Zen is always announced.
- [en] Polls in groups, live location for a while, notes to yourself, messages sent later and chats muted for a time; in groups only mentions notify by default.
- [en] Files are saved where you choose, links open in their own apps, after "Change code" the old code stops working, and you report a problem with one tap.
- [pl] Każdy rodzaj powiadomień ma własny włącznik i własny poziom treści, a o nowej wersji Zen powiadomienie przychodzi zawsze.
- [pl] Ankiety w grupach, położenie na żywo, notatki dla siebie, wysyłanie później i wyciszanie na czas; w grupach domyślnie powiadamiają tylko wzmianki.
- [pl] Pliki zapisujesz, gdzie chcesz, linki otwierają się w swoich aplikacjach, po „Zmień kod” stary kod nie działa, a problem zgłosisz jednym przyciskiem.

### Fixes and changes
- **Notifications per kind**: Ustawienia → Powiadomienia i dźwięki lists every kind with its switch and, under it, "Treść" (its own level of what a notification shows, or the general one; a conversation's own level still comes first). New kinds: messages from outside friends, introductions, meet-ups and events, the neighbours, dating, questions to the network, pebbles and the pyramid (they were never switchable). Always told: a friend's alarm, a request for help with a recovery, a date's safety check-ins, and a new version of Zen (its switch cannot be turned off). The locked phone applies the same levels. Far friends' posts are on by default, also for settings saved under the old default (once).
- **New version announced sooner**: while Zen is closed the background service looks every 15 minutes on its beat (it was 30 and 30, so up to an hour); the updates screen shows the whole what's new ("Pokaż całość" in the banner) and no raw errors or retry times ("Nie udało się teraz sprawdzić aktualizacji. Zen spróbuje ponownie sam."): those go to the diagnostics log.
- **"Czeka na doręczenie" drains**: mail picked up a second time (from another mailbox, or after a direct copy) is acknowledged to its sender again; the only acknowledgement went when the mail was first taken in, often while the sender was away, which kept the message waiting there for its two weeks. The diagnostics log gets a line with what waits and what is held, by kind and age.
- **Save As everywhere**: call recordings, chat attachments, the key copy, the graph picture, stickers and the diagnostics log open the system's own file browser at Downloads (Android, iPhone, computers); on phones they went to Zen's own hidden folder. An account backup asks for its folder when it is saved, unless one was chosen on its screen (it went to the default folder).
- **Links open in their app**: "Zen na Discordzie", "Zen na GitHubie" and every other link open in the app the link is for, or the default browser; Android's browser selector listed every app calling itself a browser and never Discord. A link Zen itself claims never comes back to Zen.
- **No "delete all accounts" button**: accounts are deleted one by one (the emergency wipe password still wipes everything).
- **The fundraiser in sight**: "Wesprzyj Zen" at the top of the settings and second in "O aplikacji".
- **macOS and Linux** are described as ready (they were "planned").
- **On by default**: friends of friends' films and Apple's Multipeer links, also for settings saved under the old defaults (once).
- **"Zmień kod" turns the old code away**: once the code was changed, a friend request without the current code's token (the old code, or none: an address learned elsewhere, Nearby, the Circle, an event, the neighbours, an introduction, "Dodaj" on a mini-profile) gets a refusal (`friend_reject`) and leaves nothing behind; so does an accept nobody here asked for, and an invitation to a group not known here from someone who is not a friend (`group_leave`). Someone who is not a friend cannot start a new conversation either (an introduction or a paid first message included); one begun before goes on. Friends, people invited from here and requests that already waited stay as they were. 1.15.4 kept those requests among the invitations without a notification. A refusal goes at most once a minute to one sender; the locked phone posts no notice for any of it.
- **Ankiety w grupach**: "Ankieta" in a group's attachment menu: a question and two to ten answers. A vote is a keycap reaction (1️⃣ … 🔟) on the poll's message, so it travels, syncs to the account's devices and changes like a reaction (one per person; a tap on one's own answer takes it back); a Zen without polls shows the poll as its numbered text and the votes as those reactions. A poll is not editable.
- **Udostępnij położenie**: in a conversation's or group's menu: the position once, or live for 15 minutes, an hour or 8 hours (the most). Live, a newer position is read every 1, 2 or 5 minutes (by the length) and sent only when the phone moved 25 m (or half its accuracy) or 10 minutes passed, as an edit of the same message, so a Zen without this feature shows the newest map link in its text; an older position never replaces a newer one. The sharing ends at its time or with "Przestań udostępniać", goes on after a restart, and only while Zen runs. The card shows when and how precise, and "Otwórz mapę". The same location service as the alarm (no Google Play services).
- **Notatki dla siebie**: below the conversations, a chat with oneself; the notes are the same on every device of the account (merged note by note, a deletion stays deleted).
- **Wyślij później**: holding the send button offers in an hour, this evening at 20:00, tomorrow at 8:00 or a chosen time; the message waits on this device and goes when Zen runs then (or as it comes back on screen), with one timer at the soonest message.
- **Muting for a time**: the conversation's "Powiadomienia" (its menu) mutes it for an hour, 8 hours, until morning, a week or until unmuted; a mention of you always comes through. The locked phone mutes the same.
- **In groups only mentions** (Ustawienia → Powiadomienia i dźwięki, and the setup; on by default): a group message notifies only when it mentions you; each group can choose "Każdej wiadomości" in its "Powiadomienia".
- **Czekają na Twoją odpowiedź**: on the chats list, friends whose last message waited two days or more (up to two weeks) for an answer (a setting, on by default).
- **The backup reminds itself**: with friends and no account backup on this device, or one a month old, a card on the chats list ("Później" waits a week). Never at the same time as the recovery circle's reminder.
- **Zgłoś problem**: in "O aplikacji" and the diagnostics: the version, the system, the relay backlog and the diagnostics log to a friend in Zen (as a file), to a new GitHub issue (the bug form filled in, with the end of the log) or to a file.
- **The setup once more** (revision 3): the notifications step names muting and has "W grupach tylko wzmianki".
- **Simpler settings, every option kept**: GitHub and Discord only in "O aplikacji" (they were there twice); "Diagnostyka" at the end of "Dlaczego nie działa?"; "Rozglądanie w tle" on "Sieć i usługa" under the Bluetooth switch; "Powiadomienia i praca w tle" opens the one permissions page (it was a second copy of three of its rows).
- **Leaks fixed**: call video renderers never used were never let go, the lock screen made a new overlay entry in every build, pebble pictures stayed after their images were made, the dating deck kept every animation curve, the pebble store and the circle backup's notifiers outlived their services.
- **ironwood**: its traffic counters and signature round-trip times were read and written by two actors at once (found by the race detector); they are atomic now (native/yggdrasil_bridge/third_party/ironwood/ZEN.md).
- **More tests**: the Go bridge under the race detector in every CI run; leak tracking of the widget tests on demand (`--dart-define=zen.leaks=true`); instrumented Kotlin tests on the CI emulator (what the file provider hands out, what other apps may start).
- **Tests**: the multi-step protocols on a network that loses, duplicates and reorders datagrams, on many seeds (`test/protocol_chaos_test.dart`); random frames into the parser and, from strangers, into the social controller (`test/signal_fuzz_test.dart`); a Go fuzz target for every parser of the bridge, fuzzed in every CI run; line coverage summed up in every CI run; mutation testing of the core files on every pull request (`tool/mutation.dart`); JVM unit tests of the Kotlin code without Android in it (docs/TESTING.md, section 11).
- **Mutation testing** stops a test past 2 GB of memory and counts the change as caught: a change that made a loop endless filled the CI machine's memory and the job died. The start is tested on the data of 1.15.4 too (its upgrade fixture).
- **The site**: what Zen is, how it works and the app itself come first, the reasons are folded to two lines each, and the part about the stores tells what Zen gains by being outside them, in every language.
- **CI**: the emulator job frees disk space first (toolsets it never uses): the previous release's build ran out of room beside an NDK and the emulator's image. A test fails when flutter_webrtc brings a WebRTC whose SHA-256 is not pinned; the 1.15.4 tag run failed on every desktop and iOS job for it (the WebRTC of flutter_webrtc 1.6.3 is pinned now, checked against the official release digests).

## 1.15.4 — 04.11.2026

### What's new
- [en] A call rings like a phone call, loudly and with vibration, shows as a call over the lock screen, and its sound goes to your car or headphones.
- [en] Chats show the date of their last activity, nine new pebble shapes, and you can pick which friends keep your pebble.
- [en] An account comes back with its password and two friends only, a pebble's code names nobody's address, and each account decides about its own notifications.
- [pl] Połączenie dzwoni jak telefon, głośno i z wibracją, pokazuje się jak rozmowa na zablokowanym ekranie, a dźwięk idzie do auta albo słuchawek.
- [pl] Czaty pokazują datę ostatniej aktywności, jest dziewięć nowych kształtów kamyczków i możesz sam wybrać, kto przechowuje Twój kamyczek.
- [pl] Konto odzyskasz tylko z hasłem i dwiema osobami, kod kamyczka nie zawiera niczyich adresów, a każde konto samo decyduje o swoich powiadomieniach.

### Fixes and changes
- **Ringing**: an incoming call rings with the phone's own ringtone, over and over at the ringer's volume, and a repeating vibration, as the ringer mode allows (ZenRinger.kt), also while Zen is locked; it played the notification's sound once, quietly, and the phone did not vibrate. The ringing notice itself is silent.
- **A call shows as a call**: on a locked phone the call card comes with a full-screen call notification (CallStyle, Android 12 on) that Android lets open over the lock screen; Android often refused to start the card from the background, which left a plain notification. While Zen is locked, the call card shows too ("Odbierz" opens Zen to unlock it).
- **Call sound in the car**: with the loudspeaker off, flutter_webrtc took the first of Bluetooth, wired headset and earpiece in the order Android lists them, often the earpiece while a car's Bluetooth was connected; a connected headset is now chosen by name, and at the start of a call it wins over the loudspeaker too.
- **Last activity in chats**: the time of the last message is worked out when shown (the date and time, or the time alone for today), not kept as words made when it came ("Teraz" stayed "Teraz").
- **Read ticks**: a read receipt marks every earlier message read too, not only the one it names.
- **"Czeka w skrzynkach u znajomych odbiorcy"**: a copy held only by this device, as the recipient's one mailbox, shows as waiting here.
- **Pebbles**: nine new natural shapes (triangular, square, hexagonal, teardrop, kidney, seed, tile, narrow flat, boulder), older designs unchanged; the editor's stone tab shows a stone; "Wybierz, kogo poprosić" lets the author ask friends of their own choice to keep a pebble.
- **Start**: the window is black from the first moment, like the splash and the first frame, with no white flash between them.
- **Graph**: the person and filter sheets stay above the system's navigation bar.
- **Invitations**: the buttons under an invitation are further apart.
- **Account recovery**: only with the account password and two people of the circle (2 to 6 trusted friends, at least two); the way without the password (four people, 7 days) is gone: new pieces hold no working passwordless half, and helpers never release one. The circle setup and the recovery screen warn that without the password there is no way back.
- **Pebble doors**: a pebble's QR code names pebble doors (the author's and up to three picked keepers'), never anyone's own address: a door is a node of its own (door_node.go) that takes only a request for a design and sends only the design, so the code gives nobody a way to send its keepers a friend request or a message. A keeper tells the author its door when it agrees; keepers on an older Zen cannot go into the code.
- **"Odblokuj Zen" with nothing behind it**: mail a mailbox hands over while Zen is locked carries one bit beside the sealed box, whether it deserves a notice (a message, a call, an invitation); receipts and statuses come in silently.
- **Notifications per account**: an additional account that receives in the background can post its notifications or not ("Powiadomienia z tego konta", in Konta i odzyskiwanie and in the setup); tapping one opens that account (one on the list of accounts; a hidden one says where it came from).
- **"Zmień kod"**: under Mój kod a new invitation code and QR; friends and the network address stay. The code is the address with a 5-character token after it (30 characters), and a friend request sent from it carries the token: once the code was changed, a request without the current token (the old code, an address learned from someone else's friend list, Nearby, the Circle) still waits among the invitations but posts no notification, in the app and on a locked phone. The invitation page takes both lengths.
- **Addresses that travelled too far**: a pebble's design never carries the signed keeper list (it names the keepers' own addresses) except to a keeper; a design asked for through a friend goes back through that friend, so the keeper and the finder never learn each other's address; a weekend plan passed on to friends of friends names its answerers by hashes bound to the plan, as events do; a gatekeeper answers "what lies further" only to whom sees their friend list, as their card does.
- **Nobody lists your peers**: Yggdrasil answered anyone's "list your peers" (and "tree", "self") query from the core, and a node's peers include friends linked over Wi-Fi or Bluetooth; the packet loop now reads below it and drops those queries unanswered, as the doors do.
- **Flood protection on phones**: a phone does at most 40 key exchanges a second for other nodes (200 on a computer), so a stranger asking for sessions over and over cannot keep it awake.
- **A message right after a friend's restart**: while frames wait for a friend's session, their key is asked for every second for the first five seconds (it doubled after three), so the first message to a friend whose Zen just restarted gets there as soon as their node is reachable, not up to two seconds later.
- **An invitation from a phone that just came on**: it stayed "Zaproszenie oczekuje na akceptację" for a minute. The mesh's session layer (ironwood) answers a session's first packet only once, and when that answer found no way back yet (a phone new on the mesh is found a second per hop of the tree later), the same packet sent again was ignored until a minute passed. Zen builds a copy of ironwood (native/yggdrasil_bridge/third_party/ironwood, ZEN.md) that sends a new first packet after a second, answered again; a test with the new node five hops away gets through in 7 to 8 s, never within 40 s before.
- **"Łączenie…" on a call that is on**: the media nearly always connect while the other side's answer is still being applied; the caller then put its stale copy of the call back, as "Łączenie…", and no second "connected" came to undo it. The same happened to whoever added a camera (the answer to the camera's offer): the controls went grey, the screen-share strip went, and the other side's camera offer was taken for a new call. The call is read again after the answer.
- **A missed call over the lock screen**: a call that rang out while the phone was locked leaves its notification even when the ringing drew Zen over the keyguard ("on screen", but nobody saw the chat).
- **Bluetooth links between phones**: the Android side handed each Bluetooth stream to the bridge at `getLoopbackAddress()`, which is `::1` on phones, while the bridge listens on 127.0.0.1 only: every stream was refused and no Bluetooth link came up. It connects to 127.0.0.1.
- **Offline links on for everyone**: "Znajomi w tej samej sieci Wi-Fi", Wi-Fi Direct and Bluetooth saved off by a version from when they were off by default are on after the update (once; turned off again, they stay off).
- **A voice call again**: with every camera off the call says "Rozmowa audio trwa" again (and ends as a voice call), on both sides; switching the camera reads the call as it is after the switch.
- **A call that ends while the speaker or the microphone is switched** stays ended: the switch put back the call as it was before it.
- **"strona github jest niedostępna"** only when the internet works: friends linked over Wi-Fi or Bluetooth (a hotspot without data) no longer count as the internet.
- **Wi-Fi Direct with Wi-Fi off** tries nothing (Android answered "busy" every 45 seconds) and puts its record up when Wi-Fi comes back.
- **Code cleanup**: two unused call widgets (the old call card and banner) and their seven texts in every language, and 29 functions nothing called (theme helpers, old provider builders, service methods no screen used) are gone.
- **Call diagnostics**: the media's connection states and the relay candidates (kind only, never an address) go to the diagnostics log; the relay candidate's LAN address is added when it becomes known, also after the loopback one went in.
- **Nearby**: a scan the "W pobliżu" screen stopped as it closed no longer tells the closed service about it (found by the monkey test).
- **Dependencies**: everything to its newest version except window_manager (0.6 is a rewrite on a new native API; 0.5 stays): file_picker 13 (static API, files read from their path), flutter_foreground_task 11, flutter_local_notifications 22, flutter_secure_storage 11 (Zen wrote with v10's ciphers from its first version, so nothing is lost), dbus 0.8, camera_windows 0.3 and the rest within their ranges; the Go bridge on yggdrasil-go 0.5.15, quic-go 0.65, klauspost/compress 1.20, x/net 0.62 and ironwood of 2026-10-23 (the patch carried over); Android on AGP 9.5, Gradle 9.8 and Kotlin 2.4; Flutter 3.47.9 (from 3.47.1), Go 1.27.3 (from 1.26.10) and govulncheck 1.9 in CI and in the CI image.
- **Group invitations name, joining gives addresses**: an invitation lists the members by name (as the inviter knows them, shown in the invitation's banner: "W grupie: Ala, Ola +3") and gives no address but the inviter's; the members' addresses come with the inviter's answer to "joined" (a `group_invite_ack` with `joined`, apart from the one that only says the invitation arrived), so someone who declines never learns them. Group mates exchange mailboxes once they have joined. An invitee on an older Zen gets the addresses from the inviter's member list after joining.
- **"Joined" said again until the members come**: the answer to "joined" was the only way to the members' addresses, and "joined" went once: one lost datagram, or an inviter offline at that moment, left the newcomer in a group of two. It goes again (at most every 30 s) whenever the inviter shows up, until their list of the members comes. The invitation's names leave out the invited person themself.
- **A shared screen keeps the call a video call** when the other side turns its camera off; so does our own camera when their offer comes while Zen is not on the screen (the call's kind was taken from their offer alone there).
- **The ring starts without holding up the call's screen**: the ringtone is prepared off the main thread.
- **Tests under the race detector**: the bridge's loggers are made with their call depth set (gologme/log set it on the first line written, and two links writing their first lines at once raced on it), and the test of a phone that stops carrying others' traffic lets what was already on its way arrive before it counts.
- **Tests open nothing on the computer**: links, maps and "show in folder" go to the computer's opener (explorer.exe, `open`, `xdg-open`) through one function that starts nothing inside `flutter test`; the monkey test tapped links and opened pages in the developer's browser.
- **CI**: the Podfile.lock workflow, after it commits new files to a pull request, also starts the emulator run (the runs GitHub makes from that bot push wait for a maintainer's approval, "workflows awaiting approval", and the held emulator run cancelled the one of the commit before); the emulator job stops the previous release's Gradle and Kotlin daemons once its APK is built (with the release on Gradle 8.14 and this commit on 9.8 there were two, and the runner ran out of memory in the next build).
- **"Zapytaj sieć" answers name nobody's address**: an answer to a question that came through a friend is signed with a hash of the answerer's address bound to the question, not the address: the asker (a friend's friend) cannot write to them; the answer comes back the way the question went, and the friend in the middle still checks it is the answerer's. An asker on an older Zen drops such answers until it updates.
- **Website**: the recovery circle is 2 to 6 friends with the password (no way without it), the way to someone's code starts from "Mój kod" in the top bar, and the home, features and guide pages tell about "Zmień kod" and each account's own notifications, in every language of the site.
- **Tests**: a walk through every tab and settings page on three screen sizes in both looks, and a seeded monkey that taps around the app (`ZEN_MONKEY_RUNS`, `ZEN_MONKEY_STEPS`, `ZEN_MONKEY_SEED`); it found the profile's information rows painting below their card's colour.

## 1.15.3 — 30.10.2026

### What's new
- [en] New versions arrive the moment they are released, invitation notices say who invites you and with what words, and you are told when someone accepts.
- [en] A few pebbles are round again, a pebble turns with any drag and has no line across it, and an open gate shows your friends without asking.
- [en] Friends' statuses are known as soon as Zen opens, and you can write to someone who invited you before you answer.
- [pl] Nowe wersje przychodzą od razu po wydaniu, powiadomienie o zaproszeniu mówi, kto zaprasza i z jakimi słowami, a o przyjęciu zaproszenia też się dowiesz.
- [pl] Kilka kamyczków znów jest okrągłych, kamyczek obraca się każdym ruchem palca i nie ma kreski przez środek, a otwarta brama pokazuje znajomych bez prośby.
- [pl] Statusy znajomych są znane od razu po otwarciu Zen, a do osoby, która Cię zaprasza, możesz napisać, zanim odpowiesz.

### Fixes and changes
- **Updates straight from the repository**: the newest version comes from GitHub's redirect from `releases/latest` (no request limit, at once when a release is published), its files from GitHub's API; the pages' `release.json` only when the API refuses and it already names that version (it was asked first and lagged minutes behind every release).
- **Invitation notices** name who invites and show their words, as the notification level allows, also while the app is locked (it said only "Odblokuj Zen, żeby zobaczyć szczegóły"); an accepted invitation says who accepted.
- **Gates**: "Pokazuj moje bramy dalej" is gone and gates are always passed on; letters through friends have no weekly limits and passed-on introductions no daily limit; a friend your gate is open to (free, no consent asked) sees your friend list without asking for it.
- **Pebbles**: seven shapes keep their rounder height (egg, tall, lopsided, potato, rock, chubby, plump) and flat shapes are not made thinner; a stone turns with a drag that starts in any direction (a scrolling page took the vertical ones); river stones have no vein drawn around them; a pebble names its author by the chosen name only, never the placeholder "Ja".
- **Website**: galleries drag with a mouse; the features list pebbles, dating, search and printable stickers, each feature has a fitting icon, and the invite steps point to the QR button in the top bar.
- **Statuses known at once**: a friend's status shows the moment Zen opens as what the last one is worth by now (an hour-old "w tle" is offline, "ostatnio w sieci …"), however long ago it was confirmed, instead of "status nieznany" until the first answers came; their answer puts it right. While Zen is locked or closed, the background service asks the friends who see your status how they are every 10 minutes and keeps their newest answers (and the pings of friends with Zen open) for the app, which shows them the moment it opens, aged as they would have been, instead of "status nieznany" until the first answers come.
- **Chat before accepting**: "Napisz, zanim odpowiesz" under an invitation opens a conversation with its sender; an invitation either way lets both write before it is answered (to ask who they are), whatever the settings for first messages, with no reply limits.
- **Keepers in a pebble's QR code**: under "Przechowujący w kodzie QR" the author picks up to three friends who keep the pebble (the first who agreed by default), with a word on why it matters; the sticker and "Pokaż kod" name them after the card (u8 count, 16 bytes of each address, not signed: only whom to ask, what they send must match the card). A finder asks them for the full design right after the author's devices, even knowing nobody; a Zen before 1.15.3 reads no code with keepers. The pebble's page reads such codes and hands them on to the app.
- **Pebbles kept for a friend**: a keeper whose design was still on its way asks the author's device for it again as soon as it hears from it (any message, any status), not at the next round up to hours later; the author's app may have been closed when it was asked.
- **"Mijani"**: one row per person and day (from the first pass to the last, with how many times), not a row for every pass.
- **Calls no longer crash the app**: the native media encryption of WebRTC reads a sender's track without asking whether there is one, so sealing the camera's sender of an audio call (no track) crashed the whole app at the start of a call; a sender is now sealed once it has a track (the camera turned on, a shared screen), and a call that ends while its senders are being sealed (a friend who is offline) closes its connection only after that. Besides, a fault in a call's relay ends the call, not the app, and a fatal error of the network library is written to a file the app puts in the diagnostics log at its next start (Android records such a crash only as "signal 11", with no stack).
- **Friends graph**: lines in a stronger colour and none thinner than 1.1, so friends of friends are visibly joined; invitation buttons further apart.
- **GitHub**: a code of conduct, and issue forms for bugs and ideas.

## 1.15.2 — 30.10.2026

### What's new
- [en] Your profile no longer looks reset after a restart, read messages always show their ticks, and pebble previews are sharp.
- [en] After painting a pebble Zen says plainly where it is kept and how friends keep it for you.
- [pl] Profil nie wygląda już na wyzerowany po ponownym uruchomieniu, odczytane wiadomości zawsze mają swoje fajki, a podglądy kamyczków są wyraźne.
- [pl] Po pomalowaniu kamyczka Zen jasno mówi, gdzie jest przechowywany i jak znajomi przechowają go za Ciebie.

### Fixes
- **Profile reset after a restart**: the own profile was read once at start, and when that happened before the app was unlocked (the store refuses then), the default profile stayed for the whole session and a change made then could be saved over the real one. It is read again once the store opens, and no change is saved on top of the default profile.
- **Ticks**: a read message always shows as read, and read receipts are recorded in the same queue as delivery changes, so neither writes over the other.
- **New versions are seen sooner**: the app looks every 15 minutes while it runs and the Android background service every 30 minutes while it is closed (was every hour and every 2 hours), on wakes that come anyway; the project's pages answer first and have no request limit.
- **Calls no longer crash the app**: a call's media keys were attached to every transceiver, and one the connection no longer had reached flutter_webrtc's native code as null (SIGSEGV in `FrameCryptorFactory.nativeCreateFrameCryptorForRtpSender`); after a few such crashes Samsung offered to clear the cache. Only senders and receivers the connection has are sealed now (found by calling a test phone and reading its crash record). The background service's engine no longer keeps flutter_webrtc, whose process-wide state it replaced and whose audio manager it stopped during a call.
- **Smoother video calls**: the camera captures 640 × 360 at 24 frames (up to 960 × 540 at 30) instead of 720p at 30, which came through the mesh late and jerky; it sends at most 900 kbit/s and keeps its frames before its sharpness when the path is tight.
- **The setup shows once more** after this update, filled in with the current settings, so everyone sees "Nie blokuj od razu po zamknięciu aplikacji" in its lock step (people who set Zen up before 1.15.0 never did).
- **Update checks** honour GitHub's own wait after a request limit even when it is longer than the next regular check.
- **Pebbles**: the pebble sticker's label says "Kamyk Zen" (in the app's language), the rail shows a stone instead of mountains, the profile's pebbles are drawn from their whole painting where the device keeps it, and "Kopiuj link" shares the whole signed card with its preview, so the pebble page shows the painted top.
- **Pebble previews** are drawn smoothed instead of as 16 × 16 squares.
- **Pebble keepers**: right after publishing, the pebble says that it lives only on your phone until a friend keeps it (unreachable while the phone is off), that Zen asks friends by itself, and where to see who agreed (Kamyczki → the pebble → "Opiekunowie").
- **Calls**: the diagnostics log now names where a native crash happened (the first libraries and functions of its stack, Android 12+), to find the crash a friend's phone had when answering calls. Sounds that stayed off were the phone's quiet modes (silent, vibrate, "Do not disturb" or Samsung's bedtime mode), as designed.

## 1.15.1 — 29.10.2026

### What's new
- [en] A friend's message lights up your locked screen, links in chats and posts open with a tap, and screenshots work everywhere.
- [en] Pebbles are flat stones now and have their own place in the menu; the first message of a chat gets its second tick.
- [pl] Wiadomość od znajomego rozświetla zablokowany ekran, linki w czatach i postach otwierają się po dotknięciu, a zrzuty ekranu działają wszędzie.
- [pl] Kamyczki to teraz płaskie kamienie i mają własne miejsce w menu; pierwsza wiadomość w czacie dostaje drugą fajkę.

### Fixes and changes
- **Notifications on a dark screen**: a friend's message or invitation that alerts lights the screen for a few seconds, as other messengers do, so it shows on the lock screen (with only what its privacy level allows there); not under "Do not disturb" and not for quiet notifications.
- **Show password**: an eye button shows or hides the password while setting the app password and when saving or restoring the key backup (unlocking had it already).
- **Links** in messages, comments and posts are underlined and open in the browser with a tap (copied where they cannot be opened).
- **Screenshots and screen recording are allowed everywhere**: the "Blokuj zrzuty i nagrywanie ekranu" setting is gone, and the protection older versions left on the window is lifted at start.
- **Delivery ticks**: a friend's receipt is no longer overwritten by the send's own later "sent", which left the first message of a chat with one tick.
- **Pebbles** are all flat stones, as people paint them, in the app and on the pebble page, and have their own place on the rail next to the Tablica and the films.
- **Update notice**: phones on 1.14 could miss it (a silent channel and GitHub's request limit on mobile data); both were fixed in 1.15.0, so from 1.15.0 on the notice comes through the website and shows in the status bar.
- CI: the emulator's start test runs as an installed app (flutter's test runner cannot open Zen's launcher alias), the emulator's start and the monkey run are bounded in time, the Linux Go bridge builds without a version-control stamp (CI's container), the promo film has no captions track and the promo page shows the poster of its language.

## 1.15.0 — 29.10.2026

### What's new
- [en] Pebbles: paint a virtual stone on every side, stick its QR code somewhere and let others collect it — it stays for everyone to find.
- [en] Search in chats, groups, the Tablica and settings, and print any QR code as a sticker in your own style and size.
- [en] Zen starts reliably after an update, removed friends stay removed, and invitations and messages after a restart arrive within seconds.
- [pl] Kamyczki: pomaluj wirtualny kamień z każdej strony, zostaw jego kod QR w ciekawym miejscu i daj innym go zebrać — zostaje dla każdego, kto go znajdzie.
- [pl] Wyszukiwanie w czatach, grupach, na Tablicy i w ustawieniach oraz naklejki z dowolnym kodem QR w Twoim stylu i rozmiarze.
- [pl] Zen niezawodnie startuje po aktualizacji, usunięci znajomi nie wracają, a zaproszenia i wiadomości po restarcie dochodzą w kilka sekund.

### Pebbles
- **Virtual painted pebbles**, like the painted stones people leave in places as finds. Design one in the 2.5D editor: turn the stone with a finger and paint straight onto the top, the bottom and every side (brush, spray, fill, eraser, mirror, stamps, curved text, patterns per face), on 31 natural stone shapes in 40 materials, with 148 stamps, 20 patterns, 26 ready designs, "Losuj" and 13 display fonts with Polish letters (open-licensed).
- **Its QR code** opens a page on the website with the stone, its name and author and "Collect in Zen"; scanned in Zen it opens straight in the app. Collecting does not take it away: everyone can collect it. The code carries only a short preview, so its dots stay big; the note, the date, the whole painting and the author's signature come with the stone and are checked by the app.
- **Kept by friends**: the author's phone asks six friends to keep the pebble (each one agrees), keepers stay keepers when they stop being the author's mailboxes, a keeper who declines or leaves is replaced, and everyone who collected it can pass it on too, so popular pebbles get easier to find.
- **Kamyczki on the profile** (created and collected), seen by friends only; "Pokaż kod" shows a pebble's code full screen so another phone can scan it.

### Reliability (field reports)
- **Zen no longer freezes on its logo.** The Go bridge's packet loop wrote replies from inside itself, so a friend sending at the wrong moment could stop the node for good, and the screen waited on it; replies now go through their own writer and every question the app asks the node is answered within a fraction of a second. Every start step has a time limit and a log line, a slow start shows which step it waits for (with "Czekaj", "Zapisz dziennik" and "Uruchom bez…") and a damaged settings file is set aside instead of stopping every start — a data wipe is never needed.
- **Files no longer break or lose data**: one writer per file across the app and the background service, every save written to its own temporary file, read back and checked before it replaces the old one, and the last good copies kept; a damaged file falls back to the previous copy, and a conversation is rebuilt from its pieces. A damaged account key no longer makes the ledger create a new account in its place.
- **Removed friends stay removed**: who is a friend is decided in one place, synced between your devices with the newer change winning; only a new invitation brings someone back.
- **Leaving with Back** no longer keeps the background service off the network for a minute.
- **Notifications** honour the chosen privacy level in the background too, never come for people who are not friends or for meeting updates, and name friends on older Zen versions.
- **Invitations** arrive within seconds (they could take hours when the first tries were lost), a restarted device is reachable within about a second, and the friend's real name shows in "połączenie z … jest gotowe".
- **Presence**: a locked friend's status shows within seconds of a start, a late frame can no longer make a friend in the background look online, and a friend's devices are recognised together nearby.
- **Updates** are found through the website first, which has no request limit (GitHub's API often refused phones on mobile data), the last check and its error show in Settings, and the update notice uses a visible channel.
- **Diagnostics log**: readable on Windows, in time order across the app and the background service, repeats counted, no quoted message text.
- **Optional**: "Nie blokuj od razu po zamknięciu aplikacji" (off by default) keeps Zen open for the lock delay after the app was closed, with the risk explained.

### Settings and look
- **Settings regrouped**: everything about notifications on one page, "Kontakt i widoczność", fewer one-setting pages; the settings search also finds settings inside the pages ("motyw", "zrzuty") and opens the page at them.
- **The friends graph grows over time**: play, pause, a day slider and speed, over any mode.
- **Titles use Baloo 2**, which has every Polish and other Latin letter, so no word mixes fonts any more.
- A group can be made with only yourself and members added later.


### Search
- **Search in a chat and in a group**: the magnifier in the title bar (in the menu on a narrow phone) or Ctrl+F on a computer. The words found are marked in the messages, "3 z 12" says which match is shown, the arrows (or Enter and Shift+Enter) go to older and newer ones and the chat scrolls there, also far back in a long history. Esc closes it.
- **Search on the chat list**: the field above the chats finds people and groups by name or by the nickname you gave, and messages of every conversation, grouped by conversation with the newest match first. A tap opens the chat at that message with its search on.
- **Search on the Tablica** (posts, their authors and the comments you can see) and **in the settings** (a setting by its name or the line under it).
- Case and Polish letters do not matter ("zolw" finds "żółw"), and every word typed has to be there. Search runs only on this device over what is already decrypted for the screen: nothing typed is sent anywhere or written down, and what was read for it is dropped when the field is cleared or the screen closed. Long histories are prepared in the background and searched in pieces, so the app stays smooth with tens of thousands of messages.

### Printable QR stickers
- **One sticker designer for every QR code worth printing**: "Mój kod", the door code (Neighbours), the install page and the collection open it with "Naklejka do druku". Texts above and below the code and a small line right under it (ready ones such as "Zeskanuj, żeby nas poznać" with the flat's or your name, or your own; they shrink to fit), a small "Zen" signature in the corner (on by default), six colour sets, a pattern in the margins (butterflies, leaves, confetti, stars, hearts, waves) and four code styles (classic, rounded, dots, round eyes), with Zen's logo in the middle wherever the code can carry it (highest error correction, under a tenth of the code, never on its patterns).
- Every style keeps the code's finder eyes, timing lines and alignment marks whole, the quiet zone free and the code dark on white; the tests read every style of every kind back module by module and decode it, and CI reads the printed pictures again with zbar.
- **Ready to print**: A4 (the default), A5, Letter, a 20 cm square, a 10 cm sticker or a phone wallpaper, upright or across. The artwork is a square in the middle of the page, with optional cutting lines, so it cuts out cleanly. The square can be printed 4, 5, 6, 8, 10, 12, 15 or 20 cm across (whatever the page holds) or as the largest the page takes; the designer shows the page at scale and how big one dot of the code comes out, warning when it gets too small for every camera. A small sticker can fill the page in rows (24 of 4 cm or 15 of 5 cm on A4), with gaps and cutting lines between them, in every file format. Saved as PDF (300 dpi), PNG, JPG or SVG to Downloads (the Files app on an iPhone); on Android also shared or printed through the system. The last design of each kind is remembered (in the encrypted store).
- **About → "Naklejka promująca Zen"**: a sticker with the link to the page about Zen or your own invitation.
- Codes that are secret or change stay on screen only: the key backup, copying the account, linking a device, event tickets, pyramid and housemate invitations, sharing the app over Wi-Fi.

### Website
- **A clearer website**: the strongest reasons first, a short FAQ, the story behind Zen on the About page and a page of promo materials (poster, a short film with CC0 music, a text to share and QR codes to print); every animation runs for everyone.
- **Screenshots and short films of the app** on the home, about and features pages: a gallery that scrolls sideways (swipe, arrow buttons or arrow keys), in Polish or English, light or dark as the visitor's device is set, with alt texts in all 21 languages. They are made from the app itself with a made-up demo account by `dart run tool/screenshots.dart`, and CI checks that none is missing.
- The lock screen's "I don't remember the password" and "Other account" use the app's font, not the phone's.

## 1.14.0 — 28.10.2026

### What's new
- [en] Settings → Notifications and sounds: choose which kinds of notifications you get, and hear soft sounds for messages, likes and posts.
- [en] Friends show up as online or in the background much sooner, and the graph opens on a presence view.
- [en] See how much room Zen takes (1 GB by default), and keep unsent messages, comments and posts after a restart.
- [pl] Ustawienia → Powiadomienia i dźwięki: wybierasz, o czym Zen powiadamia, i słyszysz ciche dźwięki wiadomości, polubień i postów.
- [pl] Znajomi dużo szybciej pokazują się jako online lub w tle, a graf otwiera się na widoku obecności.
- [pl] Widzisz, ile miejsca zajmuje Zen (domyślnie 1 GB), a niewysłane wiadomości, komentarze i posty zostają po ponownym uruchomieniu.

### Notifications and sounds
- **One page for notifications and sounds**: in-app sounds, a "notification sound" switch (off: notifications arrive silently; a ringing call and a friend's alarm are always heard) and one switch per kind: messages, group messages, calls, mentions, reactions, friends' posts, posts of further friends (off by default), invitations and updates. The rules also hold while Zen is locked.
- **In-app sounds where they were missing**: sending in a group, a message arriving in the open chat, a like or reaction, a published post and a new entry in the notification list. On Android nothing plays in silent, vibrate or "Do not disturb" mode, and the diagnostics log now says so.
- Every notice at the bottom of the screen can be swiped away to either side.

### Chats and drafts
- **The send button sits level with the letters** in chats and groups, for any font and text size (it was centred on the line, which looked too high, more so with tall phone fonts).
- **A chat at the newest message stays there** when the keyboard opens, a message arrives or is sent, someone is typing or a picture loads; your own message always brings you down. Scrolled up, what you are reading no longer moves as messages arrive. A new message no longer rebuilds the whole list.
- **Drafts survive a restart**: an unsent message in each chat and group, a comment under each post, and a new post's text, mentions and audience (closing the editor asks whether to keep the draft). Drafts are stored encrypted with the account and removed on send or wipe.

### Presence and network
- **Presence shows up sooner**: a new round of pings goes out as soon as the node reaches the network, a new friend is pinged at once, pings run every 2 minutes while Zen is open, and a friend counts as offline after 5 minutes (10 when they were in the background).
- **Changes are told at once, without more pings**: leaving Zen, coming back, closing it on a computer and getting the network back go straight to the friends who have Zen open (at most once per state every 30 seconds); a locked phone gets nothing more than before.
- **What friends showed is remembered over a restart**: a state confirmed within the last 30 minutes shows as it stands now (online from 3 minutes ago is online, from 8 minutes ago offline) until they say more.
- **"status nieznany"** (a grey dot with a question mark) for a friend whose last state is older than that, until they answer or the answers had time to come (with what they showed last, e.g. "status nieznany · ostatnio w sieci 2 godz. temu"), and for a friend whose Zen is too old to tell it. Friends no longer look offline just because Zen has not asked them yet.
- **"brak połączenia"** (a grey crossed-out cloud) for every friend while this device has no network ("Nie masz połączenia z siecią" in the chat), instead of showing them offline.
- **Public peers**: every built-in peer is on and shows what the device does with it (in use, connecting, not connecting, in reserve, paused by the transit guard), also in a list you edited before: peers you never switched are turned on, the ones you switched stay as you set them. A phone keeps the whole list in reserve and dials 4 peers, only 2 while Zen just receives in the background (fewer packets waking the radio). A peer whose link goes down is replaced at once: two stand-ins are dialled in parallel and the phone has its links back within seconds (at most about 15 seconds when the next candidates are dead too). With no network at all it tries again in waves that thin out to one every 15 minutes, and after a sleep it redials at the first wake instead of waiting for the network library's own long retry timers.
- **Wi-Fi Direct and Bluetooth links are on by default** and the first-start permissions ask for "Nearby devices"; both run only when there is a friend's device or another of your devices to link with.
- "Share mailboxes with group members" is on by default.

### Speed
- **Posts of friends of friends arrive within seconds**: a friend passes a post on about 3 seconds after getting it (it was 20–40 seconds, and up to 10 minutes for the next post), a waiting pass no longer holds up fetches, and an ask whose answer got lost is repeated after a minute (it was 10–20 minutes). Their notification comes within about 15 seconds; before, it only showed once a friend's post arrived later.
- Notifications of friends' posts and of likes and comments come after 5 seconds of quiet (at most 30 seconds in a busy thread); before, every new reaction pushed them back again.

### Graph and profile
- **The graph opens on a presence view**: online, in the background and offline at a glance; weak acquaintances have no status. The camera and filter buttons sit below the modes instead of over them.
- The follower count includes every friend, and the followers list shows them.

### Settings and storage
- **One "Data and storage" page**: how much room Zen takes, with a breakdown, the storage limit (1 GB by default, from 10 MB to 10 GB) and an optional separate limit for friends' photos and videos.
- **Zen keeps within its storage limit** by deleting only the oldest photos and videos of friends' posts; messages, chats, your own posts, backups and exports are never deleted on their own. When Zen goes over the limit, a warning on the page and one notice (at most once a day) offer to raise it.
- "Run the setup again" is the first item in Settings.

### Fixes
- The "new version" notification goes away once that version is installed, and a What's new note that could not be fetched is fetched again at the next check.
- **Updating does the right thing on each system**: on iPhone and iPad, numbered steps (turn on LocalDevVPN, tap **Update in SideStore**) hand the new version's `Zen-unsigned.ipa` to SideStore with its documented install link; **Download Zen 1.x.y** saves the file through Safari for **My Apps → +** in SideStore, and the iPhone install page is the fallback, instead of a dead end; links now open on iPhone at all. The updates card says beforehand what **Update** will do (Android installer, folder swap and restart, or the `.deb` saved for the package installer), and a file saved to Downloads comes with the right next step for Windows, Mac, the Linux tarball and the `.deb` (`sudo apt install …`). A release without this device's file points to its page.
- **iPhone installs with SideStore again**: the iPhone install page walks through it in seven illustrated steps (LocalDevVPN, iloader on a computer once, trust and Developer Mode, the first refresh, Zen's source, a daily Shortcuts automation so SideStore renews Zen by itself without a computer, and how updates arrive), with what to do when something goes wrong (7 days passed, the pairing file after an iOS update, no Developer Mode, the 3-app limit). **Add Zen source to SideStore** is also on the updates screen and in "How to install Zen" on an iPhone, with the address to copy for **Sources → +**. The 7-day reminder in Chats says to tap the counter in **My Apps** and points to the automation. Only `apps.json` is published as a source now.
- The thanks on the website, in the app and in the README go to Yggdrasil and SideStore.
- The offline mailboxes, the meeting hub and several sheets no longer hide their last items under the system bar.
- Holding the alarm and delete buttons no longer selects text.

### Development
- The tests run in parallel groups (`dart run tool/test.dart`), about twice as fast; CI splits them into four jobs and runs the tests that need Linux or the Go bridge on Linux.
- A release needs one approval: the APKs are built in parallel without keys and everything is signed in one approved job. A release of this repository stops when a signing key is missing.

## 1.13.1 — 28.10.2026

### What's new
- [en] Messages and notifications arrive again after Zen restarts or an account is restored.
- [en] Restoring a full backup brings back everything, including your app password; friends see you right away.
- [en] GIFs from the search work again, and tapping a Zen backup file opens it in Zen.
- [pl] Wiadomości i powiadomienia znów docierają po ponownym uruchomieniu Zen i po przywróceniu konta.
- [pl] Przywrócenie pełnej kopii przywraca wszystko, także hasło aplikacji, a znajomi od razu Cię widzą.
- [pl] GIF-y z wyszukiwarki znów działają, a dotknięcie pliku kopii otwiera go w Zen.

### Fixes
- After the app's engine was recreated (for example after restoring an account), the background service and the app could not start their connection for minutes ("a node with this identity already runs"), so messages and notifications didn't arrive. The newest owner now takes the connection over at once and the old one goes quiet.
- A friend request accepted while Zen was in the background could turn the friend back into a pending request when Zen opened, showing them as "Kontakt Zen" and stopping presence.
- After a restore, friends are greeted again within a minute and profiles (names, photos) are exchanged with the new device.
- Restoring a whole backup restores every setting and the app password; the setup appears only when the backup comes from an older version. "I already have an account" is offered on the password step, without the app flashing up first.
- GIFs from the search are sent as a copy small enough to travel inside the message; a device that keeps receiving without confirming no longer gets the same data again and again.
- Returning to an open conversation sends the read receipt (two ticks).
- Coming back to the app no longer crashes when a link reaches it.
- "Start over" on the lock screen needs the full 10-second hold also with animations turned off.
- The send buttons in chats and comments are centred and show their icon; snack bars with an action disappear after their time.
- The diagnostics log is saved to Downloads on Android.
- Tapping a Zen backup, key or update file opens it in Zen (Android, iPhone, Mac, Linux; "Open with" on Windows).
- The setup's gates step can set a price.

## 1.13.0 — 27.10.2026

### What's new
- [en] Messages reach you even when Zen is closed or locked: your trusted friends' phones keep them for you like mailboxes.
- [en] See whether a friend has Zen open, in the background or offline, and find your notifications in a list behind the bell.
- [en] Zen tells you about a new version within hours, with a short note like this one.
- [pl] Wiadomości docierają nawet przy zamkniętym lub zablokowanym Zen: telefony zaufanych znajomych przechowują je dla Ciebie jak skrzynki.
- [pl] Widzisz, czy znajomy ma Zen otwarty, w tle czy offline, a powiadomienia czekają na liście pod dzwonkiem.
- [pl] Zen mówi o nowej wersji w ciągu kilku godzin, z krótką notką taką jak ta.

### Messages and delivery
- **Phones are mailboxes again**, also while locked: a locked Android phone keeps mail for its trusted friends and hands it over once, with a confirmation, instead of again at every poll.
- **A locked phone hands its node to the background service reliably**; two nodes with the same identity can no longer run at once (that dropped messages to locked phones).
- **One notification per message**, also when it arrives both directly and from a mailbox; a new message no longer revives a notification you already dismissed.
- **Tapping a notification opens the right chat, group or post**, also when another screen is open.
- **Mailboxes are chosen by who is actually online**: each device says whether it is a computer, an Android phone or an iPhone, Zen counts how often it answers, changes at most one mailbox a day, and tells you when a mailbox has been quiet for days. A friend's devices count as one person, so a friend's dead old phone stops being your mailbox.
- Recovered history lands in time order; a file that will not come says "Plik niedostępny" and is no longer asked for forever.
- One tick means delivered, two mean read.

### Notifications and presence
- **Three privacy levels** for notifications (sender and start of the message, sender only, nothing), globally and per conversation; a locked phone shows at most the first 80 characters, and only known group members by name.
- **Notification list behind a bell** in the top bar (messages, invitations, reactions, posts, mentions), with undo.
- **Notifications about friends' new posts**, grouped, with a switch for everyone and a list of muted people.
- **@mentions** in group chats, posts and comments, with checks and limits.
- **Presence in three states**: open, in the background, offline, plus when a friend last opened Zen; weak acquaintances see none of it.
- **New versions are noticed within hours** (every hour in the app, every few hours in the background), with a system notification once per version and a short "what's new" note.

### Feed, people and the pyramid
- Posts are public by default; **you choose how far you look** (friends, friends of friends, third degree), posts from further away show who passed them on, and only post notices travel — the post itself is fetched from those who hold it.
- Pyramid: an empty head place is filled automatically after 7 days by the longer-serving member; a vote in a cell counts once members have met (or after 14 days).
- See which system a friend uses; jump to the latest message; the app comes back to the screen and place you left.

### Setup, look and backups
- **First-run setup** (lock, notifications, gates — open for free by default —, animations, permissions; on iPhone how Zen is woken), shown again after an update that changes something important.
- "Never" lock opens Zen without the password even after a restart (the key waits in the system's secure store); "Lock now" in the top bar locks it until the next unlock.
- Five themes with their own frames, an Animations setting, the splash in your theme, more contrast in light themes.
- Account backups go to Downloads by default, or to a folder you pick.

### Battery, network and stability
- Fewer wakes: background jobs share one wake and back off when nothing happens; Nearby looks less often when nobody is around; the parked service no longer wakes the phone every minute.
- Android: wake handling, Bluetooth and the integrity check run off the main thread (the cause of "app not responding"); every bridge lets go of the screen when it closes (the leak of one screen per start).
- Go: a memory limit on phones; a phone that starts carrying strangers' Yggdrasil traffic keeps a single link for a while (the cause of 2.4 GB in one night).
- Nearby: full scans while the screen is open, retries after failures, people on the same Wi-Fi.
- A technical log with numbers only (wakes, modes, memory, traffic) to diagnose problems, saved from Settings → Diagnostyka.

### iPhone
- A locked Zen keeps receiving: messages wait sealed until you unlock; background refresh, an hourly Shortcuts action and an optional silent keep-alive can wake it.
- Installation through **Scarlet** in four steps.

### Website
- A new website in 21 languages: a short invitation page, one install page per system with direct links to the latest files, a guide, features, support, and why Zen is not in the app stores.

## 1.12.1 — 24.10.2026
- Sending a GIF from the keyboard no longer crashes the app; GIFs show without a bubble or caption.
- Unlocking asks for the fingerprint or face at once when biometric unlock is on.

## 1.12.0 — 23.10.2026

### Installing and releasing
- **Install page** on GitHub Pages (`/install/`, English and Polish): recognises the visitor's system and shows only its steps: Android (APK, signing certificate fingerprint, one-tap Obtainium), iPhone (SideStore in 8 short steps with a one-tap "Add Zen source"), Windows, macOS and Linux.
- **SideStore / AltStore source** (`apps.json`), rebuilt from the latest published release by the Pages workflow (version, date, size, `Zen-unsigned.ipa`, permissions from `Info.plist`). The release run fails without the iPhone file.
- In the app: **Settings → Invite → Friend doesn't have Zen? → How to install Zen on another phone / computer**: a QR code to the install page and the steps per system.
- **`tool/release.dart`** (`check`, `prepare <version>`, `verify <folder>`): checks that the release workflow still produces every file the in-app updater expects, sets the version everywhere, moves these notes under the new version, commits and tags (it never pushes), and verifies downloaded release files against `SHA256SUMS` and its signature. CI runs `check` on every push; the release run fails when the tag differs from the version in the build.
- **Linux files run on Ubuntu 22.04, Debian 12, Mint 21 and newer** (glibc 2.35+): built on Ubuntu 22.04 with a check of every library, and the `.deb` is test-installed on Ubuntu 22.04–26.04 and Debian 12–13 in CI. The Flatpak moves to GNOME 51 and shows how to update instead of downloading.
- **Windows ZIPs carry the Visual C++ runtime**, checked file by file; the README explains Smart App Control and false antivirus alarms.
- **Safer release builds:** signing keys only in an approved, tag-only environment (the run stops if they leak into repository secrets); locked Dart packages, a pinned Go toolchain and `govulncheck`; pinned libwebrtc checksums; 16 KB page alignment of the Android libraries; reproducible Linux archives; the iPhone source is built from the release's own IPA and checksum.
- **Android: one APK per processor type** instead of one large universal APK: `Zen-arm64-v8a.apk` (most phones), `Zen-armeabi-v7a.apk` (older 32-bit phones) and `Zen-x86_64.apk` (Chromebooks, emulators). The self-update fetches the file for the phone's own type.
- **`CONTRIBUTING.md`** with a contributor licence grant and a pull request template.

### Documentation and GitHub
- **User guide** (`docs/guide`): one short page per area with diagrams and light and dark screenshots made from the app by `tool/ui_tour/docs_screens_test.dart`.
- **`docs/SECURITY_MODEL.md`** (threats, what is post-quantum, what stays classical and why, hardening, limits) and **`docs/DEPENDENCIES.md`** (what every library and platform API is for, and its licence).
- **README** rewritten: badges, a Post-quantum section, a feature list linking to the guide, platforms.
- **CI summaries:** format, analyzer, test counts, failed tests and Go tests on the run's summary page; the release run lists every file with its size and SHA-256.
- **Zen on Discord** (https://discord.gg/g4vHvpKV37), linked from the README and the GitHub issue page.

### License and legal texts
- **GPL-3.0-only** (`LICENSE`, the unmodified GNU text) with additional terms under GPL section 7 in `NOTICE` (author attribution in About, modified versions marked and renamed, no trademark rights; the donation link is not a licence condition; repository builds such as F-Droid may keep the name). `LICENSE` and `NOTICE` ship with the release files, the `.deb` and the Flatpak. `THIRD_PARTY_NOTICES.md` covers every component, including camera_windows, OpenH264, vo-aacenc, fonts, ZXing and KLIPY; the licences are also in the app (About → Licenses).
- **Consent at the first start:** terms, privacy policy and licence, each readable in the app; asked again when a document changes.
- **Terms of use:** a clear section at the top: Zen may be used only lawfully; using it to break the law is forbidden and is the user's sole responsibility.
- **No age gate:** the privacy policy and terms set no minimum age; only the pyramid asks for the birth year (below).

### Security and post-quantum
- **Hybrid ML-KEM-768 + X25519** for every signal between devices (no plaintext mode), offline mailbox mail, the locked phone's inbox, Bluetooth hellos, local link handshakes, neighbours' doors, dating boxes, food pickup and Table for six addresses, and private transfers.
- **Hybrid signatures (Ed25519 + ML-DSA-65)** on account and device records, posts, pyramid records, ballots, voting cards and releases. **Device identity** is post-quantum: device keys are pinned per address, and a key mismatch shows a warning in the chat.
- **Call recordings** of any length are encrypted into Zen's storage in pieces; the plain file is deleted only after that, "saved" appears only then, and a failed save offers *Retry*. Profile photos from another device or a backup go straight into encrypted storage.
- **Release checks:** a tag build stops at once while the app pins no release key or APK certificate, `SHA256SUMS.sig` must be signed by a pinned key and the APKs by the pinned certificate; commented-out pins do not count. The iOS and macOS WebRTC framework is checked against a pinned hash, and JitPack serves only the one library that needs it.
- **Windows:** Zen comes in its own `Zen` folder with a list of its files; an update replaces only that folder, never a folder Zen was merely unpacked into.
- **Lost or stolen devices:** once a device is cut off, friends stop sending it anything and their chat shows a warning; revocations are bounded and reach offline friends. A stranger can no longer probe whom you know through ledger hellos.
- **Linux video player** decodes only the formats Zen itself sends.
- **Calls:** frame encryption (AES-128-GCM, per-call hybrid keys rotated every 5 minutes and on every join or leave) inside DTLS-SRTP, and every packet sealed again in Zen's relay with a 256-bit ChaCha20-Poly1305 key of the two devices.
- **Cell votes** with one-time hybrid voting cards; only the card registration stays a ring signature. **Event tickets** are HMAC-based. **Dating lanterns** commit to a one-time hybrid key, and the match test is a sealed offer.
- **Yggdrasil:** no NodeInfo answers, no admin socket, only encrypted peer links (TLS 1.3 with X25519MLKEM768), strict peer address checks.
- **Memory and tampering:** secrets are wiped after use and link keys kept in locked memory; debuggers, Frida, hooking frameworks, injected libraries and re-signed copies are detected on every platform, and then transfers and the pyramid power key are blocked.
- Still classical: the Yggdrasil node key, the voting card registration, the pair secret of local links before devices first meet over the mesh, and the 128-bit AES key inside call frames (see `docs/SECURITY_MODEL.md`).
- **Private temporary media:** plain media files that must exist for a moment go to a folder only you can open (0700, files 0600, random names) in the app's own cache instead of a shared `/tmp`, and are cleared at start and exit.
- **Comments can no longer delete other files:** Zen remembers which author's entry brought each file, so deleting a comment removes only its own pictures, and storage limits touch only post and comment pictures.
- **Huge pictures are refused before decoding** (128 MiB of memory or 40 megapixels, read from the header), and big ones decode off the main thread.
- **Lock screen:** "I don't remember the password" (erasing this device) needs a **10-second hold**; failed password attempts are **throttled** (free for 5, then the wait doubles from 30 s up to 30 min, kept across restarts).
- **Official copy:** the app **checks itself** (Official copy / red warning at start and in About; "Cannot check" while no fingerprint is pinned) and can compare an installed or received file with the release's **`SHA256SUMS`** on demand; a short build code helps compare two phones.
- **Privacy defaults:** Nearby (Bluetooth) visibility is off until you turn it on, and the profile status line is visible to friends only.
- **Storage limits are enforced** for other people's media (friends 12 months, 2 GB per friend, 1 GB cache, oldest first; own data never), and a conversation can be auto-cleaned by age or size.

### Accounts and recovery
- **Several accounts on one device**, each a separate person (keys, mesh address, password, data, notifications). Accounts kept off the list open with their ID and password; decoy folders and hashed keystore names hide how many there are. Switching from the avatar menu; removing one account or all of them.
- **Receive in the background** per account (Android, and computers in the tray), with a battery and hiding warning; notifications of extra accounts are generic.
- **Copy with friends:** each person of the recovery circle keeps an encrypted copy (up to 10 MB) of the profile, friends, groups, levels, settings, pyramid, wallet, household, dating profile and, by default, the text of conversations. After recovery Zen fetches and restores it by itself.
- A recovered account gets its **pyramid place, wallet and power key** back.
- **Recovery circle you choose:** 4 to 6 friends (casual friends not suggested), a list of who holds the keys with confirmations and a printable list with their codes; a new phone shows a code and QR instead of an address, and helpers get a notification with **Help** already filled in.
- **First start:** a step for your name (friends no longer see "Me"), a key copy first and a reminder to set up the circle once you have 4 friends; optional permissions folded away.
- **Clear names:** *App password*, *Account password*, *Emergency wipe password*, the alarm's *Duress PIN*; *Key copy*, *Full account copy*, *Copy with friends*, *Add a second device or move the account*; *Delete this account from this device* warns when the account has no copy.
- **iPhone:** a reminder 2 days before the 7-day signature expires.

### Chats and delivery
- **Full chats, also in groups and pyramid cell chats:** photos, videos, files, voice notes and GIFs; **reactions, replies, editing (24 h), forwarding and delete for everyone**. Group files up to 64 KB travel in the message; larger ones, up to 24 MB, are sealed once and fetched from the sender or other members. A photo on the group **Board**.
- **GIF files** from the gallery or disk stay animated (metadata removed, up to 8 MB); Android keyboard GIFs arrive animated; a GIF that won't play can go as a file.
- **Drag and drop and paste** (Ctrl/⌘+V) of photos, GIFs, videos and files into chats, the post editor and the gallery on Windows, macOS and Linux; on iPhone, **Paste image from clipboard** for keyboard GIFs.
- **Outbox:** every reliable message is written to disk before the first attempt and retried on a battery-friendly schedule for up to 14 days, also after a restart; mailbox copies after 4 seconds; large payloads split across mailboxes; new posts and comments reach offline friends through their mailboxes. On a locked Android phone a sealed copy of the queue keeps sending.
- **Delivery icons** under every message (sending, waiting on your phone, waiting in the recipient's mailboxes, sent, delivered, read, failed) with details and **Retry**; groups show *Delivered d of n*.
- **GIF search switch** (Settings → Messages and calls → GIFs): off, Zen sends nothing to KLIPY and hides the GIF button.
- **Mailboxes prefer devices that stay online** (computers in the tray, Android) and replace ones silent for 3 days; the outbox is capped at 32 MB.
- **Honest iPhone delivery:** labels, a one-time card and *Why isn't it working?* say that an iPhone sends and receives only while Zen is open. **Copy invitation** copies a message with your link; the invitation code no longer vanishes from the clipboard.
- **GIFs always play:** event, food, flat, avatar and cover pictures keep a GIF animated (made smaller when needed, never flattened to one frame); on iPhone, **Paste image** in the text menu takes a keyboard GIF in chats, comments and posts.
- **Mini-profiles** (signed name and photo) travel with likes, comments and messages to people who are not friends; **messages to non-friends** are allowed in ordinary chats (text only, 3 messages until they answer; chosen in Settings).
- **Aggregated notifications** ("Cela and 3 others liked your post") are also system notifications, one per post, with the title hidden by "notifications without content".
- **Group board** is the group's own space of posts; **video plays while it downloads** (media sealed in independent 256 KB segments).
- **Call recording on every system:** iPhone, iPad and Mac (`.m4a`, the call and the microphone through flutter_webrtc's audio hooks) and Linux (`.wav`, only Zen's own sound and the microphone through PulseAudio / PipeWire) join Android and Windows.

### Feed and videos
- A new **Videos** section: a vertical full-screen player, recording and trimming, compression to about 720p and 20 MB on the device, an order worked out on the phone, block-by-block download from friends and mailboxes, views only for the author, videos from friends of friends (opt-in).
- **Cameras on computers:** Windows (camera_windows, Media Foundation compression and covers), macOS (own capture and export) and Linux (GStreamer, with OpenH264 and vo-aacenc built into Zen). QR codes can be scanned with a computer's camera too.
- Feed filters **All · Friends · Close friends · Pyramid · Country**, always shown.
- **Pictures in comments:** up to 4 photos or GIFs in a comment under posts, videos and pyramid posts, from the camera, gallery, files, GIF search, keyboard or drag and drop; they sync to your other devices like post photos. Your own comment can now be deleted, with its pictures.

### Pyramid and wallet
- **Birth year at entry:** the pyramid asks for the birth year (minors are admitted; age is never a condition) and shows the age in the member's pyramid profile, confirmed by the signature of the person who admitted them. Dating and the wallet never ask about age.
- **Your devices share the pyramid state** (entry data, own records and votes), so one member key never votes twice.
- **Private transfers:** orders go sealed to the treasurers only; a transfer counts when a majority of them sign it; signed statements, a dispute button and a court complaint for a wrong balance. A **daily transfer limit** (5 to 200, 30 by default).
- **Issuance limit as a hard rule:** lowering applies at once (hold to confirm), raising is announced and applies after 30 days unless cancelled; the same for the transfer limit.
- **Court and appeals:** verdicts visible on the person's profile; appeals one level above whoever decided, the time doubling per level.
- **Promotion one level at a time**, at most every 7 days. **Top immunity:** removing or banning a member of the top cell needs 2 of 3 of the top and a majority of level 2.
- **Posts to the whole pyramid** by the head, who can delegate them; the **Country** chip for everyone, with countries from the profile or the phone's region (several at once).
- National sections without a size threshold, ordered like the pyramid; referral joining, voting after 14 days or a confirmed acquaintance; advisory referenda; rule changes by the top (2 of 3) within hard limits; a group chat for every cell.
- **Places over time:** an animated history of the tree. The wallet has its own rail icon and opens from your profile too.

### Graph, introductions and gates
- **Gates with three prices** (close friends, friends, further away; each may be free) and an **Open for free** list; routes through any number of gates, the cheapest first.
- Graph **timeline**, **trust map**, **who's worth meeting**, **bridges and lonely islands**, **long ago**, private names for groups of friends, the answer path of *Ask the network*, a snapshot without personal data, **full screen**; **add friends of friends** without a code.

### Meeting people and Nearby
- **Nearby** visible by default; a cheap look around in the background every 5 minutes (adjustable in **Settings → App → Looking around in the background**, Android), also with Zen locked. **Nearby on computers** with Bluetooth LE (Windows and Linux broadcast and look; a Mac only looks). The Nearby icon shows only where it works.
- **Met?** from *Passed by* for up to 7 days; **New at the table** after a dinner.
- **Met in person** is signed by **both sides**: after a scanned or shown QR, Nearby or an event, each phone asks "Did we meet in person?" and only "Yes" signs.
- Dinner circles with invitations, *Leave circle*, *Who's coming* with diets, a chat per dinner, *Who owes whom*, *How was it?* and reminders even with Zen locked; **Cooking today, join me**; food sharing (eat in or take away; free, swap, points or money) with the pickup address sealed for the accepted person; **Table for six through a go-between**, who never sees the address; event guest lists without addresses for far circles.

### Neighbours
- A knock on the door waits up to 10 minutes for a resident to **accept** ("Let in" / "Refuse") before anything is answered; the door takes only knock frames and answers no Yggdrasil queries.
- A knock rings every household phone, also on a locked Android phone; *Leave* changes the household key; *What a knocker sees*.
- **Move the flat to this device:** when the phone that runs the flat is lost or replaced, another device of the account takes it over with a new door key; housemates and neighbours follow, the old door is refused from then on, and Zen offers a new sticker. Offered also right after cutting off a lost device.
- A **one-time housemate code** (10 minutes, confirmed on the phone that showed it), a **24-hour code** for inviting people nearby, messages signed with **your name in the flat**, and removing a housemate of a two-person flat only with their consent or after 7 days.

### Dating
- **Private lanterns:** a lantern carries only a one-off key (no age, name, gender or preferences) and goes 2 steps; a phone that sees one runs a sealed match test and asks for the profile only on a fit.
- Up to 3 steps and through open gates, *How far you want to see*, a distance nobody can fake, hiding *from them and their circle*, fixed-size answers, matchmaking, opinions only from people who know the person, free interests, meeting without romantic intent, filters, no extra password.

### Offline links and the locked phone
- Direct links over the **same Wi-Fi** (on by default), **Wi-Fi Direct** (Android, Windows), **Bluetooth** (all platforms) and **Apple Multipeer** (iPhone, Mac); strangers see only random-looking adverts.
- The Android background service runs the same code as the app and wakes on signals instead of polling. It works **without the master key**: a separate background key and small kits let it send the alarm, show you nearby, take knocks and send queued messages while Zen is locked.

### Look, navigation and settings
- **Portrait only** on phones and tablets; on computers the window stays a portrait column too (maximizing makes it a tall column, the floating call window is portrait as well).
- **27 themes in five groups** (Classic, Wild, Muted, Cool, Elegant), every one in a light and a dark version, each with its own shapes, borders, surfaces, buttons, backgrounds, transitions and motion; colours with fixed meanings; contrast checked everywhere. The default stays **Classic**; *Retro* is now *Player*.
- A **rail** with every section one tap away (no *More*); lock and rail toggle in the top bar; Invite and About at the top of Settings; a **Close friends** filter in chats.
- A new **About** with its own pages and **network census**: about how many people use Zen (an anonymous estimate) and the exact number in the pyramid.
- **Public peers editor** (add, remove, switch off, check, pin key, restore defaults); selectable text across the app; settings rows that wrap instead of cutting text.
- Media download over mobile data is on by default; the *Experimental features* screen and the unused notification delay setting are gone.
- **Nothing cut off:** every dialog and sheet scrolls above the keyboard, on small and split screens and with large text; tested in German, Russian and Arabic at 320 dp.
- **Right-to-left layouts** (Arabic): paddings, alignments, bubbles and badges follow the reading direction; graph labels too.
- **Zen on GitHub** in Settings and at the top of About.
- **Pyramid and Wallet for non-members** explain how to join through a friend who is a member and list friends who are.

### Updates and store build
- **GitHub release check and self-update:** at start and every 12 hours; the download is checked against `SHA256SUMS` (and Zen's signing certificate on Android), and against the maintainers' signature once their keys are pinned. Updates from friends over the network stay off until then, and the Updates screen says so.
- **The store build** (`appStoreOnly`, Google Play and Galaxy Store) is the same app with three forced differences: no self-update, no handing on of the APK (a link instead) and no launcher disguise. It also skips the check of its own signing certificate, since the store signs it.
- Tor `.onion` mirror links are no longer accepted.
- Built-in location (system service, no Google Play services) and Zen's own sounds.

### Battery
- **No permanent wake lock:** the Android background service wakes the phone only for short, timed moments (Nearby looks, mailbox polls, reminders, calls), and after 5 minutes in the background Zen only receives.
- **Fewer connections and pings:** a phone keeps 4 public peers instead of 16 (swapped when one fails); presence pings go only to friends, only while Zen is on screen, every 2.5 minutes.
- **Calmer screens:** status dots and neon effects pulse briefly on a change instead of all the time, animations run at a low frame rate and stop when hidden; videos pause off screen.
- **Computers on battery** stop bridging for others and keep 4 public peers; the battery estimate for looking around now counts the phone's wake-up time.
- **Shorter wake-ups:** an incoming signal keeps the phone awake for about 3 seconds (a message, knock or call until its work is done); mailbox polls and Nearby looks share one wake-up; a look is not scheduled while Bluetooth is off; each alarm releases its wake lock as soon as its work ends.
- **Lighter hellos:** a friend gets the device certificate once per run, later hellos only name it and are signed once; the 10-minute round greets only who was heard from lately (everyone once an hour); "I'm here" is not repeated within 2.5 minutes.
- **Only computers serve as always-on mailboxes** (a locked phone takes only its own mail); friends' bridges that are no longer chosen are disconnected (a phone keeps 1, a computer 5, a laptop on battery 1).
- **GIFs** play only while they can be seen (not in a hidden tab, under another page, in the background or in the tray) and are decoded at their on-screen size.

### Compatibility between versions
- **Data from a newer Zen is never overwritten:** every stored format has a version and is kept as is when it is newer; unknown fields survive a rewrite; a bar asks to update. Samples of all 1.12.0 formats are kept as tests.
- **Oldest supported version** (`minv` in hellos, `zen-min:` in a release) shows "update" instead of silently missing messages; moving an account between different versions says so; pyramid records of newer rules stop the pyramid with an update notice.
- **Ledger checkpoints** prepared, so logs can be shortened later without breaking 1.12.0; certificates and file lists are stored in smaller files.

## 1.11.0 — 20.10.2026

### Platforms
- **Android: three ABIs in one universal APK** — arm64-v8a, **armeabi-v7a** (older 32-bit phones) and **x86_64** (ChromeOS, emulators). The Go bridge is built per ABI and rebuilt only when it changed; native libraries are stored compressed so the APK stays about the same size. (x86 32-bit is not available: Flutter has no release engine for it.)
- **Android `appStoreOnly` flavor** (`flutter build appbundle --release --flavor appStoreOnly`; for Google Play and Galaxy Store, built manually; the files are named `Zen-APP-STORE-ONLY-do-not-install-manually.*` and are never installed by hand): no `REQUEST_INSTALL_PACKAGES`, no self-update (the screen says "Updates come from the store"), and "Pass it on" becomes a dialog with a link.
- **Windows ARM64** (`Zen-Windows-arm64.zip`, experimental): native build on `windows-11-arm`, Go bridge through llvm-mingw. The x64 build also runs on Windows 11 ARM under emulation.
- **Linux x64 and arm64: `.tar.gz` plus new `.deb`** (`Zen-Linux-x64.deb`, `Zen-Linux-arm64.deb`; Debian, Ubuntu, Mint). Audio and video playback through GStreamer (own `video_player` backend), a `.desktop` file (menu, `zen://` links, Wayland icon), AppStream metadata, `install-desktop-entry.sh` in the tarball, single-instance runner so a link from the browser reaches the running Zen. A Flatpak of the x64 bundle (`Zen-Linux-x64.flatpak`) is attached to the release.
- iOS (`Zen-unsigned.ipa`, iOS 15+), Windows x64 and universal macOS (12+, `Zen-macOS.zip`) unchanged.

### Translations
- **21 languages everywhere**, not only in the Dart UI: the invite page (`tool/pages`, language from the browser or `?lang=xx`, right-to-left for Arabic), iOS and macOS `Info.plist` strings (21 `<code>.lproj` folders), Android resources (`values-<lang>`; incoming-call screen, notifications, PiP, biometrics, installer, share), Linux `.desktop` comments. Everything outside the app UI now defaults to English.
- The new `docs/PRIVACY.md`, `docs/TERMS.md` and `docs/PROTOCOL.md` are in English; the About screen links to the privacy policy and the terms.

### Security
- **Network:** no more hard-coded 8.8.8.8 / 1.1.1.1 on Android — the bridge asks the system resolver (including Private DNS) first and falls back to a DNS-over-TLS list. The call UDP relay accepts a local socket only if its first datagram is an ICE check with the call's own username (desktop: listens on 127.0.0.1 only). The public bridge port goes through a Go limiter (4 connections per IPv4 or /64, 128 total, 1 MiB/s and 2 GiB per source per day, 32 GiB total). "Pass it on" serves on one chosen or best network and skips cellular, VPN and virtual interfaces. The "Answer" route is tied to one call number. Local-network discovery (see "Offline links" under Unreleased); at first only the account's own devices found each other.
- **Nearby:** a private per-phone key that never leaves the phone; friends get only a mask key, one-way hash-chain anchors and their own pair key, so nobody can forge another friend's presence. Alarm waves are signed with the pair key. The BLE token rotates every 10 minutes together with the MAC address. Greeting to a stranger carries no address — the reply goes over Bluetooth, and addresses are exchanged only between people who answered each other.
- **Releases:** the signed release manifest now covers the donation link, author and repository, plus mirrors; the app warns in red when its own values differ. New signed **canary** statement, 2-of-3 like a release; `tool/zen_release.dart` gets `maintainers`, `canary`, `sums` and `fingerprint`. Network updates stay off until maintainers are configured.
- **Pyramid rules:** a record that throws is rejected deterministically, quorum counted from active members, over-limit issuance by whole-pyramid referendum, content bans by entry id with the signed original attached. New record types `natpin` and `badge`.
- **Storage:** hidden file names for `meet/list/` and `ledger/` as well; Windows data lives in `%LOCALAPPDATA%` instead of Roaming; 20 MB limit warns from 50% and compresses harder from 75%; stale `*.tmp` files are cleaned up; clipboard copies expire after 60 s everywhere.
- **Mailbox attachments** are chunked and encrypted with a fresh key (ChaCha20-Poly1305); mailboxes see only ciphertext (see Features).
- **Profile images** (avatar, background) are moved into the encrypted media vault.
- **Forward compatibility:** unknown log spaces are kept for the owner (max 1000 entries per device log); golden protocol frames pinned in `test/wire/golden_frames_test.dart`.

### Privacy
- **Friendship levels have teeth:** a weak friend sees neither the friend list (they can ask via "Introduce me") nor statuses other than "Do not disturb"; the new default list audience is "Friends and close friends". Changing a level resends the list and status right away. People met in person are asked "How close are you?".
- **Group invites:** "Who can invite me to groups" (Anyone / All friends / Friends and close friends (default) / Close friends only); an invite below the threshold is rejected immediately.
- **Per-field profile visibility:** status, About me, photo, background, nationality, friend count, follower count — each Public / All friends / Friends and close / Close / Only me. Public fields go in the public entry, the rest in encrypted per-audience entries.
- Your device address goes into the public profile only when you have a public post or share.
- **Dating:** "I'm going on a date" can request your location on demand (the friend asks, your phone asks you or answers automatically if you agreed); "Report a minor" disables a profile locally at once and reports it to the pyramid, and a phone that receives reports from 2+ different reporters disables it too; re-confirmation with password or biometrics when entering Dating and after returning from the background.
- **Screen sharing:** system notifications are shown without content, a permanent red banner says the whole screen is visible, and Android older than 14 gets a warning first.
- Offline mailbox attachments use per-sender quotas and ciphertext only; recorded calls beep for all participants.
- "Media over Wi-Fi only" (default for new installs).

### Features
- **Calls:** a "Board" tab in groups (the group's own space of posts); an audible signal for everyone when recording starts. Camera and screen at the same time (a second video track) is built but not yet tested on devices.
- **Mailboxes and attachments:** photos, videos, files and longer voice notes for an offline friend wait at their mailboxes and arrive when they return, even if the sender is offline too. Per-sender limit 20 MB by default (Settings → Offline mailboxes → Attachments: off/5/10/20/50 MB), 200 MB total, 14-day expiry; live WebRTC stays the fast path.
- **Profile and feed:** per-field visibility, nationality (up to 3 country codes), mini-profile card, other-person profile with Add / Follow / Message and tabs Posts · Photos · Videos · Thanks · Info; signed follows with a followers list and blocking; "Liked by you, Bob and 1,284 others"; the author can hide comments and block people in their threads; paged reaction bundles (up to 2000 likes, 300 comments); grouped bell notifications; metadata stripped from MP4/MOV/M4A; a deleted post's tombstone reaches resharers.
- **Meetings:** the friend graph zooms (1–8x), groups into clusters and shows friends-of-friends labels; Alarm gets a fresh location from the background and a backup SMS to up to 5 numbers; dinner circles of 4–8 people, "vouching" for guests, shared pot; "Ask the network" answers are signed by the answering device; a "shared cause" plan with "I'll take it" claims.
- **Neighbours:** door code with exactly one door-inbox address, a link `https://…/Zen/m#<code>` and a web page `/m`; "Ask" about an invitation.
- **Pyramid:** pinned posts in the national section, age and gender badge, anonymous branch statistics (from 5 people), "Delivered / read" counts, price card in the profile, paid introduction (the broker is paid only after the introduced person agrees), escalation of reports level by level, 24 h / 7 d / 30 d breaks, only a friend of at least level "Friend" can be admitted.
- **Onboarding and recovery:** paper backup of the account key (56 characters in 14 groups, QR `zen-key:<code>`, with a check of two random groups) and restore from paper; a "Secure your account" card after the permission step and a reminder in Settings.
- **Permissions and diagnostics:** location, background location, exact alarms and vendor-specific battery instructions (Xiaomi, Samsung, Huawei, OnePlus, Oppo/Realme, Vivo); a "Welcome to Zen" card; **"Why is it not working?"** screen (network, background, notifications, battery, clock, free space, "Copy report"); clock-skew bar; six tabs plus "More"; accessibility labels.
- **Versions:** friends exchange app versions, and Settings shows a quiet "Friends have a newer Zen" bar; feature flags ("Experimental features": Pyramid, Wallet, Dating; all three are on by default and can be switched off, Neighbours is core); `v: 1` format versions for settings and profile.
- **Performance:** heavy encryption of data over 64 KB runs in a short-lived isolate (byte-identical output), the feed is recomputed only when the log changes and is built lazily.

## 1.10.0 — 14.10.2026

### Languages, Linux and macOS, security audit
- **21 languages:** Polish, English, German, French, Spanish, Italian, Portuguese, Dutch, Czech, Hungarian, Romanian, Turkish, Russian, Ukrainian, Arabic (right to left), Hindi, Indonesian, Vietnamese, Chinese, Japanese, Korean. Zen picks the system language (English if unknown); **Settings → Language** changes it instantly. Source strings are Polish in `t()` / `tn()`, translations in `assets/i18n/<code>.json`, checked by `dart run tool/i18n.dart` and `test/i18n_test.dart`.
- **Linux and macOS:** new release files `Zen-Linux-x64.tar.gz`, `Zen-Linux-arm64.tar.gz`, `Zen-macOS.zip` (Apple Silicon and Intel, macOS 12+), unsigned, built by GitHub Actions; `SHA256SUMS` covers all release files. macOS: Touch ID through the Secure Enclave, screen protection, no sandbox. Linux: key in GNOME Keyring / KWallet, tray through AppIndicator. No Bluetooth, call recording or camera on either; no voice-note or video playback on Linux.
- **Security audit fixes**: account recovery bound to the account, bridge memory limits, proof of device address, file warnings, mailboxes only for friends, corrupted data no longer removes friends, notification and screen privacy, GIFs on tap, pinned CI actions and APK key only for approved tags, `SECURITY.md`.
- **"Report":** reported content can be hidden locally, decisions can be appealed, the dialog no longer promises "Remove from my device".
- **Docs:** `docs/RELEASES.md` (channels, store requirements, Android developer verification, iPhone, costs); README with languages, Linux, macOS and an honest note about GIFs from klipy.com.

### Security, currency, iPhone
- **First launch:** after the password, a "Permissions and Bluetooth" screen (notifications, Bluetooth, full-screen alarm, background work, optional microphone and camera), also available in Settings. No more series of system dialogs.
- **Bluetooth:** steady, frugal advertising while visible (also from the background service), restored after Bluetooth toggles; scanning only on the "Nearby" screen (background scanning off by default).
- **Friends of friends:** friend lists in separate files with limits; frames from non-friends wait for approval; ping/pong carry digests and missing data is re-requested.
- **Graph:** search (diacritics-insensitive), filters, shortest path to a person, lines between friends who know each other, "Friend lists: from X of Y friends" with "Ask".
- **Consent as currency:** "Who sees my friend list" (all / on request / nobody), "Ask for an introduction" (a mutual friend passes it on, the other person decides), "Write a letter" through a mutual friend (max 3 per week per person), "Ask for an opinion". Within a pyramid a broker can price an introduction.
- **Pyramid:** no parties (party founding and primaries removed). Reports and appeals only from members, with limits; the treasurer signature cannot be replaced or removed; limits for proposals and market messages.
- **Currency:** hard limits (10^15 hundredths per amount, 2^60 per balance), saturating sums, re-confirmation (password or biometrics) before sending money, screenshot block in the wallet, all amounts in hundredths.
- **Signed Bluetooth alarm:** HMAC-SHA256 with the Nearby secret, valid ±10 min, replays rejected; only a verified friend alarm rings. Sent before state is saved.
- **Friends' attachments, voice notes and photos encrypted on disk** under random names; photos decrypted only in memory.
- **Stores only in the current envelope**, node configuration and verified-signature memory protected.
- **Panic password wipes everything:** stops the background service, then clears cache, temporary files, `Android/data/…/files`, Zen folders in Documents and Downloads, and saved copies.
- **APK signature:** "Pass it on" and ADB check the certificate before sending and installing.
- **Invitations:** a code, a link with the code after `#` and `zen://c/CODE` work.
- **Smoothness:** in-memory presence, delayed writes, screens watch only what they show.
- A friend's name always comes from their latest profile.
- **Dating like Tinder:** card stack, right "Yes", left "No"; "Match-make" and "Ask for an opinion" on the card.
- **Statuses redone:** highlighted "Your status" card with a countdown; friends' statuses grouped by kind.
- **Weekend plan:** a fourth form in Meetings — a loose plan with a reach, "Joining" / "Maybe"; once enough people join it becomes an event with a chat.
- **iPhone:** Zen runs on iOS (SideStore / AltStore, free Apple ID); `Zen-unsigned.ipa` built by GitHub Actions. Features iOS forbids (background work, background Bluetooth, button alarm) are marked unavailable.
- **Building:** the Go bridge builds itself on `flutter build apk` / `windows` (only when sources changed). GitHub Actions: tests on every push, release files on tag, invite page on Pages.
- **Licenses** of Go modules and fonts in "About → Licenses".
- **Invite page** `robertostrowskijagoda.github.io/Zen/#CODE` opens Zen or shows downloads; donations: **buycoffee.to/zen**; a few words from the author in "About".
- **Honest biometrics:** the first-password question says any fingerprint stored on the phone will unlock Zen; the default is "Password only". Windows: "Windows Hello unlock" with a warning in Settings.
- **Icons:** Feed as a newspaper, Wallet as a dollar sign; one pyramid drawing everywhere.
- **License:** a source-available license with the author's permissions (later replaced by GPL-3.0-only) — anyone, including companies, may use Zen for any purpose; it may not be sold or bundled into paid products; the author and donation link must stay; pull requests welcome, forks and modified versions forbidden.

### Names from profiles, safe media, recordings in posts
- **A friend's name comes from their profile** and cannot be changed (newer wins). Instead of "Rename" there is a **nickname** visible only to you, shown in small italics under the name and shared across your devices. Names from others are stripped of control and direction-changing characters and trimmed to 60.
- **Virus protection for photos and videos** (`media_guard.dart`): every incoming photo is decoded in pure Dart and re-encoded, so the system image decoder never sees the original (the class of WebP-2023 attacks); oversized "photos" are rejected before decoding. Videos and recordings must have a valid container (MP4/MOV/M4A/WebM/Ogg/MP3/WAV), otherwise they become a plain file Zen will not play. Type, MIME and file name come from the content. Files that could run a program (EXE, APK, scripts, shortcuts, macros) get a warning before "Save a copy"; Zen never opens files itself. Camera photos sent in chat lose GPS.
- **Voice notes and audio recordings in posts:** "Record a voice note" and "Insert a recording from file" (up to 25 MB); in chat, "Audio recording from file". Playback only on tap.
- **Zen codes straight into the app (Android):** with "Open supported links" enabled (Invite → "Zen codes straight into the app"), a code scanned with the ordinary camera opens in Zen. Flutter's built-in deep links disabled.
- **About → Your own Yggdrasil bridge:** how to run a permanent node without Zen.

### Convenience, security, release
- **Biometrics off by default;** asked once when setting the first password.
- **Default lock after 5 minutes in the background.** Lock-screen texts say the background service still receives messages.
- **Security fix:** attachment file names from others are sanitized — previously "Save a copy" could overwrite files in the app directory (path traversal).
- **Default theme: system.** Black logo in the light theme.
- **Left panel:** friend graph first; Wallet before Bluetooth; Bluetooth before Invite; new pyramid and feed icons; "Lock now" on the panel. Buttons shrink to fit (checked at 360×568: 13 tabs and lock).
- **Windows tray icon** rounded.
- **"Pass it on"** easier to find: Invite ("Friend has no Zen?") and About.
- **"About" rewritten:** donations first, then what Zen is (including the pyramid and grassroots politics), "Why", how to use, privacy with the recovery circle (up to 6 friends: password + 2 of them after 24 h, or 4 of them without a password after 7 days), platforms, Yggdrasil, why not in stores, how to check it is not a virus, official GitHub link, licenses.
- **Own status clearly marked** ("YOUR OWN STATUS", "Own" pill).
- **Desktop bridge** stays on by default, silently; the "Help others connect" switch is at the bottom of Settings (Advanced → Network and service).
- **One QR code for everyone:** an invite is a link with the code after `#`, so it never reaches the server; the Zen scanner adds the friend at once.
- **README for ordinary people:** download, what to do after scanning a code, installation (including the 2027 path for unverified developers with a 24 h wait), Windows SmartScreen, virus checking, why not in stores, privacy, Yggdrasil, donations, license summary, developer part.

### Statuses, nearby, alarm and reliability
- **More "right now" statuses:** Need help urgently (louder notification, separate red button), Can help, Going for a walk, Want to eat together, Want to play — and a **custom status** (own words and emoji). Compact pills instead of big tiles.
- **"People nearby" has its own button** in the left panel. Full Bluetooth scanning with the screen open; otherwise a short look-around every 5 minutes.
- **Alarm with confirmations:** the friend's phone replies "arrived" and "seen"; the alarm screen shows who got it, who saw it and who responded, with retry.
- **No whole-file rewrites:** conversations in segments of 200 messages, pyramid records in an append-only log.
- **Fewer freezes:** verified pyramid ring signatures cached on disk, first verification in the background.
- **Android no longer kills the service after 6 hours** (Android 14+: `specialUse` service type); if the system stops it anyway, a "Zen is not receiving in the background — open it for a moment" notification appears.
- **App sharing through Quick Share / Bluetooth** (new button in "Pass it on").
- **Same colors in light and dark themes;** the "ZEN" mark on the start screen.
- Someone in two pyramids sees the one they joined most recently.
- **Network identity survives a corrupted file:** node configuration written atomically with a backup (previously a corrupted file meant a new address and losing contact with friends).
- "Meetings" state from an unknown (newer) version is no longer overwritten with an empty one.

### The network carries itself: computers are bridges
- **Every computer is a bridge** (on by default). The PC app opens a router port itself (UPnP, else NAT-PMP), asks friends to verify from outside that it is reachable, and only then announces the bridge. Port and announcement are renewed every half hour, withdrawn when unreachable, closed on exit.
- A computer with a public address (no router, or IPv6) is a bridge too. The PC node listens on IPv4 and IPv6 (`tls://[::]:32913`), also on Linux and macOS.
- **Bridge status in Settings → Network and service:** working / router did not open the port / router refused (UPnP off) / no public address (CGNAT) / firewall blocks / waiting for a friend online, with "Check now" and hints. A manually forwarded port works too.
- **Bridge checks:** the app waits for the Yggdrasil handshake instead of a bare TCP connection; bridges must have a public IP (no names, no home networks), so nobody can send the app "knocking" on devices in your network. A friend checks at most 4 addresses per minute for others.
- **Bridge choice by speed and networks:** fastest working bridges spread across address blocks; rechecked every 6 h, dead ones get a second chance after a day and are dropped after three failures.

### Security audit
- A stranger can no longer become your friend with one packet (`friend_accept` without your invite goes to confirmations).
- A locked app no longer breaks friendships or loses invites: signals wait until state is loaded after unlocking.
- Two people who invite each other at the same moment become friends at once.
- Flood and "bomb" protection: zstd, signal fragments, photos and images, attachments, friend requests, group invites, events, dating bundles, offline mailboxes, alarms, questions.
- Pyramid: resilience to bad ring signatures, double votes, date rollback, veto and issuance-limit bypass, constitutional change without quorum; sync only with friends.
- Windows: data key sealed only when Windows Hello is enabled.
- Passwords: changing needs confirmation, password and panic password cannot match; panic destroys keys first.
- Device linking with a commitment; conversation file names do not reveal contacts; writes bound to the file key.
- A link can no longer answer a call or replace the caller's name; notification content hidden for dating and pyramid too.
- Android: no data backups, call screen unavailable to other apps. "Pass it on" shows the file's SHA-256.
- Test pilot only in debug builds; no logcat logs in release.

### Polished look
- Friend graph scrolls with its legend and no longer overlaps at small sizes; friends do not cover "You".
- "Meetings" tiles and "What do you feel like" statuses collapse to one column instead of breaking words.
- On desktop every screen keeps the same narrow layout.
- Amounts with thousands separators, pyramid levels from 1 and other small fixes.

### Reports, events, alarm and neighbours
- **"Report" everywhere:** posts, messages (also in groups) and profiles; reported content can be hidden at once; in the pyramid it goes to the reports delegate or the top.
- **Dating:** bundles encrypted with a separate key (ChaCha20-Poly1305), key given on request; vouches signed with a vouching key; several photos; "Dating" status 💘; "Thank the matchmaker"; "I'm going on a date" deadlines watched in the background.
- **Events:** shared album (photos from attendees, from 15 min before start), thank-you cards, organizer tips in pyramid currency.
- **Alarm:** audio recording for close friends and an optional Bluetooth wave to nearby phones.
- **Alarm shortcut: 5× power button** (Android, off by default): five quick presses (~4 s), also with the screen off and Zen closed, raise the ordinary alarm; only the PIN cancels it, the panic PIN works as always; vibration confirms. Warning about the system "Emergency SOS" that reacts to the same gesture.
- **Nearby alarm with the app closed:** with the option on, the Android background service shows nearby phones and receives alarm waves; each wave rings only once.
- **"Also look around in the background"** (off by default): every 5 minutes 10 s of frugal scanning, only to mark friends in range as "met in person".
- **Neighbours:** flat photo, removing a neighbour with a new key for the rest, revealing yourself to neighbours.
- **Event ticket pinned to the phone:** "I'll come" sends the organizer a key held only by that phone; at the door the phone shows a live code (refreshed every 20 s), accepted once within ±90 s.
- **Neighbours: a removed household member cannot forge a new flat key.** Each member phone has its own key known from the profile; removal votes and the new-key notice are signed by it; neighbours accept a new key only with the signature of a remaining member and a majority. Two competing new keys produce a warning, and scanning the new door code settles it.
- Fix: a shared event album disappears from disk with the event even if the app never loaded it.
- **Currency:** tip for an answer in "Ask the network", prices by friendship level, announcements through broker chains, moving a whole pyramid as a branch into a larger one.

### New look for the whole app
- **New palette:** deep dark (or light) base tinted with the accent and a gradient accent. **Color choice is back** (Settings → Appearance: 27 colors + light/dark/system); the default is "Zen" purple.
- **Readable typography:** sans-serif everywhere, sentences instead of ALL CAPS.
- **Every screen redone:** Inbox and chats (gradient bubbles, new composer), profile (cover, avatar in a gradient ring), Feed, Meetings, events, Table for Six, dinner circles, Ask the network, nearby, alarm, dating, neighbours, graph, pyramid, Invite, settings, lock screen, calls, start screen.
- **Own buttons in the left panel** for Dating, Neighbours, Friend graph and Alarm (red, at the bottom).
- Elements no longer overlap and fit narrow phones (checked with phone-size screenshots: `tool/ui_tour`).

### Smaller changes
- **Lock after leaving the app** is configurable: Settings → Security → "After leaving the app": 5 s, 30 s, 1 min, 5 min, 15 min, 1 h (default 5 min).
- Events: "Meal" instead of "Dinner / supper", "Friends of friends of friends" instead of "2 steps away"; explanation of Table for Six when creating an event.
- Neighbours: an "Add" button next to a flat that scanned your code replaces the toggle.
- Dating: the "Thanks" tab fits the screen.

### Pyramid, power, currency — new "Pyramid" tab
- **Joining in person:** the cell leader's QR code, year of birth and gender confirmed at entry (only a hash is public).
- **Cells:** leader swap 2 of 3, **anonymous vote request and anonymous vote** (ring signature — nobody knows who voted how), leaving, taking a free seat, absence after 60 days, removal only by one's own cell, moving under another leader, **merging pyramids** (the smaller one joins as a branch).
- **Power:** top decisions 2 of 3, delegations (scope, limit, deadline, sub-delegation, revoking), bans with **immunity** of higher levels, **"Report"** in dating and the pyramid (delegate or top, open decision, appeal).
- **Referenda counted by tree** (votes go only to the cell leader, verifiable sums upward), **constitution** changed by referendum, **national section** with a lead, political and national posts.
- **Currency:** issuance with a 24 h veto window and term limit, 15 treasurers (transfer valid with majority signatures, no double spend), conditional payments; **access market** — paid mailbox, introductions, sharing, announcements.
- **Crisis mode:** alarm with reach and a Bluetooth wave to nearby phones, also without internet.

### Multi-client testing (`docs/TESTING.md`)
- **Network simulator** (`SimNetwork`): virtual clock, delays, loss, offline phones, partitions; 20+ pyramid, dating and neighbours scenarios in `flutter test`, including chaos with repair.
- **Several apps on one computer:** `zen.exe --zen-profile=NAME` (separate data and keys), `tool\multi_client.ps1 -Count 4`.
- **Pilot** `/x/…` and `dart run tool/zen_drive.dart pyramid 48888 48889 48890 48891`; phone through `adb forward`.

### Dating through friends — "Meetings → Dating"
- **Only up to 3 steps**, always with someone in common: "You know each other through: Bob → Kasia".
- **Nobody knows you are dating:** every phone weekly sends and forwards identical bundles — with a profile or an empty decoy.
- **Dating profile** built in one tap from the main profile, with preferences (gender, age, 1–3 steps) and hiding from chosen friends or whole groups.
- **"Yes / No":** a pair forms only on "Yes" + "Yes"; "No" sends nothing.
- **Pair chats, introductions and likes are encrypted** and travel through friends who do not even know whom they are from.
- **Ask for an opinion** from a mutual friend, **matchmaking**, **vouches** on the profile.
- **"I'm going on a date":** a friend sees where you are; if you do not confirm "All OK", they get a reminder, then an alarm.

### Neighbours — "Meetings → Neighbours"
- **Neighbour profile of a family / flat group:** "Novaks · flat 12", "About us", invitations (date, seats), "We offer", "We need". Neighbours do not see your accounts.
- **Household members** (no limit): another phone joins by scanning the member code. Anyone can edit the profile and reply; everything syncs.
- **Moving out:** the old door code stops working, neighbours are informed, new tenants start from scratch.
- **Door code:** printable A6 sticker (PNG) with its own password; "New code" invalidates the old one.
- **My neighbours:** scan a neighbour's door — both flats are on each other's list. Messages between flats, sign-ups with seat limits, muting, removing.
- **Nearby invitation:** send an invitation over Bluetooth to Zen users in range; they add you as neighbours with one tap.

### Meetings — new "Meetings" tab
- **Right now:** "Want to talk", "Want to go out", "Need help", "Do not disturb" — for an hour, until end of day or until cancelled, with a note, for all friends or only close ones.
- **Alarm:** hold for 3 seconds — close friends get it at once, full screen, with sound and your location (refreshed every minute); you see who is coming. Cancel with the ordinary PIN; a separate panic PIN cancels it on screen but friends are warned you may be coerced. A wrong PIN cancels nothing. "Call 112" button. Works with the app closed.
- **People nearby** (Android, Bluetooth): friends with names, strangers as a pseudonym rotating every 15 minutes, distance, "Write" to a stranger without revealing your account, "Invite as friend" with the "met in person" stamp.
- **Events through friends:** party, meal, meeting — for chosen people, friends, friends of friends or further. Guest list shows how many you know and who brought whom. Seat limit, "+1" with consent, QR tickets checked offline at the door, "We met" after the event.
- **Table for Six:** a dinner with people two steps away — Zen picks 5 guests who know each other the least.
- **Dinner circles:** cooking rota, swaps with consent, allergies, "who brings what".
- **Ask the network:** a question to friends (further only manually), answers come back with "friend of Bartek".
- **Friend graph:** you in the centre, close friends, friends and friends of friends, status colors, mutual friends. New setting "Show my friend list to friends".
- Android: new Bluetooth permissions (no location) and location (alarm only).

### Resilience: network updates and "Pass it on"
- **Updates from friends, without a store or server** (**off** for now): a new version travels as an ordinary file from friend to friend, waits **7 days** after first seen and **never installs itself** (Android opens the system installer; on a computer the installer lands in Downloads).
- **Settings → Updates and Pass it on:** version, state of a new version, "Load update from file" (`.zenupdate`).
- `tool/zen_release.dart` and `docs/RELEASES.md` describe the current (disabled) mechanism.
- **Pass it on:** the phone hands Zen to someone nearby without internet — own hotspot (Wi-Fi QR) plus a second QR with a download page. Also works on the same Wi-Fi. Only that one file is served, at a random address, for at most 20 minutes.
- **From a computer by USB:** "Install" with a connected phone (via `adb`), including a newer signed version.
- **HTTPS-looking traffic:** a computer bridge asks the router for external port 443 first.
- Android: new permissions — installing apps (updates) and Wi-Fi / nearby devices (hotspot).

### On-device data protection
- **App password required by default** (at least 8 characters); skipping is a conscious choice with a Settings switch.
- **Argon2id** for password and panic password.
- **Hardware-backed biometric unlock:** the key lives in Android Keystore (StrongBox if present) or a Windows TPM (DPAPI without), opened by fingerprint / face / Windows Hello. A new fingerprint invalidates the key — you type the password once.
- **Account key leaves memory** together with the data key when the app locks.
- **Re-confirmation** (biometrics or password) before Account and recovery, Devices and Call recordings; valid for a minute.
- **Screenshot and screen-recording block** in chats, groups, recordings, account and devices (Android and Windows); can be turned off.
- **Disappearing messages** in chat and group menus: 1 hour, 1 day or 7 days; the same setting reaches the other side and your other devices; messages vanish everywhere together with files and never enter durable account backups.
- **Panic password** also deletes the key in the security chip.
- **Rooted-phone warning** in Settings → Security (su, Magisk, LSPosed, Frida, test keys), without blocking.
- Android: the app now runs on `FlutterFragmentActivity` (needed for the system biometric prompt).

### Account on several devices
- **Settings → Devices:** list, "Link a new device", "This is the new device: join the account", "Unlink".
- **Safe linking:** the new device shows its code (QR or typed); both screens show the same 6 digits; only after confirmation the account key travels, encrypted with one-time keys.
- **Friends see one person:** messages and calls reach every device; answering a call on one silences the others; what you write on one device appears on the rest.
- **Friends and groups are the same everywhere:** stored in the account, encrypted so only your devices read them. Friends keep an encrypted copy, so a **recovered account comes back with friends and groups**.
- **Unlinking a lost or stolen device:** from then on nothing from it is accepted and it gets no messages; the device itself shows it was unlinked.
- **Chat history on a new device:** all conversations so far (files up to 25 MB each), encrypted for your devices only.
- **Sent photos, files and voice notes** (also in groups) appear on other devices, not just text.
- **Removing a friend, leaving a group, renaming and blocking** on one device happen on all.
- **A group member with several devices** is one person.
- **Security:** the greeting between devices carries an address-proving signature, so nobody can impersonate a friend's second device.

### One invite code
- There is only one code: 25 characters (`XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`). The QR carries the same code, so it is smaller and easier to scan. The name comes with the invite.

