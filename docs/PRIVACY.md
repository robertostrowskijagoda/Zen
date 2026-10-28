# Zen - Privacy Policy

*Version for Zen 1.11.0 - last updated 22 October 2026.*

This policy explains what happens to your data when you use Zen. It is written
to be honest about how the app actually works, including the places where
privacy is weaker than people might expect.

## 1. The short version

- **The author runs no servers for Zen.** There is no Zen account, no cloud, no
  phone number, no e-mail address and no sign-in. The author does not receive,
  store or see your messages, contacts, posts, location or profile.
- **Your data lives on your devices.** It is encrypted on the device with a key
  protected by your password and, where the system has one, the hardware key
  store (Android Keystore, Windows TPM, Secure Enclave).
- **Other people's devices get what you send them.** Friends, groups and the
  pyramid you join receive the content you share with them, and their copies
  are outside your control and the author's control.
- **Network helpers see addresses, not content.** Zen runs on the Yggdrasil
  network. The nodes that carry your traffic can see your IP address and your
  network address, but not what you write.
- **Two outside services are contacted by the app itself:** the GIF search uses
  klipy.com (section 6) and, except in the store build, Zen asks GitHub for the
  newest release (section 7).
- **No analytics, no advertising, no trackers.** Crash and diagnostic logs stay
  on your device.

## 2. Who is responsible

Zen is made by **Robert Ostrowski-Jagoda**, an individual developer
(see the `NOTICE` file; project page: https://github.com/robertostrowskijagoda/Zen).

Because the author never receives your data, in practice the author is **not in
a position to access, correct or delete it**. To the extent the law treats the
author as a "controller" of anything (for example, of the information published
on the GitHub project page, or of the app's design choices), the author is that
person. Each user who shares other people's data with their friends (for
example by uploading a photo of someone) is responsible for doing so lawfully
themselves.

Contact: see section 13.

## 3. What data exists and where

### 3.1 On your device (never sent to the author)

- **Identity keys.** On first start Zen creates cryptographic keys: a mesh
  network key (this gives you your Zen address, which is derived from it), a
  ledger account key and device keys, and keys for sealed mail and dating.
  Your "invite code" and QR code encode your network address.
- **Profile:** display name, bio, custom status, avatar, profile background,
  gallery, "gratitude cards".
- **Contacts and conversations:** friends and their levels, groups, messages,
  voice notes, photos, videos and files, your posts, likes and comments.
  For each friend who shows it, their last presence (open, in the
  background, offline), when it was last confirmed and when they last
  opened Zen, so that after a start it can be shown as it stands (when
  confirmed within the last 30 minutes) or as not known yet instead of
  offline; it is replaced by their next answer.
- **Features data:** "Right now" statuses, events, alarms (including location
  and recorded sound, if you use them), neighbours (flats), dating profile and
  decisions, pyramid records and balances, and the ledger of signed entries.
- **"Passed by" (encounters log):** friends you passed and how many other
  Zen phones were around, built only from what "People nearby" hears while it
  scans (nothing scans for it), with the time and, if the phone had a recent
  position, a place rounded to about 100 m. Strangers' tokens are kept in
  memory for one 10-minute slot and only the largest hourly count is kept;
  Bluetooth addresses are never kept. It stays on the phone, goes after 30
  days and can be cleared at any time.
- **Settings, the lock password hash parameters, the panic password** and
  similar.
- **Diagnostic log:** rolling text files (`zen-diagnostics-ui.log` and, on
  Android, `zen-diagnostics-svc.log` for the background service; each kept
  to at most about 1 MB) with technical messages, and technical numbers:
  when the background work woke the phone and for how long, how the app was
  ended, how much memory the network node used, how many peers it had and
  how much data passed. Those numbers are counts and sizes only, never a
  message, a name, an address or a file name. Folder paths are shortened in
  the messages. You can read the log, and save it as a file, in Settings. It
  is **never sent anywhere automatically**. If you copy or send it to
  someone (for example when reporting a bug), that is your choice - check it
  first.

Almost everything above is stored encrypted (AES-256-GCM, with a master key
protected by a key derived from your password with Argon2id and, where
available, by hardware-backed storage). **Exceptions:** media you export or
save on purpose is saved as an ordinary file, and the language you chose is
kept in a plain file (it is needed before you unlock). On Android, so that
the phone can keep receiving while Zen is locked, this device's network
identity, a list of keyed tags of your contacts, and what the alarm, "people
nearby" and your flat's door need while Zen is locked (alarm recipients and
the alarm's own key, your Bluetooth tokens for the next days, the keys
friends gave you to recognise them nearby, the door keys) are sealed with a
separate **background key** in the system's secure storage that opens
without your password; what arrives while Zen is locked is stored sealed so
that only your unlocked app can read it. This is a deliberate trade-off: someone
who can extract both the app's data and that key (for example on a rooted or
compromised phone) can read those small "kits" - who the alarm goes to, the
alarm key (it signs alarm frames only), your Bluetooth tokens for the next
days (not your private nearby key), the flat's door keys - but not your
messages, posts or contacts' names, which stay under the password.

