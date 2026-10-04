# Changelog

## Alpha 3.1

- Fixed blurry artwork in Now Playing

## Alpha 3

### Added

- Updates through apt, dnf, zypper and pacman
- A splash screen while melo starts
- Mini player gesture in the setup window
- Clear button for shortcuts
- Startup cache for AppImages
- Mouse wheel on inset boxes in the theme editor

### Changes

- Improved glyph rendering
- Improved browser cookie reading
- Assigning a key that is already in use removes it from its previous shortcut
- Much faster sorting, filtering and opening playlists in large libraries
- Adjusted scrollbar placement
- The .deb and .rpm file names carry the version

### Fixes

- Fixed melo briefly showing default settings on launch
- Fixed the queue's Q key not showing in Shortcuts
- Fixed songs not playing when the home disk is nearly full
- Fixed some long videos not playing
- Fixed yt-dlp leaving files in /tmp and running after melo quits
- Fixed plugins running after melo quits
- Fixed Play All and Shuffle ignoring the library's sort and filter
- Fixed resize instability after switching to the mini player and back
- Fixed the setup window's Colour choice always showing System
- Fixed the Mini player shortcut not showing the gesture that is bound
- Fixed None not turning off the mini player gestures
- Fixed a stale frame in the account drop-down
- Fixed layers disappearing after being moved past a filter layer
- Fixed bar drags reaching Now Playing while arranging the player bar
- Fixed recommendations after resetting the guest session
- Fixed unstable mini bar resize after closing the visualiser

## Alpha 2.2

- Fixed playback on Arch-based distributions
- Added updates through AppImageUpdate and Gear Lever

## Alpha 2.1

- Fixed the full AppImage not opening in AppImage tools

## Alpha 2

### Added

- Pin button on GNOME, Cinnamon, labwc, Pantheon, Budgie and XFCE on Wayland
- First-run yt-dlp download progress
- AppStream metadata in the AppImages and packages

### Changes

- yt-dlp installs and updates only from the signed release
- The deb and rpm bundle Node
- Where melo cannot place windows, the mini player's queue opens the full player

### Fixes

- Fixed glass blur on Plasma 6.7, GNOME 51 and Plasma 6 X11
- Fixed the pin button outside Plasma 6 on Wayland
- Fixed the mini player's placement on Plasma 6 X11
- Fixed yt-dlp errors on first start and on distros that ship an old yt-dlp, such as Mint
- Fixed AAC playback and the Node download on first start for the deb and rpm
- Fixed maximising on GNOME X11
- Fixed the number of loading placeholders in a fresh window

## Alpha 1

First release.
