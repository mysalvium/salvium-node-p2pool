# Supply-chain checks and SBOMs

This stack uses reproducible references and automated checks so an update is a
reviewed change, not an invisible download.

## What is pinned

- Ubuntu, Alpine, and Python bases use immutable multi-platform manifest
  digests in `.env.example`, the Dockerfiles, and `scripts/build-images.sh`.
- The P2Pool statistics source is pinned to a full reviewed commit.
- Python packages are exact-version locked and installed with
  `pip --require-hashes`.
- Trivy is pinned to a specific release archive and the archive must match the
  hardcoded SHA-256 value before it can execute.
- GitHub Actions use full commit SHAs rather than moving version tags.

The automatic Salvium and P2Pool binary updater has its own checksum checks;
see [`automatic-downloads.md`](automatic-downloads.md).

## Run the security gate

From the repository directory, after building the images:

```sh
./scripts/security-scan.sh .env full
```

This performs a secret scan, records configuration and dependency findings,
checks all five image filesystems, fails if a fixable critical image
vulnerability is present, and creates one SPDX JSON SBOM per image.

Reports go to `.security-reports/` and the scanner/database cache goes to
`.security-cache/`. Both are ignored by Git. On a no-execute staging mount,
set a root-owned executable cache explicitly:

```sh
SECURITY_CACHE_DIR=/trusted/root-only/path ./scripts/security-scan.sh .env full
```

Do not use a directory writable by an untrusted user for that cache.

## GitHub automation

`.github/workflows/security.yml` runs shell and Compose checks, builds the
pinned images, scans them, and retains the reports/SBOMs as a workflow artifact
for 30 days. It runs for pull requests, pushes to `main`, every Monday, and
manual dispatches.

Dependabot opens weekly proposals for Docker, Python, and GitHub Action
updates. A proposal is not permission to deploy it. Review the upstream release
and new digest, build, run the full scan, test the stack, and only then merge.

## Important limits

- A clean vulnerability scan is not proof that software has no vulnerability.
- The image gate blocks fixable critical findings; high-severity findings are
  retained in JSON for review rather than automatically breaking every build.
- SBOMs inventory components but do not make them trustworthy by themselves.
- Salvium/P2Pool release checksums come from the same upstream release channel
  as the archives. Independent signatures would provide stronger publisher
  authentication.
