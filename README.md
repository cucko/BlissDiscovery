# Bliss Discovery (LMS / Lyrion plugin)

Adds a **Bliss Discovery** section to the Material Skin home screen — a row of
album-art tiles, each a randomly picked song from a **different genre**, shown
exactly like Material's "New Music" section. Tapping a tile immediately
starts a **Bliss mix** seeded from that song on the current player.

It also adds a **Bliss Discovery** entry to the **My Apps** menu, so the same
tiles are reachable from the Default/Touch web skin and any Jive/SqueezePlay-
based player UI, not just Material Skin.

Requires:
* **Material Skin** (recent version with third-party home-screen sections) for
  the home-screen section - the **My Apps** entry works without it
* **Bliss Mixer** plugin, with your library analysed by bliss-analyser

## Screenshots

| Home screen section | Enabling in Material Skin | Plugin settings |
|---|---|---|
| ![Bliss Discovery home section](HTML/EN/plugins/BlissDiscovery/html/images/screenshots/HomeSection.png) | ![Enabling the scrollable list](HTML/EN/plugins/BlissDiscovery/html/images/screenshots/ScrollableItems.png) | ![Plugin settings page](HTML/EN/plugins/BlissDiscovery/html/images/screenshots/Settings.png) |

## Install

### Via the LMS plugin repository (recommended)

1. In LMS, open **Settings → Plugins**, scroll to the bottom and add this URL
   under **Additional Repositories**:

   ```
   https://raw.githubusercontent.com/cucko/BlissDiscovery/main/public.xml
   ```

2. Press **Apply**. **Bliss Discovery** now shows up in the plugin list under
   3rd party plugins — check it, press **Apply** again, and restart LMS when
   prompted.
3. Future updates show up the same way LMS's own plugins do: a new version in
   the list to check and apply.

### Manual install

1. Stop LMS.
2. Copy the `BlissDiscovery` folder into your LMS `Plugins` directory so you get
   `Plugins/BlissDiscovery/Plugin.pm`.
3. Start LMS. The plugin is enabled by default.

### After installing

In Material Skin open **Settings → Interface → Home screen** (the list of
home-screen sections such as New Music / Recently Played) and enable
**Bliss Discovery**. Drag it to where you want it.

## Settings

Server Settings → Plugins → Bliss Discovery:

| Setting | Default | Meaning |
|---|---|---|
| Number of tiles | 6 | 1–12 tiles, one genre each |
| Mix length | 20 | Tracks in the generated mix (1–50) |
| Genres from | LMS genres | What "one genre per tile" means: a different **Lyrion Music Server genre**, or a different **Bliss Mixer genre group** (Bliss Mixer settings → Genre groups). Group names are matched like Bliss does — case-insensitive globs (`* Rock`) — and with Bliss's *Use track genre* on, every ungrouped genre counts as its own group. Falls back to LMS genres if no groups are defined |
| Restrict to library | All music | Pick tiles and mix tracks only from a virtual library. Choose a specific library, **Library selected in Material Skin** to follow Material's own **Change Library** button, or **Player's library view** to follow each player's own library setting (LMS Settings → Player → Library View); in the latter two modes each browser / player gets its own tile set |
| Favorite genres | (none) | One genre name per line. These always get a tile (as many as fit within "Number of tiles") before the rest are picked at random |
| Excluded genres | (none) | One genre name per line. These genres are never used for tiles |
| Enable Don't Stop The Music | off | Also switch the player's DSTM to Bliss Mixer when a tile is tapped |
| Replace tile after playing | on | The tapped tile is swapped for a song from a genre not currently shown |
| Refresh all tiles every (hours) | 24 | Periodic re-pick of all tiles; 0 disables. Tiles also refresh after every rescan |
| Refresh tiles now | — | Button to re-pick immediately |

Tile changes are pushed to Material live (no page reload needed).

Each tile also has a context menu (the "⋮" that Material shows on a tile) with
**Add/Remove from favorite genres** and **Exclude/Un-exclude this genre**,
which update the same two settings and re-pick tiles immediately.

## How it works

* On startup (and after rescans / on schedule) the plugin picks random genres
  — or Bliss Mixer genre groups, per the *Genres from* setting — and one random
  local track per genre/group. Bliss's groups are read from the Bliss Mixer
  plugin's `genre_groups` preference and resolved to LMS genre ids with the
  same rules the mixer uses (case-insensitive globs, ungrouped genres as
  singleton groups when *Use track genre* is on). Favorite genres are given a
  tile first, before the rest are picked at random; excluded genres are never
  used, in either mode.
* It registers a home-screen section with Material via
  `Plugins::MaterialSkin::Plugin->registerHomeExtra`. Material asks for the
  items when it draws the home screen; each item carries the track's cover
  (`music/<coverid>/cover.jpg`) and a `go` action `blissdiscovery playlist play tile:N`.
* The section shows "Number of tiles" tiles. Pressing Material's **More**
  button on the section header opens a page with **3×** that many tiles — the
  extra ones are picked on demand (again one per genre, genres/songs already
  shown are skipped) and appended, so the tiles already on the home row keep
  their place.
* Tapping runs that command on the current player. The plugin calls
  `blissmixer mix track_id:<id> count:<n>` (the Bliss Mixer plugin does all
  the mixing), loads the returned tracks with the seed song first, and
  optionally switches DSTM to Bliss.
* The same tiles are exposed as a **Bliss Discovery** entry under **My Apps**
  via `Slim::Plugin::OPMLBased` (`menu => 'apps'`), so any skin or player UI
  that browses the apps menu can reach them, tapping a tile there runs the
  same `blissdiscovery playlist play tile:N` command.

## CLI

```
blissdiscovery playlist play tile:<n>          # start a Bliss mix from tile n (needs player)
blissdiscovery refresh                         # re-pick all tiles
blissdiscovery list                            # show current tiles
blissdiscovery more tile:<n>                   # context menu for tile n's genre
blissdiscovery genre toggle list:<l> genre:<g> # toggle genre g in list l ('favorite' or 'excluded')
```

## Library restriction

Bliss Mixer itself doesn't know about virtual libraries, so the plugin handles
it: tile songs are picked from the chosen library, Bliss is asked for up to 3×
the mix length, and the result is filtered to tracks in the library before
loading (trimmed back to the mix length). If very few tracks in a library have
been analysed, mixes may come out shorter than requested.

Material Skin keeps the library chosen with its **Change Library** button in
the browser, and passes it to the server only as a `library_id` parameter on
the requests that browser makes - it is not handed to third-party home-screen
sections. In **Library selected in Material Skin** mode the plugin therefore
chains itself in front of Material's own `material-skin` CLI handler (using the
previous handler that `addDispatch` returns) and notes `library_id` as it goes
past, per player. Changing the library in Material re-fetches the home screen,
so the tiles swap over straight away. The section's **More** page does not send
`library_id`, so it reuses the last value seen from the home screen.

## Notes

* Songs are picked from the LMS library, not from the Bliss analysis DB. If a
  picked song was never analysed, Bliss returns no tracks and you'll see an
  error toast — just tap another tile or refresh.
* Only local (`file://`) tracks are used. Cue-sheet sub-tracks are included -
  bliss-analyser analyses them and Bliss Mixer maps them to and from its own
  `<file>.CUE_TRACK.<n>` paths.
* If the Material Skin plugin isn't installed you'll get a warning in the
  server log and no tiles.
