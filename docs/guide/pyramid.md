# The pyramid

> A way to decide shared matters without a headquarters: small cells of
> people who know each other in person, stacked into one tree. Trust, votes
> and a common purse flow from the bottom up, and every change is a signed,
> public record.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../images/pyramid-dark.png">
    <img src="../images/pyramid-light.png" width="250" alt="The pyramid, the Me tab">
  </picture>
  &nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../images/pyramid-tree-dark.png">
    <img src="../images/pyramid-tree-light.png" width="250" alt="The pyramid tree today">
  </picture>
</p>

## What it is

There is **one** original pyramid. Its first record (the genesis) is pinned
in the app, so nobody can start a rival "official" one. Every member's phone
keeps all its records and computes the same state from them, by the same
rules, in the same order. A record that breaks a rule is rejected
everywhere alike. There is no server that could be bribed or shut down.

## Cells and places

<p align="center">
  <img src="../images/pyramid-cells.svg" width="760" alt="A tree of cells of three; promotion is a swap with the head of your cell">
</p>

- Every place has a **head** above it and two places below. A head and the
  two people under them form a **cell** of three. Most people sit in two
  cells: under their head, and as the head of their own.
- The **top** is the cell at the very top: three people who decide together,
  2 of 3.
- Every cell has its own group chat, made automatically.

## Joining

1. Any member can bring someone in with a **referral**, to a free place in
   their own branch. The newcomer must be at least a *friend* (not a casual
   friend) of the member.
2. The newcomer gives a pseudonym, nationality, birth year (minors are
   accepted) and gender (kept only as a hash unless they choose to show it).
3. The member who referred them, the newcomer, and the head of the chosen
   cell sign.
4. The newcomer **votes** after 14 days, or as soon as a voting member of
   their cells confirms "we've met".

## Moving up, step by step

Every move up is **exactly one level**, and that level must agree:

- a **swap** with the head of your cell, signed by 2 of the 3 in the cell
  (or a won cell vote, below);
- taking a free place directly above you;
- moving to a cell one level higher, with the consent of its head.

After any rise the next one is possible after **7 days** at the earliest.
Nobody falls out: the head simply takes your old place. Moving to another
cell is allowed to the same level, lower, or one level up; with your whole
branch, only to the same level or lower. Someone who left, was removed or
was declared absent comes back at most to the level they left.

## Cell votes

Anyone with a vote in a cell can ask, anonymously, for a vote on who should
be the head.

- The **request** carries a ring signature: it proves that someone in the
  cell asked, not who.
- Each member's phone then makes a **one-time voting card** (a fresh hybrid
  key) and sends it to the other members only. The list of cards (the
  ballot) is signed by the members; it counts only when there are at least
  as many signatures as cards, so nobody can hold two cards.
- Each card votes once. **Two votes for the same person** make them the
  head (a swap); otherwise the head stays.
- A vote cast before the ballot is ready waits on your phone and goes out
  by itself. If someone stays silent, after a third of the voting time the
  cards of two people are enough.

## Referendums

Only the top (2 of 3) calls a referendum: a question with 2 to 6 options,
for the whole pyramid, one branch or one nationality. It is **advisory**.
Your vote goes only to the head of your cell; every head signs the total of
their branch, and the totals are checked against the size of each branch.

## Rules and their hard limits

The top (2 of 3) can change the rules. A change is public at once and applies
24 hours later, never outside the limits built into the app:

