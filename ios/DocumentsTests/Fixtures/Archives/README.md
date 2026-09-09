# Archive fixtures

`lzma2.7z` and `rar4.rar` are small unencrypted fixtures copied from the
Homebrew test fixture set at
`Library/Homebrew/test/support/fixtures/cask/container.7z` and
`container.rar`. Homebrew is distributed under the BSD-2-Clause license; the
full upstream notice is included in `HOMEBREW-LICENSE.txt` beside these
fixtures. These files contain only the test payload used by the upstream
fixture.

`rar5.rar` is decoded from libarchive's BSD-2-Clause test fixture
`test_read_format_rar5_win32.rar.uu`:

https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar5_win32.rar.uu

`hardlink.tar` is a local test-only fixture with one regular file and one
hard-link entry. It exercises the native reader's link rejection and is not an
archive format offered by the app UI.

The fixtures are used only to prove format and codec support. Extraction still
rejects links, special files, unsafe paths, overwrites, and oversized output.
