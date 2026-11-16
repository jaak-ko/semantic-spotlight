SEMANTIC SPOTLIGHT
==================

Search your own files by meaning, from anywhere on your Mac.
Everything runs on this Mac. Your files never leave it.

INSTALL
1. Drag SemanticSpotlight.app onto the Applications folder next to it.

FIRST LAUNCH (one time only)
This app is not notarized by Apple, so macOS asks you to confirm it once.

  macOS 14:         In Applications, right-click (or Control-click)
                    SemanticSpotlight, choose Open, then click Open again.

  macOS 15 and later: right-click may not offer Open. Then double-click the
                    app once (it will be blocked), open System Settings >
                    Privacy & Security, scroll down to the message about
                    SemanticSpotlight, click Open Anyway, and confirm.
                    You only do this once.

  If macOS says the app is "damaged" and cannot be opened, open Terminal and run:
      xattr -dr com.apple.quarantine /Applications/SemanticSpotlight.app

SETUP
A welcome screen appears on first launch. It asks you to:
  1. Download the language model (about 470 MB, one time). This is the only
     download the app ever makes, and it only happens when you click the button.
  2. Choose a folder to index. Files are only read, never changed.
  3. Search with Option+Space.

Your index and settings are stored in ~/.semsearch/ on this Mac.

UNINSTALL
Open Settings (from the menu bar icon), go to the Uninstall section at the
bottom, and click "Uninstall Semantic Spotlight…". The dialog lists everything the app created, with sizes, before
anything is deleted. That is the search index and settings, the downloaded
model, preferences, caches, the GPU shader caches the engine causes (rebuilt automatically),
and the app itself. Your own files and folders
are never touched, including the folders you indexed.

LICENSE and THIRD_PARTY_NOTICES.md (the licenses of the software inside) are
in this disk image next to this README.
