# Security policy

## Reporting a vulnerability

Report it privately through GitHub: on the
[Security tab](https://github.com/krisarmstrong/ferry/security) choose **Report a vulnerability**.
Please do not open a public issue or pull request for a security problem.

Include the Ferry version (Ferry > About), your macOS version, and the steps to reproduce.
I will acknowledge a report within a week and keep you informed until it is fixed.

## In scope

- The Ferry app, the Ferry agent (`FerryAgent`) and the Finder extensions (File Provider and
  sync), including the XPC interface between them.
- Handling of data from a connected device: file names, paths and metadata from MTP and ADB.
- The update feed (`appcast.xml` on the GitHub releases) and the Sparkle update check.
- Release signing: the Developer ID signature, notarization, and the Sparkle EdDSA key, and the
  release workflow that uses them.

## Out of scope

- Findings that need an already compromised Mac or a modified copy of Ferry.
- Vulnerabilities in third parties (Sparkle, libmtp, libusb, Google's platform tools): report
  those upstream. If Ferry ships a vulnerable version, tell me.

## Supported versions

Only the latest release receives fixes.
