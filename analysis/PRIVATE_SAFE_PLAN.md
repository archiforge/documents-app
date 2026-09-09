# Private Safe implementation plan

Status: approved and implemented. DocumentsApp, Manage, and document actions
are integrated. All 21 Safe storage, recovery, session, and audit tests pass;
phone and iPad UI follow-ups pass. Physical-device authentication and system
file-protection behavior remain unverified; see [current evidence](CURRENT_STATUS.md).

## Approved product boundary

Private Safe stores an encrypted **copy** in the app sandbox. Adding a copy
never moves, encrypts, trashes, or deletes the source; deleting a Safe item
deletes only that copy. Originals remain available unless the user separately
deletes them through the existing document flow. V1 is local-only:

- Unlock uses Face ID or device passcode through LocalAuthentication.
- Lock occurs when every connected scene is actually backgrounded, or when
  protected data becomes unavailable. `foregroundInactive` only privacy-covers
  Safe during Face ID/system sheets; it must not cancel an unlock.
- The master key is not synced, backed up, escrowed, or recoverable through an
  account, server, password, or support override.
- Safe is a copy/view/export surface. In-place editing and source encryption
  are separate decisions.

## Repository fit and storage

Implement a new `Core/PrivateSafe/` actor without changing `SchemaV3`,
`DocumentRecord`, `FolderGrant`, or migration history. Resolve app-owned
sources through `DocumentStore.fileBridge`; keep security-scoped access alive
for external sources. Safe must not change source paths, trash state, or
`DeviceLibraryService` metadata.

Use `Library/Application Support/PrivateSafe/v1/`, never Documents:

```text
manifest.safe                 authenticated encrypted index
blobs/<item-uuid>.safe        encrypted payloads with canonical names
transactions/<operation>.json journals and delete staging
pending/                       same-volume write staging
Caches/PrivateSafe/views/     short-lived decrypted viewer files
Caches/PrivateSafe/exports/   short-lived plaintext export files
```

Create only regular files/directories, reject symlinks, apply
`URLFileProtection.complete`, and set backup exclusion at each final path
because rename/file operations can reset it. Startup cleanup follows only the
known cache roots and never follows links. While locked it may remove only a
clearly marked plaintext or incomplete scratch file; it retains every
encrypted blob, manifest, pending encrypted blob, journal, and delete-staged
blob until authenticated recovery.

## Key and file format

Generate one random 256-bit key and store its raw 32 bytes in a create-only
Keychain generic-password item:

```text
service = com.docdeck.app.private-safe
account = master-key-v1
synchronizable = false
accessibility = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
access control = kSecAccessControlUserPresence
```

Put accessibility in `SecAccessControlCreateWithFlags`; do not duplicate a
weaker accessibility attribute. Read with a fresh `LAContext` via
`kSecUseAuthenticationContext`. If the item is missing while Safe files exist,
report `keyUnavailable`; never make a replacement key or show an empty vault.
`NSFaceIDUsageDescription` belongs in `ios/project.yml` when implementation
starts. Do not log or persist passwords, biometric results, passcodes, or key
bytes.

Use CryptoKit only. Derive a per-item AES-GCM key with HKDF-SHA256 from the
master key, a versioned salt, and the item UUID as info. Encrypt plaintext in
1 MiB chunks; each record contains a fresh 12-byte nonce and sealed-box
combined bytes preceded by its length. The header authenticates format
version, item UUID, chunk size, and each chunk's index/length as AAD. The
manifest is a separately sealed Codable index containing generation, item UUID,
display name/type, byte count, date, and optional source record ID; each item
is bound to its canonical `<item-uuid>.safe` blob. The parser rejects unknown
versions, truncated/impossible lengths, duplicate/out-of-order chunks,
tampered AAD/ciphertext, and a final byte count that differs from the manifest.

## Add, read, delete, and recovery

`PrivateSafeStore` is an actor. The main actor passes only Sendable values;
encryption/decryption is streamed without a plaintext staging copy.

