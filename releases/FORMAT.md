# Release manifest format (version 1)

A suite release is described by exactly one immutable file, `releases/<suite-version>/manifest.tsv`.

- The format is line-oriented and tab-separated, so the POSIX installer can parse it without `jq` or Python.
- `scripts/lib/manifest.sh` is the reference validator.
- `tests/check-manifests.sh` enforces the rules on this directory.

## Encoding

- Printable ASCII, the tab character, and LF line endings. CR or CRLF is rejected.
- The file must end with a newline. Blank lines and comments are not allowed.

## Lines

```text
luuna-suite-manifest<TAB>1
suite<TAB><suite-version>
asset<TAB><component><TAB><component-version><TAB><os><TAB><arch><TAB><url><TAB><sha256><TAB><archive-file-name><TAB><executables>
...
```

| Field | Rule |
| --- | --- |
| `suite-version`, `component-version` | `MAJOR.MINOR.PATCH` with an optional `-prerelease` (`[0-9A-Za-z.-]`), at most 64 characters. The suite version must equal the `<suite-version>` directory name. |
| `component` | `atlas`, `beacon`, `missions` or `roots` |
| `os` | `darwin` or `linux` |
| `arch` | `arm64` or `amd64` |
| `url` | `https://github.com/brodynelly/luuna-<component>/releases/download/<tag>/<archive-file-name>` |
| `sha256` | 64 lowercase hex characters: the SHA256 of the archive at `url` |
| `archive-file-name` | `luuna-<component>_<component-version>_<os>_<arch>.tar.gz` |
| `executables` | Comma-separated. Must include the primary, may include the public alias, and nothing else. |

Each `(component, os, arch)` appears at most once. To install on a platform, all four components must be present for it. Otherwise the installer exits 3 (unsupported platform).

### Public executable set

| Component | Primary | Public alias |
| --- | --- | --- |
| atlas | `luuna-atlas` | `lat` |
| beacon | `luuna-beacon` | `lbc` |
| missions | `luuna-missions` | `lms` |
| roots | `luuna-roots` | `lrt` |

The following names are never valid in a manifest:

- `luuna` and `lu`, which belong to the private runtime
- the generic source aliases `la`, `lb`, `lm` and `missions`

The hub dispatcher `luuna-suite` comes from this repository, not from an archive.

## Archives

Each archive is a gzip-compressed tar. Its only entries are an optional `bin/` directory and `bin/<executable>` regular files, one for each listed executable.

The installer rejects the archive (exit 5) before extracting anything if it contains any of the following:

- an absolute path or a `..` segment
- a symlink, hardlink or device
- a duplicate entry
- any other entry

## Index and immutability

`releases/INDEX.tsv` starts with the header `#suite-version<TAB>manifest-sha256`. It has one line for each release: `<suite-version><TAB><sha256 of manifest.tsv>`.

`tests/check-manifests.sh --base <ref>` enforces these rules:

- Every manifest validates and matches its index hash, and versions are unique.
- Against the base ref, files under `releases/<v>/` may only be **added**.
- `INDEX.tsv` may only gain appended lines.

A published manifest is never edited. A fix ships as a new suite version.

## Example (illustrative only: not a real release, placeholder checksum)

```text
luuna-suite-manifest	1
suite	1.2.3
asset	atlas	1.2.3	linux	amd64	https://github.com/brodynelly/luuna-atlas/releases/download/v1.2.3/luuna-atlas_1.2.3_linux_amd64.tar.gz	<64 lowercase hex>	luuna-atlas_1.2.3_linux_amd64.tar.gz	luuna-atlas,lat
```