### 3.2 What other people receive

When you use a feature, the people involved receive the data that feature needs.
Everything below is sent device to device over the Yggdrasil network.

| You do this | Who receives what |
|---|---|
| Send a friend request | The other person: your Zen address, display name and the note you wrote. |
| Be a friend | Friends can see your profile (name, status, bio, avatar), whether Zen is open on your screen, in the background or offline, and when you last opened it (carried by the presence pings, every 2 min while Zen is on the screen, and their answers, and told at once to the friends who have Zen open when you leave Zen, come back, quit it on a computer or get the network back; not shown to a weak acquaintance; the time can be turned off in Settings), your current "Right now" status if its audience allows it, and - depending on your setting - your friend list. Your "closeness level" for a friend is private; they never learn it. |
| Like, comment or write to someone who is not your friend | The author of the post and the friends who passed it on get your signed like or comment together with a small signed copy of your profile (name and photo). A first message to a non-friend (only if their settings allow it) carries the same. |
| Chat | The recipient: message text, attachments, timestamps, typing indicator, delivery and read receipts, disappearing-message timers. |
| Groups | Every member (up to 256) gets each message. Members learn the group's member list. |
| Calls | The other participants: call signalling and the media stream (WebRTC). Participants learn your network address and, through WebRTC, network details needed to connect. |
| Post on your board | The ledger replicates your post to the devices of the chosen audience. Posts with the audience "All friends", "Friends and close friends" or "Close friends only" are encrypted so only friends of a high enough level can read them; **public posts and public profile fields can be read by anyone who obtains them**, including people who follow you and anyone they were passed on to. The existence, time and size of entries and your account key are visible to anyone who holds the entry, even for encrypted posts. |
| Offline mailboxes | Up to six friends you pick (or the app picks) hold **encrypted** copies of mail addressed to you for up to 14 days, including attachments (up to 24 MB each, within a per-sender quota). They see who it is from and to, size and time, not the content. |
| Alarm | The friends chosen for alarms: your location (if allowed), a note, recorded sound, and delivery confirmations. Phones nearby may receive a signed Bluetooth "wave" (alarm id and time; only friends can tell whose it is). The location comes from the phone's own location service (never from Google Play services) and is sent only with an alarm or a date-safety request you or the friend triggered. Tapping a map link opens openstreetmap.org in your browser with the coordinates. |
| "People nearby" (Android) | If you turn it on, your phone advertises a token over Bluetooth that changes every 10 minutes (together with the Bluetooth address); only friends can tell it is you, and they cannot show it to others in your place. Anyone nearby can see that *a* Zen phone is there and its approximate signal strength. While Wi-Fi discovery is on (also while Zen is locked), the same changing token also goes out with the local network's beacons, so people on the same Wi-Fi who look around see you too (friends by name, others by the pseudonym); there, your IP address stays the same while the token changes, so they can tell it is one device while you stay on that network, but not who you are. If you "wave", the person gets your pseudonym, your short text and your mesh address - not your account. Friends' phones that hear you may note it in their own private "Passed by" log (section 3.1). |
| Offline links | If you leave Wi-Fi discovery, Wi-Fi Direct or Bluetooth on (they are on by default) or turn on Apple Multipeer, your device broadcasts adverts so friends' and your own devices nearby can link with it without internet: on the local network a UDP beacon every 10-30 seconds, over Bluetooth an advertisement with a fixed Zen service id, over Wi-Fi Direct a service record (and, on a phone that hosts a group, the group's name and passphrase). An advert is a Bloom filter of tags only the right devices can test, with a new random salt every time, so strangers see random bytes; they can tell that *a* Zen device with local links is there and roughly how many devices it links with, not who you are. Strangers who join the same Wi-Fi network or group get no link and no data; the handshake proves a shared secret first. |
| "Open to meet" | Off by default. If you turn it on (a prompt in the dating profile), your friends receive only your intention (dates, new friends or both), and they pass it on to their own friends, so your friends of friends may see a badge on the graph. People you exclude are listed as salted hashes, so friends who pass the flag on can skip them without learning who they are. Nothing else from the dating profile goes with it. |
| Dinner circles: sharing food | A member's food offer (dish, portions, time window, photo, price or "free") goes to the circle and, if the cook chose, to friends or friends of friends. The place is told only to people the cook accepted; a friend who passes a request between a friend of a friend and the cook also sees the place in the answer. Who fed whom is kept only on the cook's and asker's own phones. |
| Neighbours | Flat or building members you join: what you choose to reveal in that feature. A knock at a flat's door is held, when no resident is online, by up to six friends of a resident, sealed so that the friend learns neither who knocked nor which flat; if you let your friends run "mailbox doors", your phone does that for them (it holds ciphertext for up to 7 days). |
| Dating | Your intention (dates, new friends or both) is part of the sealed match test and of your profile, and interests are part of the profile; the filters you set stay on your phone. Small "lanterns" (a one-off key and nothing else: no age, name, gender or preferences; the same shape whether or not you date) are passed up to two hops through friends' phones. A phone that sees a lantern runs a sealed match test; only if the two of you fit does it ask for the profile, which is sent sealed, so the phones on the way cannot read it. Dating never asks about your age. People who can read your profile see what you put in it. Your "Yes" is sent only as an unlinkable token; "No" sends nothing. |
| Pyramid | When you join, you give your birth year, nationality and gender; the person who admits you signs that this is true. Members of the pyramid see your pseudonym, nationality and **age** in your pyramid profile (gender only if you choose to show it). Members also receive the signed records you create (votes, proposals, posts, payments, reports) and share a group chat with the members of their cell and of the cell below (no invitations; all of them see the messages). People outside the pyramid can read posts of the top and of the national section that their friends in the pyramid pass on (the author's pseudonym and the signed post). Votes in your cell are signed anonymously within a ring of members; that signature is classical, so a future quantum computer could in principle link a recorded vote to its signer. |
| Introductions | The friend who introduces you and the person you are introduced to. Your gate terms (free or a price, consent) go to your friends; if you turn on "Show my gates further", your friends pass those terms and your friend list on to their friends, up to two steps. A price for a first message from outside your friends is published on your pyramid price list (members only). Paid gates and first messages are pyramid payments: pyramid members who hold the record can see the pseudonyms of payer and payee, the amount, the time and a label saying that it was a gate or a first message (not the message). A payment is held until the one paid keeps or returns it (or the payer takes it back after a deadline). |

Anything you send can be copied, screenshotted, forwarded or kept by the
recipient. Ledger entries are **signed and append-only**: other devices may keep
a copy of a post or record even after you delete it on your side (section 10).

### 3.3 Data a stranger can see without being your friend

- Your **network address** (visible to anyone you connect to or who routes to
  you on Yggdrasil) and anything you made public.
- Strangers can send you data (friend requests, neighbour hellos, signals);
  Zen rate-limits and ignores most of it, and it does not answer pings from
  people who are not friends or group members.

## 4. Public Yggdrasil nodes and bridges

Zen has no servers of its own. To reach the mesh, the app connects to **public
Yggdrasil peers** (a list shipped inside the app, taken from the community list
at github.com/yggdrasil-network/public-peers), to devices found by local links (section 3.2, "Offline links": on the same Wi-Fi by
default, only friends' and your own devices are linked), and to "bridges" run by
Zen users. Desktop versions can accept
incoming connections (UPnP / NAT-PMP) and thereby act as a bridge for others.

What these operators can see:

- **Your IP address and your Yggdrasil node address** (and therefore your Zen
  address), when your device connects directly to them.
- Which other node addresses your traffic goes to and how much and when - not
  the content, which is end-to-end encrypted by Yggdrasil between your node
  and the destination node.
- Traffic you relay for other people also passes through *your* device if you
  run a desktop bridge (encrypted; you cannot read it).

Those operators are independent, may be anywhere in the world, and are not
controlled by the author. This is an unavoidable property of using a public
overlay network. Do not use Zen if you cannot accept that your IP address is
visible to them. (A VPN does not change that for Yggdrasil operators but hides
your real IP from them.)

## 5. Encryption - what it does and does not do

- Traffic between two Zen devices is encrypted end to end by Yggdrasil (session
  keys derived from the nodes' keys), and each hop is additionally protected.
  A peer's identity is checked: a packet is accepted only if it really comes
  from the sender's node address. Yggdrasil's own cryptography is classical,
  so Zen seals every signal once more with a hybrid post-quantum key
  (ML-KEM-768 + X25519), meant to keep recorded traffic unreadable by a future
  quantum computer.
- Mail held by a relay friend, and the locked-phone inbox, are sealed with the
  same kind of hybrid key, so the relay cannot read the mail or change who
  sent it. Audio and video frames of calls are encrypted end to end on top of
  WebRTC (keys from a hybrid exchange); they use AES-128-GCM, which is weaker
  against a quantum computer than the rest.
- What Zen signs and keeps (posts, records, releases) carries a hybrid
  Ed25519 + ML-DSA-65 signature. Still classical: the anonymous votes' ring
  signatures, event QR tickets, Bluetooth and Wi-Fi greetings and local-link
  handshakes, dating boxes, door knocks and the Yggdrasil node key. See
  SECURITY.md.
- Posts for limited audiences, dating packages and some other data have their
  own encryption layers.
- Metadata is not hidden from the other party or from network participants who
  see addresses and timing (see section 4).
- Zen cannot protect you from someone who has your unlocked device, your
  password, or who tricks you into installing a modified app.

## 6. Third party: klipy.com (GIF search)

GIF search is the **only feature that contacts a company's server** instead of
another Zen user.

- When you open the GIF picker or search, your device sends an HTTPS request
  to `api.klipy.com` containing: **the search text you typed** (or a request
  for "featured"), **your app language** (as a locale such as `pl_PL`), a
  shared application key embedded in Zen (or your own key, if you set one in
  Settings), a client name (`zen_messenger`) and, as with any web request,
  **your IP address** and the usual technical headers. Nothing from your
  conversations, contacts or account is sent.
- The GIF previews and the GIF you choose are downloaded from klipy.com by
  **your** device, so klipy.com sees your IP address and which GIF you picked.
  Zen then sends the chosen GIF to your friend as an ordinary image attachment
  (end-to-end encrypted like any other). **A friend who receives a GIF never
  contacts klipy.com**: nothing is fetched on their device, and the GIF passes
  through the same checks as other pictures (it must be a well-formed GIF within
  size, frame and dimension limits; it is not re-encoded, so it keeps moving).
- Klipy's own terms and privacy policy apply to what Klipy does with this
  data. The author has no control over it.
- **GIF search can be turned off** in Settings -> *GIF-y*. When it is off, Zen
  sends nothing to klipy.com and the GIF button disappears. GIFs from your
  phone's keyboard still work: most keyboards insert them as ordinary
  pictures, which Zen sends like any other image.

## 7. Other third parties

- **buycoffee.to (donations).** Zen shows a link to the voluntary fundraiser at
  https://buycoffee.to/zen. Opening it takes you out of the app into your
  browser; payments, payer data and cookies are handled by buycoffee.to and
  its payment partners under their own policies. Zen does not process payments
  and no payment data passes through the app. Donations are not required.
- **GitHub.** The app is distributed through GitHub Releases, and the
  invite web page (https://robertostrowskijagoda.github.io/Zen/) is hosted on
  GitHub Pages. GitHub sees ordinary web-visit data (IP address, user agent)
  when you download Zen or open that page, under GitHub's own policy. An invite
  code in a link is placed after `#` and is therefore not sent to the server by
  your browser. Zen itself (except the store build) asks GitHub's API for the
  latest release about 20 seconds after start and then at most once an hour
  (on Android also every few hours while the app is closed and receives in
  the background), fetches the short note about a newer version and its
  signature (`whats-new.json`, `SHA256SUMS.sig`), and downloads the release
  file (and its `SHA256SUMS`) when you press "Update"; GitHub then sees
  your IP address and the user agent "Zen" and which release file you
  fetched, nothing else (no account, token or device
  id). If GitHub cannot be reached, the app says so. Zen checks the downloaded
  file against the release's checksums (and, on Android, against its own
  signing certificate) before it installs it.
- **Links you tap** (the Yggdrasil site, the public-peers list, maps) open in
  your browser and are governed by those sites.
- **Operating system and stores.** Your phone vendor, the Android / iOS / Windows
  / macOS maker and, for iPhone, SideStore / AltStore and Apple, may collect
  data about installing and running apps. That is outside Zen.
- **Phone permissions.** Zen asks for location (alarms, date safety, the
  "Passed by" place; optional, also in the background if you allow it), Bluetooth
  and nearby Wi-Fi devices (people nearby and offline links, optional), camera and
  microphone (calls, QR scan, recordings), notifications, and a few system
  permissions (foreground service, full-screen alarm, battery optimisation,
  installing updates from "Pass it on" and the self-update). The data is
  used on the device and sent only as described above. Older Android versions
  require the location permission for Wi-Fi Direct (a system rule).

## 8. What Zen does *not* do

- No analytics, telemetry, advertising IDs, crash-reporting services or A/B
  testing. There is no code that reports usage to the author.
- No selling, renting or sharing of data by the author - the author has none.
- No profiling or recommendation algorithm.
- No reading of your address book, photos or files except what you pick.

## 9. Legal bases and special categories (EU / UK GDPR)

Because the author does not process your data on any server, most processing is
done by **you and your devices** (for example, a private household use). To the
extent GDPR applies to the author's activity, the intended bases are:
performance of the service you request (art. 6(1)(b)) and legitimate interest
in providing a secure messaging tool (art. 6(1)(f)).

Two parts of Zen touch **special categories of data** (art. 9):

- **Pyramid** (opinions, votes, who you delegate trust to) can reveal political
  opinions.
- **Dating** (gender, whom you are interested in, photos, preferences) can
  reveal sexual life or orientation.

Both are **off until you choose to use them**, and you give **explicit consent**
for each by creating a dating profile or joining a pyramid. You can withdraw
consent at any time by leaving the pyramid or turning dating off and deleting
the profile (copies already received by others, and signed pyramid records,
may remain - see section 10). Do not put other people's special-category data
into these features without their consent.

## 10. Your rights, retention and deleting your data

Because the data is on devices, **you control the copy on your device**, and
you can exercise most rights yourself:

- **Access / copy:** it is on your device; features let you export files.
- **Rectification:** edit your profile and posts; profile changes are sent to
  friends as updates. Edits to posts are new signed entries.
- **Erasure on your device:** Settings -> *Remove this account from this device* ->
  *Hold to delete all accounts* wipes keys first, then the files, settings, caches and Zen's
  exported files, and restarts clean. The **panic password** does the same on
  demand. Uninstalling the app removes its data on most systems (platform
  backups are managed by your OS). "Remove from my device" removes
  reported media from your phone.
- **Deleting what others hold:** Zen sends friends a delete / removal signal
  where the feature has one (for example removing a friendship, disappearing
  messages with a timer, deleting a post or gallery item), and well-behaved
  apps honour it. **No one - including the author - can force another person's
  device to delete a copy.** Signed ledger entries, pyramid records and copies
  held by friends or relay friends can remain (relay copies expire after 14
  days at most).
- **Restriction / objection / portability:** use the controls in the app
  (visibility, hiding, blocking, leaving groups and pyramids, turning
  features off).
- **Complaints:** if you are in the EU / EEA you may complain to your data
  protection authority (in Poland: the President of the Personal Data
  Protection Office, UODO). In the UK: the ICO.

Retention is set by you and by feature timers. The author keeps no personal
data about Zen users. The GitHub repository keeps whatever you post there
(issues, comments) under GitHub's rules - **do not post private data in public
issues.**

If you want to ask the author something about this policy or about personal
data on the GitHub page, use section 13. The author cannot look up "your"
account because none exists.

## 11. Children and age limits

- **Zen has no age gate.** It does not check anyone's age, and it does not
  ask for it, with one exception: the **Pyramid** asks for your birth year when
  you join, accepts members of any age, and shows the age in your pyramid
  profile to the other members, confirmed by the person who admitted you
  (section 3.2). What you type is not checked against any document, and the
  author cannot verify age or parental consent; that is the responsibility of
  users and parents.
- **Dating and the wallet never ask about age**, and dating lanterns carry no
  age. The terms say that dating is meant for adults, but the app does not
  check it. If you see someone who is clearly a minor in the dating feature,
  use "report an underage person" (it hides the profile on your phone at once),
  block them and tell a trusted adult; you can report illegal content as
  described in docs/TERMS.md.
- Zen is not designed for or marketed to children. If you believe a child is
  using the app in a harmful way, tell the child's parents or the authorities;
  the author has no way to identify or contact users.

## 12. Security and incidents

Zen uses modern cryptography and the project is open to inspection (see
SECURITY.md for how to report a vulnerability privately). No software is
perfectly secure. Because the author holds no user data there is nothing for
the author to leak, but a flaw in the app could expose data on your device or
in transit. If a significant security problem is found, the author will publish a
fix and a notice in the GitHub Releases / repository.

## 13. Contact

- Privacy questions and general requests: open an issue at
  https://github.com/robertostrowskijagoda/Zen/issues (do not include private
  data), and ask for a way to continue privately if needed.
- Security vulnerabilities: do **not** open a public issue; use the private
  report form described in `SECURITY.md`
  (https://github.com/robertostrowskijagoda/Zen/security/advisories/new).

## 14. Changes

This policy may change when Zen changes. The current version is in the
repository at docs/PRIVACY.md and linked from the app's About screen;
the history is in the repository's change log. A new version applies from the
Zen release that links to it.
