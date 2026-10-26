# Security and privacy

Use wireless mirroring only on a trusted local network. The four-digit pairing
code is a legacy AirPlay compatibility mechanism, not strong protection against
an adversary on the same network. Do not forward receiver ports to the Internet.

The viewer has no account, analytics, cloud relay, recording, remote-control, or
automatic-update implementation. It does not open the Mac camera/microphone.
Visible iPad notifications are part of the mirrored image and may be captured by
your recorder; your recorder has its own privacy/storage behavior.

See [SECURITY.txt](SECURITY.txt) for storage, permissions, and lifecycle details,
and [SECURITY-REVIEW.txt](SECURITY-REVIEW.txt) for the focused review, fixes,
validation, and known limitations. In particular, the wireless helper is not a
security sandbox, and an upstream stalled-request denial-of-service limitation
remains. Keep dependencies and regression tests current.

## Reporting a vulnerability

Do not put credentials, connection codes, device identifiers, personal captures,
or sensitive network traces in a public issue. Use the repository's private
vulnerability-reporting channel if the maintainer has enabled one. A dedicated
security contact has not yet been configured in this source package; configure
one before inviting private reports. Ordinary bugs can be reported with a
minimal reproduction using synthetic data.

## Publishing or contributing

Publish this source tree, not a development/chat workspace or an app's temporary
runtime directories. The prepared tree has no Git history or personal Git
identity. Your GitHub profile, commit author email, issues, and uploaded captures
can still identify you independently of clean code. Choose your intended public
Git identity before the first commit.
