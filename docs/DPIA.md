<!--
MAINTAINER NOTE: This is not legal advice; review with a lawyer. This is a DRAFT
data protection impact assessment (GDPR art. 35) for Zen 1.10.0, written
20.10.2026 from the code and docs/STATUS.md. It has not been reviewed by a data
protection officer or a lawyer and not been consulted with any authority. Open
question for the lawyer: whether the author is a controller at all for a purely
peer-to-peer app with no author-side processing, and whether art. 35 even applies;
the draft assumes "yes, to be careful", because dating and political-opinion
features process special-category data.
-->

# Zen - Data Protection Impact Assessment (draft)

*Draft v0.1 for Zen 1.10.0 - 20 October 2026. Companion to
[PRIVACY.md](PRIVACY.md) and [PROTOCOL.md](PROTOCOL.md).*

## 1. Why an assessment

Zen combines features that individually or together could present a high risk
to individuals: processing of special-category data (political opinions in the
"pyramid"; sex life / orientation in dating), location sharing for alarms,
profiling-like graph features (friends of friends), a large-scale peer network
and possible use by minors. The author is an individual developer who runs no
servers; this assessment is meant to show the risks have been thought through
and to guide design decisions.

## 2. Description of the processing

**Nature.** A peer-to-peer messenger and community app (Flutter app + Go
Yggdrasil bridge) for Android, iOS (sideloaded), Windows, Linux and macOS.

**Who processes what.** All content is processed on users' devices. There is no
author-operated server, no accounts, no telemetry. Data moves device to device
over the Yggdrasil overlay network (end-to-end encrypted between nodes). Friends
may hold sealed copies of mail for 14 days; ledger entries are replicated to
the audience they are meant for.

**Data subjects.** Users, their contacts, people mentioned or pictured in
content, members of groups / pyramids / neighbour buildings, dating candidates,
and strangers whose network addresses are seen.

**Categories of data.** Network address / IP address; display name, bio,
avatar, photos, videos, voice; messages and files; friend graph and closeness
levels; presence (online state); status and event / plan data; alarm data
including precise location and sound; dating profile (age, gender, preferences,
photos, texts, decisions); pyramid records (votes, delegation, reports, points
balances); device and diagnostic logs (local only).

**Special categories (art. 9).** Political opinions (pyramid votes, delegation,
reports, referendums), sex life / orientation (dating preferences), possibly
health or religion if users write it. Data about minors if a minor uses the app.

**Scale.** Unknown; the app is distributed outside stores via GitHub, so numbers
are expected to start small and grow gradually.

**Third parties.** Public Yggdrasil node operators (see IP and node address
only); klipy.com for GIF search (search text, locale, IP); buycoffee.to for
voluntary donations (link in browser only); GitHub (downloads, invite page).

## 3. Necessity and proportionality

- **Purpose** is to let people who know each other communicate and organise
  without an intermediary. Each feature needs only what it shows: for example,
  the nearby token rotates every 15 minutes, dating packages are sealed and
  padded so passing phones cannot read them.
- **Data minimisation:** no accounts, phone numbers or e-mail; no central
  database; no analytics; diagnostic logs stay on device and are size-limited.
- **Storage limitation:** relay mail expires after at most 14 days; disappearing
  messages; user-driven deletion; wipe of all data with key destruction.
- **Lawfulness:** consent for special-category features (explicit action to enable
  dating or join a pyramid); contract / legitimate interest for the core
  messenger as chosen by the user.
- **Transparency:** privacy policy linked in the app; honest limitations
  listed (metadata, IP exposure, Klipy, copies at friends).
- **Data subject rights:** exercised mostly on the device; limits for copies held
  by others are stated. See PRIVACY.md section 10.
- **Processors / transfers:** none engaged by the author. Third-party flows are
  user-initiated; Yggdrasil nodes are worldwide, so an IP address can reach
  non-EU operators.

## 4. Risks and measures

Likelihood (L) and severity (S): low / medium / high, before measures ->
residual after measures.

