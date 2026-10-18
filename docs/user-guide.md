# SqueezeWax user guide: from a new record to "You own a pressing"

## 1. How it fits together

Your Discogs collection says which records you own. A tag in your music files
says which Discogs release each album is. SqueezeWax matches the two every time
LMS scans your library, and marks the albums you own. Nothing here depends on
which tools you use to rip or tag, as long as the files carry the Discogs
release ID.

## 2. The workflow

1. **Add the exact pressing you own to your Discogs collection.** Use the main
   collection, not the wantlist. Do this *before* the scan in step 6: a record
   added afterwards shows as owned only after the next scan or a press of
   "Sync collection now".
2. **Rip the record** with any tools you like.
3. **Tag every track with the Discogs release ID.** Optionally also tag the
   master release ID, using one of these names: `DISCOGS_MASTER_ID`,
   `DISCOGS MASTER ID` or `DISCOGS_MASTER_RELEASE_ID`. (These names are fixed.)
   Without a master tag, SqueezeWax asks Discogs for the master itself.
4. **One-time setup: tell SqueezeWax the name of your release-ID tag.** Type it
   into "Discogs release ID tags" in SqueezeWax's settings, or press "Detect" and
   copy what it finds. The list starts empty, and until you fill it SqueezeWax
   reads no tags at all. (You also need your Discogs token entered once; see the
   README.)
5. **Copy the files into your LMS music folder.** *Keep the music share mounted
   during the scan.* LMS removes library entries for files it cannot reach, and
   it cannot tell a share that is offline from files that were deleted.
6. **Run an ordinary library rescan** (Basic Settings → Rescan Media Library →
   "Look for new and changed media files"). SqueezeWax reads your collection
   itself during the scan. Only if your files have no master-release tag, press
   "Sync collection now" once after the "Master releases" work on the settings
   page has finished; albums whose files carry a master tag already show "You own
   a version" after the rescan.
7. **Check.** Open the album's menu. It should say "You own a pressing" (or "You
   own a version") with the Discogs link or links, and the album should appear in
   "Records I own". If it doesn't, see section 4.

## 3. A worked example

This is one way to do it. Any ripper and any tagger works, as long as your
files end up with the Discogs release ID in a tag.

The record was *Various – X-Mix-1 - The MFS Trip*, a various-artists DJ mix on
vinyl: 13 tracks over sides A and B.

- **Ripping.** Turntable into a USB phono preamp, recorded in Audacity. One raw
  WAV per side was kept as a backup; each side was then split into tracks at
  labels and exported as 16-bit FLAC.
- **Tagging.** In foobar2000 with its Discogs tagging component: select all the
  tracks, look up the release, compare, apply the tags. By default that
  component writes `DISCOGS_RELEASE_ID` and `DISCOGS_MASTER_RELEASE_ID`. Here
  that gave release 198756 and master 56108 on all 13 files.
- **Then.** The release was added to the Discogs collection, the files were
  copied to the music folder, and one ordinary rescan was run, with no "Sync
  now". The album then showed "You own a pressing" with both Discogs links
  (the master link comes straight from the tag), and appeared in "Records I own".

A various-artists record is the awkward case for matching by title, but it did
not matter here: SqueezeWax checks the tagged release against your collection
first, and only looks at artist names if that fails.

### Optional tagging tips

*These are good practice for LMS and are **not needed by SqueezeWax**.*

- **Track numbers.** Use a running number 1-N across both sides. LMS keeps only
  the first run of digits, so vinyl positions like A1 and B1 both become 1. If
  you want the Discogs position, keep it in a separate tag.
- **Compilations.** Set `COMPILATION` to 1 on various-artist releases and DJ
  mixes, so LMS lists them under Compilations. `COMPILATION` = 1 makes it
  certain. Without it, LMS guesses from the album artist and the track artists,
  and Discogs' "Various" is not LMS's "Various Artists".
- **ReplayGain.** Add ReplayGain tags for level matching. LMS can apply track or
  album gain, chosen per player.

## 4. If an album isn't shown as owned

| What you see | Why | What to do |
|---|---|---|
| Nothing for any album | No tag name is set in "Discogs release ID tags", so only the title-and-artist rule runs. Or no token. | Fill in the tag name (or "Detect") and the token, then rescan. |
| Not owned, tagged correctly | The release is not in your main collection, and neither is another pressing of the same master. | Add it to your collection, then rescan or press "Sync collection now". |
| "You own a version", not "a pressing" | The tagged release is not in your collection, but another pressing of its master is. | Add the exact pressing, or fix the tag if it names the wrong release. |
| Album is in the review queue | Some tracks carry a Discogs tag and others don't, two tracks name different releases, or a tag's value can't be read. | Open Settings, then Review queue: each album says what to fix. "Show tags" shows which files disagree. Retag them, then rescan. |
| No tag, owned as "a version" | Exactly one collection entry has the same album title and artist. | Nothing; this is the title-and-artist rule. |
| No tag, in the review queue | Two or more entries share title and artist; or both sides say "Various Artists"; or the title matches one entry but the artist differs or is missing. | Tag the files with the release ID, then rescan. Albums with only streaming tracks can't be tagged. |
| No tag, not owned | No entry in your collection has that title (or several share it and none is by this artist). | Tag the files with the release ID. |

If the files carry the right tag and the release is in your collection but the
album still isn't marked, make sure the music share was mounted during the scan
and that you saved the settings before it.
