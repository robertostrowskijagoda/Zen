# Friends and the graph

> Who you know, how close you are, and how your groups of friends connect: drawn from
> what your friends chose to show you, computed on your own phone.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../images/graph-dark.png">
    <img src="../images/graph-light.png" width="280" alt="The friend graph">
  </picture>
</p>

## Friendship levels

Every friend has a level that only you see:

| Level | Sees your friend list* | Sees your statuses | May invite you to groups* | Gets your alarm |
|---|---|---|---|---|
| Casual friend | no (can ask) | only "Do not disturb" | no | only if you have no close friends |
| Friend | yes | yes | yes | only if you have no close friends |
| Close friend | yes | yes | yes | yes |

\* These are the defaults. *Who sees my friend list* can be narrowed to
close friends (others can ask, and you agree in your inbox);
*Who can invite me to groups* can be anyone, all friends, friends and close
friends, or close friends only.

Profile fields (status, About me, photo, nationality, counts…) each have
their own audience: public, all friends, friends and close friends, close
friends, or only me.

When you meet a friend in person, Zen can ask **Met?**. Both of you confirm
on your own phones and sign a small "met in person" note that your friends
see. It feeds the *Met in person* mode and the trust map below.

## The graph

The **Graph** tab draws you, your friends and the friends of friends who
show you their lists. People further away appear in an outer ring when
something brings them in: gatekeepers your friends passed on, or people
open to meeting (with their consent, up to three steps).

Modes (chips above the graph):

| Mode | What it shows |
|---|---|
| Friends | who knows whom; groups of friends are found and named automatically |
| Statuses | who is online, statuses, who is open to meeting |
| Met in person | the "met" notes, closeness as line styles |
| Pyramid | your pyramid's line and levels |
| Gates | prices on the lines for introductions ([gates](introductions-and-gates.md)) |
| Path | the shortest or cheapest way to a person |
| Timeline | how your graph grew, from the earliest day this phone knows about to today (see below) |
| Bridges | friends who alone connect two of your groups of friends, and groups with no link; Zen suggests introducing two people |
| Long ago | friends you have not talked to or met for 4, 8, 12 or 26 weeks, with a gentle *Message* or *Remind me later* |

Also on the graph:

- **Who's worth meeting**: friends of friends with several mutual friends,
  or the same status or intention as you. One tap asks the closest mutual
  friend to introduce you.
- **Trust map** on a person's card: when you met in person, which friends
  met them, thank-you cards, time in the pyramid, shared events. No stars,
  no scores.
- **Your groups of friends**: give a group your own name ("Climbing", "Uni"). The
  name never leaves the phone.
- **Graph snapshot**: a 1080 x 1080 picture with initials and group
  colours only, no names or addresses, to save or send.
- **How the graph grew**: the *Timeline* mode, or the clock button next to
  the zoom buttons in any other mode (the mode keeps its colours). Play
  shows friends and friends of friends appearing on the day they came, with
  their lines fading in; pause, drag the slider to any day (the date and
  how many friends and meetings there were then are under it), and switch
  the speed between 1×, 2× and 4×. A friend comes on the earliest day this
  phone knows: the friendship, your first message, or the start of a group
  you are both in. A friend of a friend comes when you first saw them, and
  never before the friend who connects you. With animations off (Settings →
  App → Appearance → Animations), it steps from one such day to the next
  instead of gliding. People not there yet on the chosen day cannot be
  tapped and are not read out by a screen reader.
- **Full screen**: the button next to the zoom buttons, F11 on a computer
  (Esc leaves). The controls fade after 3 seconds and come back on a touch.
  Mode, filters and the selected person carry over.
- Filters: everyone / friends and close friends / close friends, by group of friends,
  number of mutual friends, nationality, status, nearby.

## Adding a friend of a friend

On a friend of a friend, **Add friend** sends a request through a mutual
friend. Their phone passes it on by itself; the other person accepts or
not. After a yes, both phones exchange an ordinary friend invitation (the
same keys and levels as with a QR code). You never learn about a refusal.
People further away (no mutual friend) get the invitation straight to their
address.

Limits: 10 such invitations a week from you; a go-between passes at most 5
a week from one person and 30 in total; a recipient takes 10 a day through
one friend.

## Privacy

- The graph is built only from lists your friends chose to show you. Zen
  has no central friend graph.
- Dates for the timeline are kept on this phone from now on; older ones are
  taken from your conversations and "met" notes. Friends from before are
  shown as "always".
- *Long ago*, *Your groups of friends* and the snapshot are visible only to you.

## Limits

- Friends of friends appear only once your friends show you their lists.
- Friends from before the timeline started are shown as "always" there.

[Back to the guide](README.md)
