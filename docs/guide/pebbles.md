# Pebbles

> Paint a stone, stick its QR code somewhere, and let others find it. Each
> finder collects it; it stays where it is for the next one.

## What it is

A **pebble** (*kamyczek*) is a small virtual stone you paint yourself: its
shape, its colours, and pictures on every side. You give it a name and a
short note ("near the river in Warsaw", "made by Kasia"), print its QR code
as a sticker and leave the sticker in a place worth finding. Whoever scans
it **collects** the pebble: it goes into their collection, and the sticker
stays for the next person. Everyone who finds it can collect it.

Every profile has a **Kamyczki** tab with the pebbles the person made and
the ones they collected. Only friends see it.

## How it works

**Making one.** Profile → *Kamyczki* → **Make a pebble**: paint the stone,
give it a name and a note, then **Publish**. Zen signs the pebble with your
account key; nobody can change it afterwards (to change it, make a new one).
Then **Print sticker** opens the sticker designer with the pebble's code.
The form shows how much room the texts take in the QR code: with a long
note the painted preview is left out of the code (the page then shows the
stone in its colours), and very long texts are shortened so the code stays
easy to scan on a small sticker.

**Finding one.** Scan the sticker with **Scan pebble** (or with the QR
button where you add friends), or open its link. You see the stone, its
name, note, author and date. **Collect** saves it at once; you can add a
note about where you found it (your friends see it). If you do not have
Zen, the link opens a page that shows the pebble and how to get Zen.

**The full design comes in the background.** The QR code carries only a
small card: enough to draw a recognisable stone. The painted design is
fetched from other devices: first from the author, then from the friends
who keep it, then from your friends and their friends who have it. Until it
arrives the pebble shows its card's look; Zen keeps asking now and then,
also later, so it upgrades by itself.

**Keepers.** When you publish, Zen asks a few of your friends (devices that
are often online first, computers and phones mixed) to **keep** the pebble:
each gets a question like "Kasia asks you to keep her pebble 'Ladybird'. It
takes 12 KB. Do you agree?". Those who agree hold a copy and hand it out
when your phone is offline. If someone says no, does not answer for two
days or gives the role up, Zen asks someone else. On the pebble's screen
you see who keeps it, and you can draw again. A keeper keeps the role even
if you later remove them as a friend; it belongs to the pebble.

**Collectors help too.** Everyone who collected a pebble can hand it on to
others who look for it, so popular pebbles get easier to find. You can turn
this off: Settings → Network and service → **Serve collected pebbles**.

**Found it!** When you collect a pebble whose author is your friend, Zen
quietly tells them someone found it; the pebble's screen shows the author
how many people did.

**Taking one back.** The author can **retire** a pebble: keepers stop
handing it out; people who collected it keep their copy.

## What stays private

- The link's page reads the pebble from the part of the link the browser
  never sends to the server; GitHub does not see which pebble you opened.
- Your Kamyczki tab is sealed for your friends; people who only follow you,
  or friends of friends, cannot read it.
- Anyone who scans the sticker sees what is on the card: the stone, its
  name and note, your display name and the date. Do not put anything there
  you would not write on the sticker itself.
- Devices you ask for a design learn your Zen address and which pebble you
  want; serving collected pebbles lets others ask your device. People you
  blocked get nothing from you and you take nothing from them.

## Limits

- The stone the card draws is a stylised preview; the full 3D design needs
  the design fetched from someone who has it. If nobody who has it is online
  for a long time, the pebble stays in its preview look until someone is.
- A pebble is never changed after publishing.
- Up to 500 collected pebbles and 200 kept for friends per device.
