# Automatic release downloads

The stack checks for new Salvium and P2Pool releases every six hours by
default. An updater restarts only the affected service when the upstream tag
differs from the persistent `.current_version` marker. The service entrypoint
then performs the download and verification.

## Verification guarantees

For Salvium:

1. Release metadata is retrieved from the official `salvium/salvium` GitHub
   API over HTTPS with TLS 1.2 or newer.
2. The Ubuntu x86-64 archive is selected by its release asset name.
3. The expected SHA-256 value is read from the same release's notes.
4. The downloaded archive must match that value before extraction.
5. The verified archive must contain a `salviumd` executable.

For P2Pool Salvium:

1. Release metadata is retrieved from the official project GitLab API over
   HTTPS with TLS 1.2 or newer.
2. The Linux x64 static archive and the release's SHA-256 manifest are selected.
3. The manifest must contain a valid entry for that exact asset filename.
4. The archive must match the published SHA-256 value before extraction.
5. The verified archive must contain a P2Pool executable.

A missing checksum, checksum mismatch, malformed archive, or missing executable
rejects the update. If a working binary is already installed, it remains in
service. Successful replacement uses an atomic rename and retains the old
binary with a `.previous` suffix.

These checks detect corrupt, partial, and mismatched artifacts. Because each
checksum comes from the same release channel as its archive, they do not defend
against compromise of that upstream publisher account. Independently signed
release metadata would provide a stronger authenticity guarantee.

## Non-installing end-to-end test

After building the images, run:

```sh
./scripts/verify-release-downloads.sh
```

The script starts disposable, read-only containers with
`VERIFY_RELEASE_ONLY=1`. Each entrypoint downloads the latest real upstream
release, verifies its checksum, tests extraction, confirms the expected binary
exists, and exits without installing or replacing anything.

Expected final messages include:

```text
Release <tag> passed checksum, archive, and binary-content verification.
Both upstream releases passed verification. No binary was installed.
```

The normal production startup path uses the same functions, selectors, and
checksum comparisons as this verification mode.

## Operational checks

```sh
docker logs --tail 100 salviumd
docker logs --tail 100 salvium-p2pool
docker logs --tail 100 salviumd-updater
docker logs --tail 100 p2pool-updater
```

Do not delete `.previous` until the replacement has run successfully through a
full maintenance and reboot test.
