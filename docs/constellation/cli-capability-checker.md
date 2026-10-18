# CLI capability execution contract

`scripts/cli-capability-matrix.sh --matrix FILE --images DIR` executes a TSV
against prepared images and tools on PATH. Install `jq` first. The entire
matrix is checked for missing inputs before any operation runs. Output goes
through this repository's `quiet-run.sh` to
`tmp/logs/cli-capability-matrix.log`; `--verbose` also streams it.

The first line is exactly these five tab-separated fields (`\t` below
denotes an actual tab):

```text
tool	fixture	exit	stdin	argv...
```

Each subsequent row contains a tool name (`fs.ext4`, for example), an image
filename, the expected exit (`0` supported or `3` refused), an stdin filename
or `-` for empty input, and one or more literal argument fields. Arguments
after the tool's TARGET each occupy their own tab-separated field. Spaces,
quotes and shell syntax inside a field remain literal; there is no shell
evaluation. Blank lines and lines starting with `#` are ignored. Empty
fields, carriage returns and paths outside the image directory are refused.
Fixtures and stdin files use simple filenames starting with a letter or
digit, followed by letters, digits, dots, underscores or hyphens.

For example, with tabs between columns:

```text
tool	fixture	exit	stdin	argv...
fs.ext4	ext4.img	0	-	stat	/data.bin
fs.erofs	erofs.img	3	-	rm	/data.bin
fs.ext4	ext4.img	0	payload.bin	write	--at	1	/data.bin
```

Every row receives a fresh writable image copy. A usage error (`2`) always
fails, as does any other exit that disagrees with the row. Exit `3` also
requires empty stdout, exactly one JSON error object on stderr with a
nonempty `error` string and numeric `code: 3`, and an image byte-identical
to the copy taken before invocation. The supplied source fixture is never
passed to the driver. The executor counts every row and refuses an empty
matrix or a run that stops short.

Add `--install` to run with all seven filesystem CLIs from the exact tags in
`SIBLING_PINS.txt`. This requires GitHub CLI with `gh attestation verify`
and `--source-ref` support, plus `tar` and a SHA-256 tool (`sha256sum` or
`shasum`). Supported hosts are darwin-arm64 and linux-x86_64. The installer
downloads each tag's platform archive and verifies its signed digest,
repository, shared `rust-fs-core/.github/workflows/release-cli.yml` signer,
and `refs/tags/<tag>` source ref before extraction. It never executes a
driver during installation. Missing or duplicate pins, unavailable assets,
failed attestations and missing executable binaries fail the run.

All seven releases must pass before any matrix operation runs. Installed
mode permits only those seven tool names and uses a private installation,
with no fallback to an existing driver on PATH. Only the `fs.*` commands
are exposed, so release-provided `mkfs.*` commands cannot shadow independent
builders. Exact tags, asset names, SHA-256 digests, signers and source refs
are retained in the capability log. The private installation is removed
on exit. Prepared-tool mode remains available without `--install`.

For a persistent installation, use
`bash scripts/install-cli-capabilities.sh --dest NEW_DIR`; it refuses an
existing destination and writes `NEW_DIR/releases.tsv` plus `NEW_DIR/bin`.
`--pins FILE` selects an alternate pins file for installer guards.

This is the execution layer of #387 (#401) and its verified release
installation layer (#488, part of #402). Independent fixture builders are
tracked in #489–#495, and the measured seven-driver capability TSV in #496.
#403 owns CLI pipe workflow coverage and the measured output budget. Until
those follow-ups land, this checker does not establish that any released
driver implements a particular verb.
