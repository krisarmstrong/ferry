# Ferry

Ferry mounts Android phones over MTP so they appear in Finder on macOS.

## Build

Requires macOS 26 and Xcode with Swift 6.4.

```sh
brew install libmtp swiftlint
make build
make test lint fmt-check
```
