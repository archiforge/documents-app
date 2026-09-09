# NativeArchives

`NativeArchives` is the app's local SwiftPM package for reading unencrypted
7-Zip and RAR4/RAR5 archives. It builds a small C ABI over libarchive with
liblzma enabled, then packages the result as an iOS device and simulator
XCFramework. The Swift facade streams decompressed bytes and rejects unsafe
paths, links, special files, overwrites, and oversized archives.

The generated XCFramework is intentionally ignored. A fresh checkout must
bootstrap it before running XcodeGen or building the app:

```sh
cd ios/Packages/NativeArchives
./Scripts/bootstrap.sh
cd ../..
xcodegen generate
```

The bootstrap pins the official libarchive 3.8.9 source release and XZ Utils
5.8.3 source release by SHA-256. It builds only arm64 iOS device and arm64
iOS Simulator slices. RAR extraction is read-only and encrypted archives are
not supported by the app flow.

## Notices

libarchive is distributed under the permissive license and source-specific
notices reproduced in its `COPYING` file. XZ Utils/liblzma is BSD Zero Clause
(0BSD) licensed. The bootstrap keeps the upstream source notices alongside
generated artifacts; the relevant checked-in texts are in `License/`.
The same texts are packaged under `Sources/NativeArchives/Resources/` so the
app's distributed package bundle carries the notices with the native reader.
