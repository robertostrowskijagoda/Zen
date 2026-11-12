# Passwords

> Your logins and passwords for sites and apps, kept encrypted in your
> account, the same on every device of the account, and back with every
> way the account comes back. On Android 9 and later they can fill other
> apps and browsers.

## What it is

*Passwords* is a password manager inside Zen: a list of entries, each with
a name ("Bank", "Mail"), a login, a password, an address (a web page such
as `https://example.com/login`, or an Android app such as
`android-app://com.example.app`) and a note. An entry needs a name or an
address, and a password or a note.

It lives in **Settings**, the row *Passwords* (*Logins and passwords for
sites and apps*) right under *Run the setup again*. Every time it opens,
Zen asks who you are (*Passwords are protected. Confirm it's you.*): your
fingerprint or face when the key is sealed in the phone's hardware,
otherwise your app password, counted with the lock screen's attempts.
Without an app password there is nothing to ask. When Zen locks, the
screen closes with every page and dialog over it, and Zen lets go of the
entries it had opened (until the memory is reused, it may still hold
copies; see the limits below).

## How it works

- **The list.** Entries sorted by name, each with its login (or its
  address) under the name and a button that copies its password. **Search**
  looks in names, logins and addresses, never in passwords or notes. An
  empty list offers **Add password**, **Import from a file** and
  **Password setup**; later **+** adds one. The top bar has **Password
  setup** (see below). The menu (**More**) holds *Import from a CSV file*,
  *Filling in other apps* (Android) and *How it works*.
- **An entry** shows its fields, the password hidden until you tap the eye,
  with **Copy login** and **Copy password**, **Edit** and **Delete**. A
  copied password or login leaves the clipboard after 30 seconds and when
  Zen locks (*Copied — leaves the clipboard in 30 s*); the same rules as for
  every secret Zen copies apply ([Getting started](getting-started.md)).
- **The generator.** **Generate** in the form opens the *Password
  generator*: 8 to 64 characters (20 by default), lowercase, uppercase,
  digits and symbols to choose from, and *No look-alike characters (O/0,
  l/1)*. Every password with at least one character of each chosen kind is
  equally likely, drawn from the system's cryptographic generator.
  **Refresh** makes another, **Use** puts it in the form. A bar under the
  password field estimates how hard a password is to guess, from *Very
  weak* to *Very strong*: it is a hint, not a guarantee.
- **Import.** Export your passwords from a browser or a password manager to
  a CSV file and choose it in *Import from a CSV file*. Zen reads the
  exports of Chrome, Edge, Firefox, Bitwarden, KeePass and KeePassXC, and
  any file whose first row names a password column and a name or an
  address column. The file must be UTF-8 (export it again otherwise) and at
  most 8 MB; at most 10,000 rows are read. Every row becomes a new entry,
  unless one with the same name or address, login and password is already
  there. A report says how many came in and why the others did not (no
  password, no name or address, not a login such as a card or a note, from
  the trash, fields too long, damaged rows, already in Zen, no room).
  Nothing of the file is kept or written to the log. **The passwords are in
  plain text in that file: delete it after the import.**
- **Earlier passwords.** Every change keeps the version before it: an
  entry shows its last five under *Previous passwords*, each with its date,
  a copy button and **Restore** (the current one then joins the earlier
  ones). *Delete previous passwords* removes them on every device.
- **Several devices.** The passwords are the same on every device of the
  account and follow every change there by themselves. A change never
  writes over another: when two devices change the same entry at the same
  time, the newer change shows and the other waits under *Previous
  passwords*; the entry is marked *Changed on two devices at once* and
  says *It was changed on another device at the same time. Choose the
  version to keep.* **Keep the current one** settles it, **Restore** takes
  the other. An entry deleted on one device while it was being changed on
  another stays (*It was deleted on another device while being changed
  here, so it stayed.*): a deletion removes only what it saw.
- **How they come back.** Passwords come back with every way the account
  comes back: from another device of the account, in a move to a new phone,
  in every full account copy (always, whatever else is ticked), and from
  the copy your friends keep (see
  [Getting started](getting-started.md#getting-your-account-back)). After a
  key copy (paper or file) or a recovery with close friends they come from
  that copy with friends: type one friend's invitation code when you
  restore a key copy. Without any friend in Zen they do not come back that
  way. A copy taken back is merged with what the device has: nothing here
  is removed and a deletion here stays.

## Password setup

*Passwords* → the **Password setup** button in the top bar (it is on the
empty list too). It is also a step of the setup on the first start (see
[Getting started](getting-started.md)): Zen asks first whether you want its
password manager; *No* changes nothing and you can come back from
*Settings* → *Passwords*, *Yes* shows this same page inside the step.
After an update that adds a step to the first-start setup, someone who went
through the one before sees only the new step, once.

On Android 9 and later it shows two things, read again every time you come
back to Zen from the settings it opened:

- **Android's autofill service.** Whether Zen is the phone's autofill
  service, with **Open Android settings**, the page where you pick it (and
  where you switch it off). Without it no app and no browser asks Zen for a
  login.
- **The browsers.** Every browser from a fixed list of 21 that is
  installed, each with what it needs. Zen finds out which are installed from
  their package names alone (listed in the manifest; no permission, nothing
  leaves the phone). What a browser needs:

| Browser | What it needs |
|---|---|
| Chrome (also Beta, Dev and Canary), Chromium, Brave, Vivaldi | A switch of its own. Chrome 135 and later hands web forms to the phone's autofill service only with it on: in the browser, *Settings* → *Autofill services* → **Autofill using another service** (the browser restarts). Zen reads the switch, shows it as on, off or unknown, and **Open the browser's settings** opens the browser's own settings page where the browser allows it; you find the switch from there. An older browser may not have it. For Brave and Vivaldi the same switch is expected; that is not confirmed. |
| Firefox (also Beta and Nightly), Fennec, Mull, IronFox, Tor Browser, DuckDuckGo | Nothing: they are believed to use Android's autofill service by themselves. Not confirmed. |
| Edge, Samsung Internet, Opera | Probably Zen does not show up in them. They do not ask the autofill service directly but need Android's accessibility-based compatibility mode, which Zen does not use. Use Chrome or Firefox for these logins, or copy the login from its entry. |
| Kiwi, Firefox Focus, Firefox Klar | Zen knows no confirmed steps and says so; look for an *Autofill* setting in the browser. |

A browser that is not on the list is not shown; if Zen finds none it knows,
the page says where to look. The words in quotes are those of the English
browsers; in other languages they sound alike. These steps come from the
browsers' and Android's own documentation and have not been confirmed on
every browser and phone.

Where Zen fills nothing in other apps (Android 8 and older, iPhone,
Windows, macOS, Linux) the page says so plainly: open the entry in
*Passwords* and copy the login or the password (they leave the clipboard
after 30 seconds and when Zen locks). The passwords are the same on every
device of the account, so on a phone with Android 9 or later they are
offered in forms.

## Filling in other apps (Android)

On Android 9 and later, logins saved in *Passwords* can fill login forms
in other apps and in browsers. It is off until you choose it: **Password
setup** (above), or *Passwords* → **More** → *Filling in other apps* →
**Open Android settings**, and pick Zen as the autofill service there (you
switch it off in the same place).

- A login form then offers one suggestion from Zen: Zen's icon, *Zen* and
  *Unlock Zen*, in colours that read in the light and the dark theme. On
  Android 11 and later it shows inside the keyboard when the keyboard shows
  suggestions, otherwise as a drop-down under the field. It carries no
  login and no password: nothing leaves Zen before you act. A form whose
  fields are marked `autocomplete="off"` or the like still gets it.
- Tapping it brings up Zen, and you are asked **once**. If Zen was locked
  (a form opened while Zen was locked waits about a minute for that), the
  unlock you make for it, with your password or your finger, is the
  confirmation and the picker opens right after; if Zen was already open,
  it asks you to confirm who you are, as for opening *Passwords*. Then you
  pick the login yourself in *Choose a login*. Only that login and its
  password go to the form, and only while that form still waits; otherwise
  *The time to fill in has run out. Try again in that app.*
- The list shows only logins saved for that app or page. An app is known
  by its package as Android reports it, which the app cannot change; a page
  is known by its address only in a browser Zen knows. A page matches an
  entry with the same host or another host of the same registered domain
  (`login.example.com` for `example.com`), never by part of a name
  (`example.com.evil.net` does not match `example.com`); a page that is not
  https matches only entries saved with `http://`; a port must be the same
  on both sides; an app matches only an entry for exactly its package, and
  never a web entry.
- Every other login is shown only after **Search passwords** and a
  warning: *Entering a password where it wasn't saved is how scams work: a
  fake app or site pretends to be the real one.* A search past the warning
  that finds nothing says so.
- **Nothing saved for it yet?** The picker has a button for a new login for
  that page or app. It opens the entry form with the name filled in and the
  address fixed: the page's address as the browser reported it (scheme, host
  and port), or the app's package, taken from the request and not from
  anything the page or app wrote, so the next time the same page asks, this
  entry is found. You cannot edit the address there. Saving it fills the
  form with it at once. Zen keeps the request open for up to five minutes
  from when it began while you type, instead of one. If the form ended
  meanwhile, the login is still saved, and Zen says it was saved but not
  filled.
- **A login in two steps.** On the first page, with the login field alone,
  Zen offers its suggestion when that field says it is the login
  (`autocomplete="username"`; an e-mail field alone is not enough, or every
  newsletter form would get it). The picker then lists only entries that
  have a login and says that only the login is filled. The second page,
  with the password alone, gets its own suggestion and fills the password.
- **Forms Zen leaves alone.** A form with two or more password fields
  (signing up, changing a password) gets no suggestion, and a field that
  says it is something else (a new password, a one-time code, a search, a
  phone number, an address, a card) is never filled.
- Zen never offers to save logins typed elsewhere.

**What another app can and cannot do.** Any app with a login form can get
the *Unlock Zen* suggestion and bring Zen up. It cannot read anything by
that: it gets a login only when you unlock Zen (or confirm who you are) and
pick one, and it is offered only the logins saved for its own package.
If you pass the warning and pick a login saved for something else, that
app gets it. While the list is on the screen, touches that come through
another app's window drawn over Zen are ignored.

## What stays private

- The passwords are kept only in the account's encrypted store on your
  devices. Changes travel between your devices sealed for them alone.
- Your friends who keep the copy with friends hold the passwords sealed:
  they cannot open them, and the passwords are padded so that the copy's
  size does not tell how many there are.
- Nothing of an entry, a form or the app that asked goes to Zen's log.

## Limits

- What it does not protect: a password you copy is on the clipboard until
  it is cleared (on Linux, macOS and iPhone on the plain clipboard); a
  password you fill goes to the app you picked; while *Passwords* is open
  the entries are in Zen's memory; anyone with your unlocked phone and your
  app password (or your finger) can open them.
- A changed or deleted password does not leave everything at once: the
  account's own record of changes on your devices keeps it until it next
  starts over (at most a few hours later), the encrypted store keeps one or
  two earlier saves of itself, a friend keeps the previous copy with
  friends until a new one replaces it, and a full account copy keeps what
  was there when you made it.
- Up to 2000 entries and 4 MB; a name up to 200 characters, a login 256, a
  password 512, an address 1024 and a note 2000. With the list full, Zen
  says so and asks you to delete what you no longer need.
- Passwords saved by a newer Zen stay as they are until you update; a
  store that cannot be read is left untouched, never taken for an empty
  one.
- Filling in other apps exists only on Android 9 and later. On Android 8
  and older, on a computer and on iPhone Zen fills nothing in other apps:
  copy the login and the password from the entry instead. Browsers that
  hand no forms to the autofill service (Edge, Samsung Internet and Opera
  probably among them) cannot be filled either.
- The password setup and the suggestion in the keyboard were written from
  the documentation of Android and of the browsers and were not tried on
  real phones before their release.

[Back to the guide](README.md)
