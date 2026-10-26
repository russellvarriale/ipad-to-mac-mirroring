# Contributing

Build and test instructions are in [README.md](README.md). Keep changes small,
explain the user-visible behavior, and include relevant validation.

- Preserve the single-window workflow and video-only/local-preview scope.
- Keep network inputs, IPC frames, buffering, and UI event delivery bounded.
- Keep Stop/quit/parent-death cleanup scoped to the owned receiver.
- Use generated test media, never personal iPad captures or live pairing codes.
- Preserve upstream notices and [the license boundaries](LICENSES.md).
- Do not commit built apps, dependency downloads, runtime caches, credentials,
  raw diagnostics, or private screenshots.

For UI changes, include screenshots with generic sample content and confirm
Clean View and the recorder's window preview. Security reports should follow
[SECURITY.md](SECURITY.md) instead of exposing private details in public issues.
