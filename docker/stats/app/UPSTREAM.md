# Statistics source snapshot

This directory is the reviewed statistics application that was running in the
production stack on 2026-09-03.

- Upstream: `https://github.com/trevorwilf/p2pool-salvium`
- Upstream branch at capture: `updatestatistics`
- Source commit: `a0fed9e186fa85d16eefdaf62bd6dbecadb629af`

The source is vendored so production startup does not pull a moving branch and
image builds do not require access credentials for the upstream repository.
Configuration is read from environment variables; no production tokens or
machine-specific addresses are included in this snapshot.
