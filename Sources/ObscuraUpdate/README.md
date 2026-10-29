# ObscuraUpdate

Obscura's own update check and verified install (G-33, roadmap B-8). See `knowledge/spec/ARCHITECTURE.md` § Updates.

- `UpdateManifest.swift`: the signed feed format, version comparison, `FeedVerifier` (signature first, then fields), `FeedSigner`.
- `UpdateTransport.swift`: the only network code — HTTPS GETs, same-host HTTPS redirects only, capped and hashed while streaming.
- `DiskImage.swift`: read-only `hdiutil attach -nobrowse` into the private update folder.
- `CodeVerifier.swift`: `SecStaticCodeCheckValidity` against the running app's own designated requirement; hardened runtime, no exceptions.
- `UpdateInstaller.swift`: check, install (download → verify → atomic swap with a rollback copy), settle after relaunch.
- `Relauncher.swift`: opens the new app after this one quits; restores the rollback copy if macOS refuses it.