| # | Risk to individuals | L / S | Existing measures | Residual |
|---|---|---|---|---|
| 1 | Seizure or theft of a device exposes messages and contacts | M / H | Data encrypted with a master key (AES-256-GCM) from a password (Argon2id) and hardware key store; auto-lock after 5 min in background; screenshot block; panic password; wipe with key destruction; root warning | Medium (own avatar and profile background are not encrypted; a weak password is weak) |
| 2 | Network operators or observers learn who talks to whom (IP, node address, timing) | H / M | Content encrypted end to end by Yggdrasil; no author server; friends-only presence replies; stated openly in the policy | Medium - metadata is not hidden; users who need anonymity must use other tools |
| 3 | Public posts and profile fields are visible to everyone who obtains them | M / M | Audience choices per post; encrypted audiences for friends levels; defaults to "Wszyscy znajomi" | Low-Medium; entries stay on other devices after deletion |
| 4 | Special-category data (dating, politics) is exposed or inferred | M / H | Dating packages sealed, padded to size buckets, flooded through friends' phones that cannot read them; "Yes" is an unlinkable token; hiding lists; pyramid votes use ring signatures; features opt-in with explicit consent; pseudonyms | Medium - a modified app in range can read profiles of people in range; pyramid membership of signed records is visible to members |
| 5 | Precise location leaks in alarms or the safety feature | M / H | Only to selected friends; false-alarm / duress PIN; map opens only on user tap; Bluetooth waves carry no location | Low-Medium; recipients can keep or forward it |
| 6 | Minors use the app, or are contacted via dating / neighbours | M / H | Dating requires declared age 18+; stated minimum age 16; report, block and hide tools; contact only via friend graph or invitations | Medium - no age verification is possible without a server or documents |
| 7 | Harassment, abuse, illegal content with no central moderator | M / H | Block, hide, leave, report; "Usuń z mojego urządzenia"; community moderation in pyramids; strangers rate-limited and ignored | Medium - the author cannot remove content from others' devices |
| 8 | Third-party exposure through GIFs (klipy.com sees IP, search terms, which GIF) | H / L | Single, disclosed third party; only klipy.com links accepted (https, no IP literals); GIFs optional; user's own key option | Low - disclosed, optional |
| 9 | Malicious or malformed input from the mesh (denial of service, injection) | M / M | Size limits (2 MB signals, 64 KB ledger entries), zstd bomb limit, per-network rate limits, bounded buffers, media re-encoding, signature checks | Low-Medium |
| 10 | Impersonation, forged messages or a relay re-attributing mail | L-M / M | Mesh source addresses authenticated; relay envelopes sealed and bound to sender, recipient and id; signed ledger entries and device certificates; revocation | Low |
| 11 | Counterfeit builds / compromised release | M / H | Single signing key; signature check in "Podaj dalej"; open source; reproducible plan | Medium - release signing is a single point of trust (STAN D2, D11) |
| 12 | Loss of data (no recovery) | M / M | Recovery circle of up to 6 friends; multi-device accounts | Medium - by design, no server backup |
| 13 | Someone else's data in your content (photos of third parties) | M / M | Terms forbid it; no automatic sharing of contacts | Medium - user responsibility |
| 14 | Retention beyond what the subject wants (signed append-only logs) | H / M | Documented limitation; public/limited audiences; deletion markers; local hide | Medium - inherent to a signed ledger |

## 5. Measures still to do (suggested)

- Lawyer review of PRIVACY.md and TERMS.md and of the controller / joint
  controller question.
- Consider encrypting the own avatar and background (STAN section 1).
- Decide a durable private contact route for privacy requests and law-enforcement
  letters (a dedicated mailbox or a foundation).
- Re-check Klipy's terms and privacy policy for each release; document any
  change in PRIVACY.md.
- Decide whether to add friction for dating (extra age warning) and a fast
  report-a-minor path.
- Consider an in-app privacy summary on first run (not only in About).
- Review this DPIA when adding features that touch personal data or when the
  user base becomes large (art. 35(11)), or when store variants (Google Play,
  App Store) with their own data declarations are created.

## 6. Conclusions

The architecture removes the largest classic risk (a central database held by
a company) but leaves residual risks that cannot be removed technically:
metadata visible to network operators, copies held by other users, limited
ability to delete from other devices, no age verification and no central
moderation. With the measures above the remaining risk is judged **medium**,
acceptable only if users are told plainly (PRIVACY.md) and if special-category
features stay opt-in. No prior consultation with a supervisory authority
(art. 36) is proposed at this stage; to be reconsidered by the lawyer.

*Sign-off: pending (author / reviewer / date).*
