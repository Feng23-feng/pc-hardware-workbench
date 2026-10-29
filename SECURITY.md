# Security policy

## Supported version

Security fixes target the current release candidate and the latest published
stable version after release.

## Report privately

Do not open a public issue for:

- a path-boundary bypass;
- command or Markdown injection through a filename, volume label, device name,
  CSV header, or warning;
- privacy-redaction failure;
- accidental network access or cloud-file hydration;
- unsafe guidance that could cause hardware damage;
- a bundled artifact with an unexpected hash or signature.

Use GitHub private vulnerability reporting after the repository is published.
Until then, send the maintainer a minimal private report outside the public
issue tracker.

Include:

- affected version;
- minimal synthetic reproduction;
- expected and observed behavior;
- impact and prerequisites;
- whether the issue can be verified without live hardware collection.

Do not include real serial numbers, passwords, API keys, private paths, full
telemetry dumps, or unrelated personal data.
