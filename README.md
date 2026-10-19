# pki-cli

Python PKI CLI (Dogtag-shaped) aimed at talking REST to IPACTA.

Personal POC repository (`agaragna77/pki-cli`). Intended upstream home later: dogtagpki.

## Licence

Repository license: GPLv2 (see `LICENSE`). Copied Dogtag Python modules retain their original file headers (typically LGPLv3+).

## Source snapshot

The `src/pki` tree was copied from Dogtag `base/common/python/pki` at commit:

```
b038dcd53aa8fbf3c101cee13dbd416ee247f047
```

Local Dogtag checkout used: `~/Projects/pki`.

## Development install (venv required)

Do **not** mix this with a system `python3-dogtag-pki` install in the same interpreter. Always use a dedicated venv:

```bash
cd ~/Projects/pki-cli
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
pki-cli --help
```

Binary name is `pki-cli`; the import package remains `pki` (Dogtag-compatible).

## Status

Scaffold: editable install and `pki-cli --help`. Pure-Python REST path, TMT plans, and catalogue land in follow-up PRs.
