# Changelog

## Alpha 4.3

### Fixes

- Fix some languages and regions, such as English (UK), Hebrew and China, breaking search or falling back to English
- Fix a yt-dlp config file changing melo's downloads and cookies
- Fix melo ignoring a proxy set in HTTPS_PROXY
- Fix YouTube's cookie consent page blocking guests in Europe
- Fix the search filters that gave wrong or empty results
- Fix importing browser cookies not finding Firefox, breaking Home or missing your YouTube recommendations
- Fix Home not loading for new guests

## Alpha 4.2

### Startup Fixes

- Fix melo crashing on its first start on older systems

## Alpha 4.1

### Known Issues

On X11 desktops without a compositor, the splash shows a black box around the logo.

### Interface Fixes

- Fix titles with HTML tags losing words or turning italic
- Fix some titles showing HTML codes instead of their characters
- Fix the queue's background changing when it opens in its own window

### AppImage Updates and Fixes

- Add an AppImage that runs on any Linux distribution
- Fix yt-dlp downloading again on every request when it cannot run

### Build and Packaging Improvements

- Allow building with Qt 6.8
- Add GMP's source to the release sources archive

## Alpha 4

### Playback Updates and Fixes

- Use the higher-quality audio of YouTube Premium accounts
- Fix tracks that start behind a YouTube ad failing to play
- Fix some tracks stopping just before the end
- Fix playback freezing when a stream stops sending
- Fix Try again freezing after a dropped stream
- Fix Retry starting the track again from the beginning
- Fix Play doing nothing after the queue ends
- Fix no sound at the first start until pause and play
- Fix media controls showing melo as playing after Stop

### Video Updates and Fixes

- Add video to Now Playing and the mini player
- Add a video quality setting
- Add a video fit setting
- Add video and visualizer transparency
- Add video snapshots
- Fix the cursor staying hidden over a video when it moves

### YouTube Music Updates

- Add YouTube Music search results
- Add YouTube Music suggestions and song radio
- Add YouTube Music albums and singles
- Add tagging from YouTube Music

### Account and Cookie Updates

- Allow playing and downloading with the browser's YouTube account
- Keep only YouTube's cookies from the browser
- Keep browser cookies off disk
- Read browsers only when the account menu opens

### Window and Mini Player Updates and Fixes

- Add queue, visualizer and video windows
- Allow resizing the mini player with the queue or visualizer open
- Restore windows at startup
- Add click-through mode
- Fix windows wobbling during resize on X11
- Fix black windows at launch
- Fix windows opening behind melo or showing on the taskbar
- Fix the mini player's popup jumping or vanishing during resize on X11
- Fix the layout shifting as melo starts
- Fix loading rows overlapping when melo opens maximised

### Interface Updates and Fixes

- Add picture glyphs
- Add a checkbox toggle style
- Add insets for view tabs, page tabs and the mini player
- Fix low-resolution art in Now Playing for saved tracks
- Fix menus cutting off their labels
- Fix menus staying open after a click outside them
- Fix the seek and slider knobs shimmering as they move
- Fix importing an exported built-in theme
- Remove the Paste URL action setting

### Error Reporting Updates

- Make errors say what to do
- Add Report… to every error
- Add a log file
- Add a Discord link to the bug form

### Plugin Updates

- Prevent plugins from changing settings, the library, themes or files

### Integration Updates

- Add Discord Rich Presence
- Turn Last.fm tagging off for new installs

### AppImage and Update Improvements

- Add AppImage updates
- Add an AppImage for musl, older distributions and systems without FUSE
- Add AV1 video to the full AppImage
- Fix balance doing nothing in the full AppImage

### Build and Packaging Improvements

- Update to Qt 6.12.0
- Set up melo's package repository when the deb or rpm installs

## Alpha 3.2

- Updated Node.js to 22.23.4, the October 2026 security release

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
