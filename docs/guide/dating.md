# Dating

> Meet new people through the people you know, up to three steps away. Your
> phone and theirs check privately whether you fit; nobody else learns it,
> not even the friends in between.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../images/dating-dark.png">
    <img src="../images/dating-light.png" width="280" alt="Dating">
  </picture>
</p>

## What it is

A dating profile, off by default and separate from your Zen account: a first
name, gender, *About me*, *What I'm looking for*, up to 4 photos, interests
and friends' recommendations. You choose an **intention**: dates, new friends
(no romance), or both, and whom you are looking for in each. There is no age
field.

## How it works

1. **Lanterns.** Once a week every phone (dating on or off, so nobody stands
   out) sends its friends a "lantern": nothing but a one-time key. Friends
   pass it on, up to **3 steps**, and also through open
   [gates](introductions-and-gates.md).
2. **A private test.** A phone that sees a lantern asks a sealed question.
   The answer tells only whether the two of you fit: both want the same kind
   of meeting and each is what the other is looking for. Neither side learns
   the other's wishes from a "no", and the friends in between see only
   sealed boxes of a fixed size.
3. **Cards.** Profiles that fit show up as cards: "You know each other
   through Celina", mutual friends, recommendations. **Yes** sends back a
   signed token; **No** sends nothing. Two yeses make a pair, and the pair
   can chat.
4. **Distance that can't be faked.** Every phone that passes an answer back
   adds one to a counter, so someone far away cannot pretend to be a friend
   of a friend.

**How far you want to see:** my friends / friends of friends / 3 steps /
further through open gates. It works both ways: people beyond your reach
don't see you either.

**Friends help.**

- **Ask for an opinion** goes only to someone who knows that person: a mutual
  friend, the friend on the way, or a matchmaker; never to the person.
- **Matchmaking:** pick two friends (or people from your Dating) and
  introduce them. Their phones run the same private test; you learn nothing.
- **Recommendations:** friends vouch for you (up to 50 on a profile), signed
  with their key.
- **Safe date:** in a pair, both can agree to see your mutual friends, to ask
  them about each other. **I'm going on a date** tells a friend where and
  when; they can ask for your location, and get an alarm if you don't check
  in.

**Hiding.** Hide your profile from chosen friends or whole group chats:
*only from them*, or *from them and their circle* (nobody who reaches you
only through that person sees you). Your phone refuses those questions
itself; the list of hidden people never travels in your profile.

## Privacy

- Your profile carries a separate dating key, not your account address.
- Profiles are signed (Ed25519 + ML-DSA-65) and answers have a fixed size,
  so a go-between can't tell a real profile from a "no".
- The boxes (answers, profiles, *Yes*, messages, matchmaking) are sealed with
  a fresh post-quantum key each (ML-KEM-768 + X25519).
- **Open to meeting people** on the graph is a separate opt-in, off by
  default, with an extra confirmation.
- **Report a minor** disables a profile on your phone at once and reports it
  to the pyramid; a phone that sees reports from two different people
  disables it too. Pyramid dating bans hide a profile as well.

## Limits

- The lantern itself, the first question of the test and the lantern proof
  are classical (X25519): see the [security model](../SECURITY_MODEL.md).
- A modified app of a hidden friend, using a new key and asking through a
  mutual friend, could get your profile under *only from them*; *from them
  and their circle* closes that route.
- A modified phone on the way can shorten the distance behind itself, not
  before itself.
- Dating is closed only when the whole app is locked; it asks for no extra
  password.

[Back to the guide](README.md)