**Add a copy:** validate a regular source, record an `add/prepared` journal,
stream to a same-volume pending blob, apply protection/backup exclusion, close
and atomically rename it to its canonical final name, then atomically replace an
authenticated manifest generation and mark `manifestCommitted`. Remove the
journal only after cleanup. On error/cancellation remove only exact pending
paths created by that operation; retain unknown encrypted payloads. The source
and prior manifest remain intact.

**Read:** unlock once into an in-memory manifest. Decrypt bounded data for a
viewer or a random file under `Caches/PrivateSafe/views`; delete that file on
lease end, cancellation, lock, and next launch. Never create a `DocumentRecord`
or device-library/Recent/thumbnail entry.

**Delete:** journal `delete/prepared`, atomically rename the blob to a
delete-staged transaction path, replace the authenticated manifest without the
item, then delete the staged blob. Deleting a source uses ordinary
`DocumentStore` trash and is never implicit.

**Crash recovery:** a plaintext journal stage is not deletion authority: a
crash can commit the authenticated manifest before the journal update. At a
locked launch retain all encrypted state and clean only proven plaintext or
incomplete scratch. After unlock, authenticate active, pending, and previous
manifest candidates, select the highest valid generation, and use journals only
as corroborating evidence. Clean a transaction payload only when its exact
UUID paths and AEAD envelope match an authenticated item. Restore a
delete-staged blob when the selected manifest still references it; remove it
only when that manifest excludes it. Retain unknown or unreferenced encrypted
blobs and malformed journals as quarantined state; never infer deletion from a
filename.

## Locking and plaintext export

`PrivateSafeSession` is `@MainActor @Observable`. It holds the key only while
unlocked, clears the in-memory index and viewer URLs on lock, invalidates its
`LAContext`, increments a generation, and cancels/awaits child work before
releasing state. Every operation captures that generation and checks
cancellation plus generation after authentication, I/O, decryption, and
before publishing. Aggregate scene state, rather than one scene's transition,
drives background locking.

Export requires an unlocked explicit action and warns that a recipient may
retain plaintext. Decrypt to a random protected file under `exports/`, present
the existing exporter/share surface, and remove the file on completion,
cancellation, failure, dismissal, lock, and next-launch sweep. Never write
plaintext to Documents, iCloud, the manifest, thumbnails, or logs. A share
extension may retain its own copy after the app deletes its temporary file.

## Migration, UI, and tests

`WhenPasscodeSetThisDeviceOnly` items do not migrate through backup and are
removed when the passcode is removed; a later passcode cannot recover the key.
`userPresence` permits current Face ID or passcode fallback and avoids
`biometryCurrentSet` key loss. A new device or missing key shows unavailable;
only a clearly destructive, warned reset may remove all Safe files and the
Keychain item. There is no recovery code or cloud key recovery.

Manage should show a locked Private Safe row (no names/thumbnails/count until
unlock), an unlocked list, and status/reset controls. Document actions add
“Save a copy to Private Safe”; Safe deletion and export are separate actions.
Use semantic colors, SF Symbols, Dynamic Type, and accessible labels.
Tests use injectable Keychain, scene snapshot, filesystem, and fault seams; cover zero/one-byte and exact 1 MiB/multi-chunk round trips, wrong key,
AAD/nonce/order/tamper/truncation/count failures, transaction-stage faults, relaunch recovery, source retention, no Recent/device-library adoption,
generation cancellation, export cleanup, and multi-scene privacy behavior.
Simulator tests fake auth; paired-device checks cover Face ID/passcode, file protection, passcode removal, migration, and share/export lifecycle.
Official references: [Keychain accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility), [`kSecAccessControlUserPresence`](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/userpresence), [`LAContext`](https://developer.apple.com/documentation/localauthentication/lacontext), [`AES.GCM.SealedBox`](https://developer.apple.com/documentation/cryptokit/aes/gcm/sealedbox), and [background UI protection](https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background).
