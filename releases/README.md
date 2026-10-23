# Releases

**No suite releases are published.** This directory holds:

- `FORMAT.md`, the manifest format
- `INDEX.tsv`, which is header-only

Manifests are added only through the owner gate in [docs/RELEASING.md](../docs/RELEASING.md). Each one comes from real, released component assets, so its URLs and SHA256s are copied from those assets and never invented. It arrives through a reviewed PR that appends one line to `INDEX.tsv`.

`sh tests/check-manifests.sh` validates this directory. With `--base <ref>`, it also enforces that releases are append-only.
