# SqueezeWax

SqueezeWax is a plugin for Lyrion Music Server (LMS). It reads your Discogs
record collection and works out which albums in your LMS library are records
you own. Where it knows, the album's menu says so and links to the release on
Discogs, and a "Records I own" library view shows only those albums. The plugin
never plays audio and never changes your Discogs collection.

## Requirements

### Hard requirements

- Lyrion Music Server 8.4 or newer (`install.xml`). It has been tested on
  9.1.1.
- A Discogs account, with your records in your Discogs collection.
- A Discogs personal access token (see [Discogs setup](#discogs-setup)).
- No other plugins or add-ons are required. Every Perl module the plugin uses
  ships with LMS or with Perl itself, except HTTPS support (`IO::Socket::SSL`),
  which the plugin uses only through LMS's own HTTP classes. LMS bundles that
  for macOS only; on other systems it comes from the system's Perl, and without
  it the scan-time sync fails with only a warning in the scanner log (the
  fallback sync after the scan is then the one that works, and only if the
  server has HTTPS too).

### For good results

- **Tags (needed for the exact-pressing result).** SqueezeWax reads no tag by
  default: the list of tag names starts empty, and you fill it in under
  Settings (or let "Detect" find them). Your files need a tag holding the
  Discogs release ID. A tag value can be:
  - the plain number, e.g. `123456`;
  - Discogs markup, e.g. `[r123456]`;
  - a Discogs release URL, e.g. `https://www.discogs.com/release/123456-Title`.

  Put the same release ID on every track of an album. SqueezeWax reads two
  files per album and compares them. If the two files name different releases,
  or one carries a Discogs tag and the other does not, the album is sent to the
  review queue and is not identified from tags. A file that cannot be read is
  ignored, not counted as a disagreement.

  Optionally, a master release ID can be tagged as `DISCOGS_MASTER_ID`,
  `DISCOGS MASTER ID` or `DISCOGS_MASTER_RELEASE_ID`. These names are fixed
  and cannot be changed. If there is no master tag, SqueezeWax asks Discogs for
  the master of each identified release.
- **Collection.** Ownership is decided from your Discogs collection, so the
  records must be in it (the main collection listing is read, not the
  wantlist):
  - *You own a pressing:* the release ID in your tag is in your collection.
  - *You own a version:* the tagged release is not in your collection, but its
    master release is (another pressing of the same record is).
  - *You own a version, no tag needed:* exactly one entry in your collection has
    the same album title and the same artist. Titles are compared ignoring
    capital letters and extra spaces, and nothing else, so punctuation
    differences will stop a match.
- **Albums with no Discogs tag.** They are not identified, but they can still
  be marked owned by the title-and-artist rule above. What happens when the
  title matches but the rest does not:
  - exactly one entry has the same title and artist: owned (a version), even if
    other entries share the title;
  - two or more entries have the same title and artist: not owned, and the
    album goes to the review queue;
  - both sides say "Various Artists": not owned, and the album goes to the
    review queue;
  - only one entry has the title, and its artist differs or is missing on
    either side: not owned, and the album goes to the review queue;
  - several entries have the title, none by this artist: not owned and not
    queued, unless the album itself has no artist, in which case it is queued;
  - no entry has the title: not owned.

  If you have configured no tag names at all,
  tag reading is switched off and only the title-and-artist rule is used.
  Albums with no local files (all streaming) are not read for tags but are
  still checked by title and artist.

## Install

SqueezeWax is not on the main LMS plugin list. Add its repository in LMS under
Settings → Plugins → Additional Repositories:

    https://raw.githubusercontent.com/d5c0d3/lms-plugin-squeezewax/v1-buildout/repo.xml

Then install and enable SqueezeWax from the plugin list. This repository is
a development branch; its version series is `0.0.0.N`.

## Discogs setup

1. On the SqueezeWax settings page, follow the "Discogs Developer Settings"
   link (`https://www.discogs.com/settings/developers`) and generate a personal
   access token.
2. Paste it into "Discogs personal access token" and save.
3. Press "Test token". It reports "Token is valid" with your Discogs username,
   or says why Discogs refused it.

The token is stored in this server's preferences file in plain text, not
encrypted. It is not limited to your collection: it can do anything you can do
on Discogs. Revoke it at the same Developer Settings page if you stop using the
plugin: uninstalling SqueezeWax does not delete the token or the SqueezeWax
database from the server, because LMS removes only the plugin's code. If you
paste a new token, the stored Discogs username and currency are cleared and
looked up again.

## Settings

Open it from Manage Plugins (SqueezeWax → settings). No settings have a default
other than empty.

| Setting | What it does | Default |
|---|---|---|
| Discogs personal access token | Lets SqueezeWax read your collection. Required for ownership. | empty |
| Test token (button) | Checks the token in the box, and saves the page. | |
| Discogs collection → Sync collection now (button) | Reads your collection now and updates ownership. Also shows when it last synced and how many items it found. | |
| Discogs release ID tags | Names of tags in your files that hold a Discogs release ID. Several may be listed, since different formats use different names. Leave blank to turn tag matching off. | empty |
| Detect tag names (button "Detect") | Reads a sample of your albums and lists tags that look like a Discogs release ID, to copy into the box above. | |
| Review queue | Link to the page listing albums SqueezeWax could not decide. | |
| Master releases | Shown only while there is background work: progress of asking Discogs for master releases. | |

While a library scan is running, the page shows a "scan is running" notice in
place of the Test token, Sync collection now and Detect buttons, and a save does
not change the tag names (the token field still saves). The same notice appears
if one of those actions is submitted anyway.

## Using it

- **Album and track menus.** Only albums you own get entries.
  - **Your exact pressing**, in apps and web pages that can open links:
    "Discogs: Browse your pressing" (a link to it on Discogs), "Discogs: Show
    your pressing's details" (a submenu), "Discogs: Browse all versions" (a link
    to the master release) and "Discogs: Show master details" (a submenu).
  - **A version you own** (another pressing of the same record): only "Discogs:
    Browse all versions" and "Discogs: Show master details". There is never a
    link to a pressing you don't own.
  - **On a player, and in apps that cannot open links:** "You own a pressing" or
    "You own a version", then the same submenus. The submenus show the Discogs
    address as text instead of a link.
  - Each entry appears only where the release or master ID is known. An album
    whose tags disagree shows only the ownership line.
  - **The submenus ask Discogs only when you open them**, one request each, and
    store nothing on disk; a reply is kept in memory for up to 2 minutes, so
    scrolling a submenu does not ask again. Pressing details show the label and catalogue number;
    format, country and date; genre and styles; how many Discogs users have and
    want it; its rating; and how many copies are for sale, from what price.
    Master details show the year, genre and styles, and copies for sale.
  - **Prices are in your Discogs account's currency.** SqueezeWax learns which
    currency that is when a collection sync runs (press "Sync collection now"
    after entering your token), and the settings page's Prices section shows
    it. Until it knows, it shows the number of copies for sale without a price.
  - If Discogs' request limit is used up, a submenu says "Discogs is busy, try
    again in N s" and asks nothing.
- **Records I own.** A library view (and a My Music entry) that shows only the
  albums you own, in the normal album grid.
- **Review queue** (Settings → Review queue). Lists albums with conflicting
  tags, ambiguous or disagreeing artist matches, and matches whose album has
  left your library. For each album you can:
  - "Show tags" to see which files disagree;
  - "Choose from my collection" and pick the record you own ("This one");
  - "Remove this match" (asks for confirmation; the album is matched from
    scratch at the next scan).

  A match you choose by hand is kept, and changes ownership at the next sync.
  A match with no album can be moved onto an album in your library that has the
  same artist, title and track count.
- **Syncing.** Your collection is read automatically during each library scan,
  and again about a minute after a scan if that did not happen. There is no
  timer: a record you add to Discogs shows up after the next scan or after
  "Sync collection now". If Discogs rejects the token, automatic syncs pause
  until you fix the token or press the button.

## Data and privacy

- **Fetched from Discogs, using your token:** your username and your profile's
  currency (at each collection sync); your whole
  collection (the main collection listing, a page of 100 at a time); in the
  background, one release lookup per identified release to find its master
  release (up to 30 a run, one a second, only when something is pending); and
  one release or master lookup each time you open a details submenu. The
  collection is held in memory for the length of one pass and then discarded;
  what a submenu shows is kept in memory for up to 2 minutes (so scrolling does
  not ask again), is emptied when you change the token, and is never written to
  disk. The settings page shows which currency prices use, from the stored label.
- **Stored in the SqueezeWax database** (`squeezewax.db`, in LMS's preferences
  directory): for each album a key made from its files, the release ID and
  master ID, whether you own it (and how), how it was matched, when, and the
  artist, title, track count and total duration of the album *from your own LMS
  library* (used to find an album again after files move); plus the master ID
  fetched from Discogs and the release it came from, a "checked, no tag" record
  per album, and the time and item count of the last sync.
  No titles, artists, tracklists or other Discogs release data are stored.
- **Stored in LMS preferences:** the token (plain text), your Discogs username
  (used for the link back to your collection), your Discogs currency code (used
  to label prices), and the last sync error.
- **Refresh:** see Syncing above. Nothing is fetched on a schedule. No
  expiry: nothing in the plugin deletes a stored match because of its age. A
  match row is removed only by "Remove this match" in the review queue, or when
  a scan finds that its tags no longer name a release and the row carries no
  decision. Removing or changing the token, or uninstalling the plugin, deletes
  nothing: `squeezewax.db` stays in LMS's preferences directory until you delete
  it.
- Requests are limited to stay within Discogs' limit of 60 requests a minute.
  A collection of N items costs about N/100 requests per sync.

## Limitations and known issues

- SqueezeWax does not draw a badge on album artwork. The Default and Material
  skins offer no way for a plugin to do so. Owned albums are shown in the menus
  and the "Records I own" view.
- A record you add or remove on Discogs is noticed only at the next scan or
  manual sync.
- Matching assumes a collection that matches your shelves. An album wrongly
  marked as owned by the title-and-artist rule cannot be unmarked in the plugin;
  fix the collection or the tags.
- Ownership by title cannot decide between several collection entries with the
  same title and artist, or for compilations ("Various Artists"); those albums
  go to the review queue.
- The review queue's "Choose from my collection" lists a fixed set of fields.
- This is a development build; several hardware checks are still open in
  `TODO.md`.

## Discogs notice

This application uses Discogs’ API but is not affiliated with, sponsored or endorsed by Discogs. ‘Discogs’ is a trademark of Zink Media, LLC.

## License

Licensed under GPL-2.0-or-later; see [LICENSE](LICENSE). The license covers the
plugin code only, not data obtained from Discogs, which stays under the Discogs
API Terms of Use.

## Credits

- SqueezeWax by d5c0d3.
- Collection data from [Discogs](https://www.discogs.com/).
- Built for Lyrion Music Server.
