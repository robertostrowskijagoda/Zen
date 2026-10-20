<!--
MAINTAINER NOTE (remove before publishing if you like):
This is not legal advice; review with a lawyer. It is a plain-language draft
written from how the code works in version 1.10.0 (20.10.2026). It makes no
promise the app cannot keep: the author runs no servers and cannot see,
change or delete what is on other people's devices. Points that most need a
lawyer's eye: (1) whether the author counts as a "controller" or "joint
controller" under the GDPR for an app that has no operator-side data at all;
(2) special-category data (political opinions in the pyramid, sexual life and
orientation in dating) and the explicit-consent wording; (3) the minimum age
(16 is used here because the plan, docs/PLAN.md section 27, says
"parental consent below 16" and 16 is the Polish age of digital consent;
other EU states set 13-16); (4) the klipy.com paragraph - check Klipy's own
terms and privacy policy before every release; (5) the contact route (no
e-mail address is published yet - only GitHub). Keep this file, docs/TERMS.md
and docs/DPIA.md in step with the code (see docs/PROTOCOL.md for what goes
over the wire).
-->

# Zen - Privacy Policy

*Version for Zen 1.10.0 - last updated 20 October 2026.*
*The app's primary language is Polish; this document is in English. If a
translation differs, ask on GitHub.*

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
  pyramids you join receive the content you share with them, and their copies
  are outside your control and the author's control.
- **Network helpers see addresses, not content.** Zen runs on the Yggdrasil
  network. The nodes that carry your traffic can see your IP address and your
  network address, but not what you write.
- **One third party is built in:** the GIF search uses klipy.com (section 6).
- **No analytics, no advertising, no trackers.** Crash and diagnostic logs stay
  on your device.

## 2. Who is responsible

Zen is made by **Robert Ostrowski-Jagoda**, an individual developer
(see the `LICENSE` file; project page: https://github.com/robertostrowskijagoda/Zen).

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
- **Features data:** statuses ("na teraz"), events, alarms (including location
  and recorded sound, if you use them), neighbours (flats), dating profile and
  decisions, pyramid records and balances, and the ledger of signed entries.
- **Settings, the lock password hash parameters, the panic password** and
  similar.
- **Diagnostic log:** a rolling text file (`zen-diagnostics.log`, trimmed to
  about 128 KB) with technical messages. Folder paths are shortened in it.
  You can read it in Settings. It is **never sent anywhere automatically**. If
  you copy or send it to someone (for example when reporting a bug), that is
  your choice - check it first.

Almost everything above is stored encrypted (AES-256-GCM, with a master key
protected by a key derived from your password with Argon2id and, where
available, by hardware-backed storage). **Exceptions:** your own avatar and
profile background are kept as plain files (documented limitation), and media
you export or save on purpose is saved as an ordinary file.

### 3.2 What other people receive

When you use a feature, the people involved receive the data that feature needs.
Everything below is sent device to device over the Yggdrasil network.

| You do this | Who receives what |
|---|---|
| Send a friend request | The other person: your Zen address, display name and the note you wrote. |
| Be a friend | Friends can see your profile (name, status, bio, avatar), when you are online / in the foreground (presence pings every ~45 s while the app runs), your current status ("na teraz") if its audience allows it, and - depending on your setting - your friend list. Your "closeness level" for a friend is private; they never learn it. |
| Chat | The recipient: message text, attachments, timestamps, typing indicator, delivery and read receipts, disappearing-message timers. |
| Groups | Every member (up to 256) gets each message. Members learn the group's member list. |
| Calls | The other participants: call signalling and the media stream (WebRTC). Participants learn your network address and, through WebRTC, network details needed to connect. |
| Post on your board | The ledger replicates your post to the devices of the chosen audience. Posts with the audience "Wszyscy znajomi", "Znajomi i przyjaciele" or "Tylko przyjaciele" are encrypted so only friends of a high enough level can read them; **public posts and public profile fields can be read by anyone who obtains them**, including people who follow you and anyone they were passed on to. The existence, time and size of entries and your account key are visible to anyone who holds the entry, even for encrypted posts. |
| Offline mailboxes | Up to six friends you pick (or the app picks) hold **encrypted** copies of mail addressed to you for up to 14 days, only for messages up to 48 KB. They see who it is from and to, size and time, not the content. |
| Alarm | The friends chosen for alarms: your location (if allowed), a note, recorded sound, and delivery confirmations. Phones nearby may receive a signed Bluetooth "wave" (alarm id and time; only friends can tell whose it is). Tapping a map link opens openstreetmap.org in your browser with the coordinates. |
| "People nearby" (Android) | If you turn it on, your phone advertises a token over Bluetooth that changes every 15 minutes; only friends can tell it is you. Anyone nearby can see that *a* Zen phone is there and its approximate signal strength. If you "wave", the person gets your pseudonym, your short text and your mesh address - not your account. |
| Neighbours | Flat or building members you join: what you choose to reveal in that feature. |
| Dating (18+) | Small "lanterns" (your dating key, age, gender and preferences, the same shape whether or not you date) are passed up to two hops through friends' phones; your profile itself is sent sealed only to a person whose lantern fits yours and who asks for it, so the phones on the way cannot read it. People who can read your profile see what you put in it. Your "Yes" is sent only as an unlinkable token; "No" sends nothing. |
| Pyramid | Members of the pyramids you join receive the signed records you create (votes, proposals, posts, payments, reports). Some votes and requests are signed anonymously within a ring of members. |
| Introductions | The friend who introduces you and the person you are introduced to. |

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
at github.com/yggdrasil-network/public-peers), to nodes found by local-network
discovery (off by default; if you turn it on, other devices on your Wi-Fi can
see you), and to "bridges" run by Zen users. Desktop versions can accept
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
  from the sender's node address.
