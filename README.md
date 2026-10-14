# Haul

Haul is a free download manager for the Mac, by Zewify.
It takes the downloads your browser starts and fetches them over several connections at once, pauses and resumes them, keeps them in a queue, and grabs video from pages.

- **Fast.** Each file is split into segments that download in parallel, and idle connections take over the tail of busy ones.
- **Resumable.** Pause, lose the connection, or quit: Haul carries on from where it stopped.
- **In your browser.** An extension for Chrome, Edge, Brave, Arc and Vivaldi, and one for Safari inside the app, hand downloads over as you click them, cookies included, so files behind a login just work.
- **Video.** Streams a page plays show up in the extension's popup; separate video and audio tracks are joined into one file on your Mac, without re-encoding.
- **Private.** Haul talks to its extension on your own Mac only. Nothing is sent anywhere.

## Install

Haul needs macOS 15 or later.
Installation instructions live at https://zewify.com/haul/.

The Chrome extension is the `Extension` folder of this repo: open `chrome://extensions`, turn on Developer mode, choose Load unpacked, and pick that folder.
Safari's copy is inside the app; turn it on in Safari → Settings → Extensions.

## Build from source

You need Xcode and XcodeGen (`brew install xcodegen`), and Node for the extension's tests.

- `./scripts/test.sh` runs every check and the tests.
- `./scripts/install-local.sh` builds a Release copy into `/Applications` and opens it.

## Privacy

Haul downloads what you ask it to and keeps its list on your Mac.
The extension sends a download's address and that site's cookies to the app on your own Mac, so the download works as it would in the browser; neither goes anywhere else.
The only other request is the installer's, and a future update check's, to GitHub.

## Licence

Haul is source available, not open source.
The source is published so you can read exactly what the app does, and build it for yourself.
Zewify keeps all rights to it; no licence to copy, modify or redistribute it is granted.