| Rule | Allowed range |
|---|---|
| Absence before a place can be declared free | 30 to 3650 days |
| Immunity (the top levels need their own cell's consent for bans) | 1 to 30 levels |
| Treasurers (everyone on the top levels) | 3 to 6 levels, at least 15 people |
| Cell vote duration | 24 to 720 hours |
| Report escalation to the next level | 24 to 720 hours |
| Issuance waiting time (veto window) | 24 to 720 hours |

**The issuance limit** (how many points may be created in 30 days) has its
own, stricter path:

- **Lower** (or a longer wait): applies at once. You confirm by holding the
  button for 2 seconds.
- **Higher** (or a shorter wait): it is **announced** to every member at
  once, pinned on the feed, on the *Me* tab and at the top of the wallet,
  and applies only **30 days later**. Until then the top can cancel it. Only
  one such change can wait at a time.

## The wallet

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../images/wallet-dark.png">
    <img src="../images/wallet-light.png" width="260" alt="The wallet">
  </picture>
</p>

- Points live in the pyramid. Your balance is computed from signed records
  by every member's phone, so a changed app on one phone cannot create
  money.
- A transfer counts when a **majority of the treasurers** sign it. A
  treasurer signs only an order that is covered, recent and has the next
  number; signing two orders with one number is public proof of cheating.
- **Issuance:** the top (2 of 3) creates points for an account, with a
  reason, within the 30-day limit. It waits (24 hours by default), during
  which the third member of the top can veto it.
- Escrow payments, used by [gates](introductions-and-gates.md): the money is
  set aside and released by a condition, or returned after a deadline.
- After recovering your account (recovery circle, paper backup or key file)
  your place, level and balance come back from the records your friends
  keep.

## Reports, the court and appeals

<p align="center">
  <img src="../images/pyramid-appeals.svg" width="760" alt="An appeal goes one level above whoever decided, with the time doubling at every level">
</p>

- **Reports** (on a post, comment, profile, message, dating profile) go to
  the narrowest branch around the reporter first and climb a level at a time
  when nobody decides. A decision can ban: permanently, for 24 hours / 7 days
  / 30 days, one piece of content, from dating, or from admitting people. A
  ban never takes away anyone's place or vote. Only your own cell can remove
  you from the pyramid (the head above you and the other member, both).
- **The court.** Any member can file a complaint against another (a fraud
  warning, *don't lend this person money*, *be careful*, other), up to 3 open
  at a time. The head of the defendant's cell decides within 3 days: a
  verdict (with an optional expiry) or a dismissal with reasons. A verdict is
  a warning that everyone sees on the person's profile in Zen, members and
  non-members alike; the person cannot hide it.
- **Appeals** go one level above whoever decided (from the top: to the top
  again). Refused or unanswered in time, you may go up again, all the way to
  the top, whose refusal is final. The time to answer doubles at each level:
  3, 6, 12, 24 days. Accepted at any level, the decision is undone: a ban is
  lifted, a removed person returns to their place (or the nearest free one in
  their former head's branch), a verdict is quashed. The parties never judge
  their own case. Your cases are under *Decisions about you* on the *Me* tab;
  judges see *To review*.

## National sections and the feed

- Each nationality has a section, led by its highest-placed member. The
  leader pins posts and gives others priority.
- Members write posts to their branch. On the feed: posts of the top, of
  your line upwards, your own, and (under *Country*) your nationality's
  section, ordered like the pyramid itself: pinned, then higher authors
  first.
- People outside the pyramid can read the top's posts and their
  nationality's section when member friends pass them on.

## History

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../images/pyramid-history-dark.png">
    <img src="../images/pyramid-history-light.png" width="260" alt="Places over time: the animated history">
  </picture>
</p>

**History → Places over time** replays the tree from the founding to today:
a slider, play and pause, speeds ½× to 4×. People move between places as
they join, rise, swap with their heads, leave or are removed. Tap people to
highlight them; you are always highlighted. Below the tree: the current step
("Gus swapped places with Chris") and the last five. Large trees show the
top three levels and the part around you and the people you picked. Under it,
*All changes* lists every signed record.

## Privacy

| Public to every member | Private |
|---|---|
| pseudonym, place, level, nationality, birth year, who admitted whom | gender (a hash, unless shown) |
| posts and comments in branches | your referendum vote (only your head knows it) |
| transfers with amounts and titles, issuances, vetoes | the content of reports, at their recipients |
| bans with reasons, verdicts, appeals and answers | branch statistics (only from 5 people up) |
| cell vote results (not who voted for whom) | gate conditions |

Records travel only between friends who are members (or follow the
pyramid).

## Limits

- Until the original genesis is pinned in a release, a release build shows
  that the pyramid has not started; development builds use a test pyramid.
- Transfers are **not private** to members: amounts and parties are in the
  records (hiding them would need heavy zero-knowledge cryptography; not
  done).
- The anonymous vote request is classical (a ring signature): a future
  quantum computer could forge a request (a nuisance, not a result) or tell
  later who asked. The votes themselves are post-quantum. See the
  [security model](../SECURITY_MODEL.md).
- Readers outside the pyramid trust their member friends that a verdict or
  post came from the right person; they cannot check the records.
- The top's power key and voting cards are not part of account recovery:
  a recovered head gets the place back, and the power key passes the usual
  way (the top cell's consent after 72 hours).

[Back to the guide](README.md)