- Mail held by a relay friend is sealed again for the recipient so the relay
  cannot read it or change who sent it.
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
  data. The author has no control over it. **If you do not want this, do not
  use GIFs.**

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
  your browser. Zen itself does not contact GitHub in the background (network
  self-update is not active in 1.10.0).
- **Links you tap** (the Yggdrasil site, the public-peers list, maps) open in
  your browser and are governed by those sites.
- **Operating system and stores.** Your phone vendor, the Android / iOS / Windows
  / macOS maker and, for iPhone, SideStore / AltStore and Apple, may collect
  data about installing and running apps. That is outside Zen.
- **Phone permissions.** Zen asks for location (alarms, optional), Bluetooth
  (nearby, optional), camera and microphone (calls, QR scan, recordings),
  notifications, and a few system permissions (foreground service, full-screen
  alarm, battery optimisation, installing updates from "Podaj dalej"). The data
  is used on the device and sent only as described above.

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
- **Erasure on your device:** Settings -> *Usuń wszystkie dane* ("Delete all
  data") wipes keys first, then the files, settings, caches and Zen's
  exported files, and restarts clean. The **panic password** does the same on
  demand. Uninstalling the app removes its data on most systems (platform
  backups are managed by your OS). "Usuń z mojego urządzenia" removes
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

- **Minimum age for Zen: 16.** If you are under 16 (or under the age of digital
  consent in your country, which can be 13-16), you may use Zen only with a
  parent's or guardian's permission, and the author recommends you do not use
  it. Zen does not ask for your age (except an optional birth year in the
  pyramid) and cannot verify age or consent; it is the responsibility of users
  and parents.
- **Dating: 18+ only.** The dating profile requires an age of at least 18
  (what you type, no documents are checked; there is no separate age question).
  Do not use dating if you are under 18. If you see someone who is clearly a minor in the dating feature,
  report and block them and tell a trusted adult; you can report illegal
  content as described in docs/TERMS.md.
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
repository at docs/PRIVACY.md and linked from the app's "O aplikacji" screen;
the history is in the repository's change log. A new version applies from the
Zen release that links to it.
