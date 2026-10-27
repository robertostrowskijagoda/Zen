# Feed and videos

> Posts and short videos from people you know, in the order your own phone
> works out. No server, no ads, no recommendation engine.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../images/feed-dark.png">
    <img src="../images/feed-light.png" width="260" alt="The feed">
  </picture>
  &nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../images/films-dark.png">
    <img src="../images/films-light.png" width="260" alt="The Videos tab">
  </picture>
</p>

## The feed

**What it is.** Posts with text, photos, videos and audio recordings. For
every post you choose who sees it: public, all friends, friends and close
friends, or close friends only.

**How it works.**

- Every post is a signed entry in your own log. Your friends' phones fetch
  new entries from each other when they meet on the network. Anything that
  is not public is encrypted with a key of its audience, which only friends
  of a high enough level hold.
- Filters: **All · Friends · 2nd degree · 3rd degree · Close friends ·
  Pyramid · Country**. *Friends* shows posts of friends and people you
  follow (and what friends reshared); *2nd degree* and *3rd degree* show
  posts that friends passed on from further away (see below). *Close
  friends* shows posts of people you marked as close friends. *Pyramid*
  and *Country* show posts from [the pyramid](pyramid.md). The order is
  always by time, with no algorithm.
- Likes, reactions, comments and shares. "Liked by you, Bob and 1,284
  others" counts only what your phone has seen.
- Public posts can be **followed** by people who are not your friends.
- GIFs in a post stay animated. On a computer you can drop or paste photos,
  GIFs and videos (up to 50 MB) into the post editor and into *Add to
  gallery*.
- A comment can carry up to 4 photos or GIFs (camera, gallery, a file, GIF
  search, a keyboard GIF, or dropped and pasted on a computer); tap one to
  see it full screen. Your own comment can be deleted, with its pictures.
  The comment field stays at the bottom of the comments, like under videos.
- A deleted comment takes with it only the pictures that came with that
  author's entries and that nothing else uses: a deleted comment can never
  remove a photo from your chats, the pyramid or your own posts. Storage
  limits likewise count only pictures fetched for posts and comments.
- You can hide comments and block people in your own threads; **Report**
  keeps the signed original as evidence and can remove the post from your
  device.

## How far a post goes

**What it is.** For a public post you also choose its reach: **Friends**,
**Friends of friends** (the default) or **3rd degree** (one step further).
A post for any other audience stays with your friends, whatever the reach.
Your phone remembers the last reach you picked for the next public post.

**How it works.**

- Your friends get the post itself, as always. Beyond them only a small
  notice travels: a friend of yours writes, in their own log that only
  their friends read, that a post of yours exists (its id, when it was
  written, its reach and how many steps from you it is). No text and no
  photos.
- A friend of a friend who sees such a notice fetches the post from the
  friend who passed it on (who holds it) or from you directly, and checks
  your signature and that you really gave the post that reach. So the post
  arrives even while you are offline.
- For a post of reach 3, a friend of a friend passes the notice one step
  further, but only once the post is on their phone, so their friends can
  fetch it from them. Nobody passes anything further than three steps.
- On the wall such a post says **via Bob**: the friend of yours who passed
  it on. You learn nothing about the path beyond that friend.
- Edits and removals follow the same way: the friend passes on a new notice
  and phones that hold the post fetch the new version, or your signed
  removal.
- Likes and comments of friends of friends reach you through the friend who
  passed the post on, shown as "Ada (via Bob)".
- Limits: notices only about posts from the last 30 days; each post passed
  on once (again only when it changes); at most 10 posts of one person and
  300 notices in all a day from one phone. A phone keeps up to 300 posts
  fetched this way.
- **Reshares** work as before: a reshare carries the whole post and goes as
  far as people keep resharing it, whatever its reach.
- The reach is kept by Zen on every phone, but it is not encryption: a
  public post can still be read by anyone who follows you. For posts that
  must stay among friends, choose a friends audience.

## Videos

**What it is.** A full-screen vertical player for short videos from friends
and people you follow: swipe up and down, double tap to like, emoji
reactions, comments, **Reply with a video**, **Send to chat**.

**How it works.**

- **Hold to record** (60 seconds, or 90), front or back camera, torch,
  3 or 10 s timer, or pick a file. Trim the start and end, add a description
  (up to 150 characters) and choose who sees it, as with a post.
- Before publishing, the phone shrinks the video to about 720p and at most
  20 MB, removes its metadata (place, device) and encrypts it.
- The order is computed on your phone: fresh unwatched videos from the last
  7 days first, weighted by how your friends reacted (likes, comments,
  shares, close friends count more), never the same author twice in a row;
  then older unwatched ones; then the rest. The list does not jump under
  your finger.
- A video is stored in encrypted blocks of 256 KB. Only the video on screen
  downloads in full; the next two fetch their first block, the next five
  their cover. A video plays only while its tab is on the screen. Blocks come from the author's devices, from friends who
  passed it on, and from the author's mailboxes (which keep a friend's
  newest videos, up to 20 MB per person).
- Up to 1 GB of other people's videos is cached; watched ones go first. Your
  own are never removed.
- **Videos from friends of friends** (off by default): public videos that a
  friend liked. Their authors don't learn that you watch them.

## Privacy

- Like counts and reactions next to a video count only your friends.
- Views are visible only to the author, counted from the author's friends.
- Moderation works as on the feed: report, hide a video, pyramid bans; an
  author can delete their own video everywhere it reached.

## Limits

- **Computers.** Windows records with the webcam (no torch) and shrinks
  videos with Media Foundation. A Mac records and shrinks with the system's
  own video tools. Linux records through GStreamer and shrinks with an
  H.264 encoder (OpenH264) and an AAC encoder (vo-aacenc) built into Zen;
  it needs GStreamer (or ffmpeg) to read the input. Without either, a video
  is published as it is if it is at most 20 MB and 90 seconds, without
  trimming. On a computer the camera turns off while Zen is hidden or
  minimised (a recording in progress ends and is kept) and on again when
  you come back.
- Likes and comments of friends of friends reach the author through the
  friend who passed the video on, shown as "Ada (via Bob)".
- The feed and video lists are only as complete as what your friends'
  devices have passed on.

[Back to the guide](README.md)
