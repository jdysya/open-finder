# WebDAV Provider Notes

The implemented `WebDAVProvider` and settings/browser wiring cover the V0 remote-provider contract from `docs/plan.md`:

- `PROPFIND` with `Depth: 1` for directory listing.
- `MKCOL` for folder creation.
- `DELETE` for delete.
- `MOVE` and `COPY` with encoded `Destination` headers and `Overwrite: F` by default so conflicts are not silently replaced.
- `PUT` upload and `GET` download.
- Settings UI for adding/removing accounts and opening an account in the active pane.
- Active-pane browsing of WebDAV directories and local/WebDAV transfer routing through the task queue.
- Basic Auth credentials read through the `KeychainStore` protocol; credentialed accounts require HTTPS unless an explicit insecure development option is set.
- XML `207 Multi-Status` parsing tolerant of namespace prefixes, current-directory self entries, and child failure statuses.

Security posture:

- Passwords/tokens should be stored via `MacKeychainStore` or another `KeychainStore` implementation.
- HTTPS certificate errors are not bypassed.
- Remote preview should download to a cache directory before previewing; direct remote Quick Look is intentionally out of scope for V0.

Known V0 boundaries:

- Upload/download progress is represented as task completion today; byte-level streaming progress belongs in the next transfer integration pass.
- Server-specific quirks should be covered with provider tests before adding compatibility branches.
