# Security

## Reporting

Report a vulnerability through GitHub's private advisory form on this
repository: **Security → Report a vulnerability**. Include the version or
commit, your platform, and the smallest input or plugin that reproduces it.

Expect an acknowledgement within a week. There is no deadline for a fix.

## In scope

A bypass of any of these is a vulnerability:

| Boundary | A vulnerability is |
|---|---|
| Plugin process (Node `--permission`) | A plugin reading files outside its own folder, its data folder and melo's plugin host folder; writing outside its data folder; or starting a process, worker thread or native addon |
| Plugin network allowlist | A plugin without `rawNetwork` reaching a host its manifest does not list, or opening a raw socket or WebSocket |
| Skin archives (`ZipReader`, `SkinArchive`) | A crafted skin causing memory corruption or reading a file outside the archive |
| Plugin without `ui` | Running code in melo's process |
| melo's own folders | Writing anywhere outside them |
| Your credentials | Disclosing your cookies or Last.fm API key |
| Remote input | Input an attacker can craft to crash melo |

## Not in scope

- A plugin with the `ui` grant doing anything melo can do, including reading
  any file. Its QML runs in melo's process and is not sandboxed.
- Bypassing the QML import allowlist.
- Attacks that need code already running as your user.
- Denial of service through a file or plugin you installed yourself.
- The content YouTube serves.

## What melo sends, and to whom

melo has no telemetry, analytics or crash reporting. It contacts these hosts:

| Host | When | What |
|---|---|---|
| `youtube.com`, `music.youtube.com`, `googlevideo.com` | Search, browsing, playback | Your query, the video id, and your profile's cookies. With **Improve recommendations** on (the default), what you play |
| `i.ytimg.com`, `yt3.ggpht.com`, `*.googleusercontent.com` | Artwork and avatars | The image request |
| `jnn-pa.googleapis.com` | Playback, about every 12 hours | A BotGuard attestation |
| `musicbrainz.org`, `api.deezer.com` | Auto-tagging | Artist and title |
| `coverartarchive.org`, `archive.org`, `cdn-images.dzcdn.net` | Album art | The MusicBrainz release id, or the image request |
| `ws.audioscrobbler.com` | Auto-tagging, when a Last.fm API key is set | Artist, title and your API key |
| `lrclib.net` | Lyrics | Artist, title, album, duration |
| `github.com`, `release-assets.githubusercontent.com` | Start, when yt-dlp is missing; a yt-dlp update check at most once a day | The download request |
| `nodejs.org` | First start, when the system has no Node 22.15 or newer (every Linux package except the full AppImage) | The download request |
| A plugin's listed hosts | While that plugin runs | Whatever that plugin sends |

## Profiles and your Google account

A guest profile is an anonymous YouTube identity. Its cookies are stored in
`~/.config/melo/guest-cookies/`; on Linux the files are mode `0600` in a `0700`
directory.

A browser profile uses that browser's YouTube identity: the Google account it
is signed in to, or, when it is signed out, its anonymous visitor ID. melo reads
the browser's cookies when it needs them and keeps them in memory only; it does
not change them. melo then acts as that identity: with **Improve
recommendations** on, what you play shapes its recommendations, including in
that browser, and when signed in it is added to the account's YouTube history.

If you import browser cookies into a guest profile, that profile's folder holds
your Google session, and any process running as you can read it.
