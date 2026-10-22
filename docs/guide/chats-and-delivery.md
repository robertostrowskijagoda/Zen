# Chats, delivery and calls

> Messages go straight from your device to your friend's. When your friend is
> offline, sealed copies wait with their trusted friends, or on your own
> device, until they come back.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../images/chat-dark.png">
    <img src="../images/chat-light.png" width="280" alt="A conversation with delivery icons under the messages">
  </picture>
</p>

## What you can do

- One-to-one chats and groups (the pyramid's cell chats too): text, photos,
  videos, files, voice notes and GIFs.
- **GIF files** picked from the gallery or from disk stay animated (up to
  8 MB, 2560 px a side and 400 frames); their comments and metadata are
  removed. A GIF that would not play can go as an ordinary file.
- On a computer, **drop** files anywhere on a conversation or **paste** them
  with Ctrl+V (⌘V on a Mac): photos, GIFs, videos, files. Text in the
  clipboard pastes as text, as usual.
- **Keyboard GIFs and stickers.** On Android, GIFs from the keyboard (for
  example Gboard or SwiftKey) arrive animated. iPhone keyboards copy a GIF
  to the clipboard instead: use **Paste image from clipboard** in the chat
  or in the attachment sheet.
- Long-press a message to **react**, **reply**, **edit**, **forward**,
  **delete for everyone**, copy it or report it.
- Groups have a **Board** tab with their own posts: text, a photo, or both.
- Audio and video calls, also in groups, with screen sharing.
- Filters in the chat list: all, unread, online, close friends.

## Reactions, replies, edits, forwarding

- **Reactions.** One per person per message. Tap the same emoji again to
  take it back; picking another one replaces it. Long-press the reactions
  under a message to see who reacted with what.
- **Replies** quote the original: who wrote it and the start of its text.
  Tap the quote to jump to the original. A reply to a disappearing message
  carries none of its text, so the quote shows only while the original is
  still there.
- **Editing.** Only your own text messages, within 24 hours of sending.
  The message is marked *edited*; the earlier text is not kept. Other
  devices take an edit only from the message's author, and only up to 25
  hours after it was sent (one hour of leeway for clocks).
- **Delete for everyone.** Your own messages; in a group, its creator may
  also delete anyone's message (a pyramid cell chat has no creator, so
  there only authors can). A *Message deleted* note stays in its place,
  replies lose the quoted words and the message's file is erased. Be
  aware: whoever already read it may remember it, and a modified app can
  ignore the deletion and keep a copy.
- **Forwarding** passes a text or a file to a friend or a group, marked
  *Forwarded*. Disappearing messages cannot be forwarded.

Reactions, edits and deletions travel like messages (queue, mailboxes) to
everyone in the chat and to your other devices, without notifications.
What a new device copies from your other devices, and the circle backup,
keep each message as it is now: edited, deleted (only the note), with its
reactions and reply.

## Files in groups

- Up to **64 KB** a file travels inside the group message itself, so it
  waits in each member's mailboxes like any message.
- Larger files, up to **24 MB**, are sealed once with a fresh key and kept
  as content-addressed blocks. The message carries only their reference
  (with the key); each member fetches the blocks from the sender or from
  any member who already has them, so your phone does not upload a copy
  per member. Until Zen's network is running, files up to 1 MB go inside
  the message instead.
- A file that has not arrived yet is asked for again when you open the
  chat. Every file is checked like in one-to-one chats: pictures are
  unpacked and saved again before they are shown.
- A photo on the **Board** is shared the same way: the post carries its
  reference, the members fetch the photo.

## How a message travels

<p align="center">
  <img src="../images/message-delivery.svg" width="760" alt="Three ways a message travels: direct, through mailboxes, from the sender's outbox">
</p>

1. **Your friend is online.** The message goes straight to their device,
   sealed end to end.
