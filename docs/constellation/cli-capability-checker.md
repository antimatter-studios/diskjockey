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

This is the execution layer of #387, implemented by #401. It does not
download drivers or construct filesystem fixtures. #402 owns attested
release installation, SIBLING_PINS.txt entries, independent builders and the
measured seven-driver capability TSV. #403 owns CLI pipe workflow coverage
and the measured output budget. Until those follow-ups land, this checker
does not establish that any released driver implements a particular verb.