2. **Your friend is offline but has mailboxes.** Every device picks up to 6
   trusted friends who keep its mail. After 4 seconds without an answer, a
   sealed copy goes to those mailboxes; they hand it over when your friend
   is back. A mailbox sees only ciphertext.
3. **No mailbox can be reached.** The message waits in the outbox on your
   device and is tried again: after 3 s, 10 s, 30 s, 2 min, 10 min, 30 min,
   1 h, 2 h, 4 h, then every 4 hours, for up to 14 days. Any sign of life
   from your friend starts over at once, and so does a change of network.

Every message is written to disk before the first attempt, so nothing is
lost if the app or the phone stops in between. Duplicates (a direct copy and
a mailbox copy) are recognised and shown once.

## What the icons mean

Long-press a message to see its label; tap the icon for details, a legend
and **Retry**.

| Icon | Label | Meaning |
|---|---|---|
| clock | Sending… | the first direct attempt is under way |
| outbox | Waiting on your phone, recipient offline | only this device has a copy and keeps trying |
| mailbox | Waiting for pickup with the recipient's trusted friends (N) | N sealed copies wait in mailboxes |
| one tick | Sent | in the queue, nothing more is known yet |
| two ticks | Delivered | the recipient's device confirmed it |
| two ticks, coloured | Read | the recipient opened it (one-to-one chats) |
| warning | Failed, retry | it expired unconfirmed; **Retry** sends it again under the same id |
| outbox | Waiting on your phone, will go when you are both online | a large file the mailboxes cannot take |

In groups the icon follows the furthest-behind member and the label says
*Delivered {d} of {n}*. **Retry** in a group goes only to those who did not
confirm.

## Calls

A call is set up over the same encrypted channel as messages. Its audio,
video and shared screen are protected three times:

- **frame encryption** (AES-128-GCM) with keys from a fresh post-quantum
  exchange for this call, rotated every 5 minutes and whenever someone joins
  or leaves a group call;
- WebRTC's own **DTLS-SRTP**;
- every packet travels through Zen's relay over the mesh and is sealed
  again with a **256-bit post-quantum** key of the two devices.

The call screen says which protection a call has. In a group call every
participant has a separate connection to every other.

When you share your screen, notifications are shown without content and a
red bar reminds you that everything is visible. When a call is recorded,
everyone hears a signal.

## Privacy

- Nobody but the two (or the group) can read a message: not the mesh, not
  the mailboxes, not the public peers. See the
  [security model](../SECURITY_MODEL.md).
- Photos from others are unpacked and saved again before they are shown, so
  a "poisoned" image never reaches the system. Zen never opens files by
  itself and warns before saving a program.
- **GIF search** uses an outside company, KLIPY: it sees what you type in
  the GIF search, the GIF you pick and your IP address. The GIF then goes
  to your friend as an ordinary encrypted picture; the friend's device never
  contacts KLIPY.
  **Settings → Messages and calls → GIFs → GIF search** turns it off: the
  GIF button disappears and nothing goes to KLIPY. GIFs from your keyboard
  and GIF files are sent like photos and keep working.
- Pasted and dropped photos are saved again as a fresh JPEG without
  metadata, the same as photos picked in the app.
- A friend's name comes from their own profile; your nickname for them is
  shown under it.

## Limits

- While Zen is locked (Android), messages still waiting go out from a
  sealed copy of the queue prepared while it was unlocked (up to 300
  messages, 4 MB). What can only go directly waits until you unlock.
- A file over 1 MB to a friend whose mailboxes do not take files waits on
  your device until both of you are online.
- A group file sent as blocks arrives only while the sender or another
  member who has it is online.
- Only text messages can be edited; a Board post may have one photo.
- Comments take no pictures. Events, food sharing and neighbours take
  small still pictures only: a GIF there keeps its first frame.
- Dropping files shows no highlight while you drag (the system reports only
  the drop).
- On iPhone Zen receives only while it is open (iOS does not allow it to run
  in the background).
- Read receipts exist only in one-to-one chats.

[Back to the guide](README.md)
