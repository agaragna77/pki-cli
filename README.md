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

Scaffold: editable install and `pki-cli --help`. Catalogue skeleton is in-tree; Java gate, TMT plans, and REST land in follow-up PRs.

## Result catalogue

YAML source of truth: `catalogue/results.yaml`.

Allowed statuses: `pass` | `rest-defect` | `api-gap` | `java-bound`.

```bash
source .venv/bin/activate
pip install -e .   # provides PyYAML for scripts
python scripts/catalogue_regen.py
python scripts/catalogue_propose.py --command 'pki-cli info' --status java-bound --notes 'gated' --dry-run
```

Humans must classify `rest-defect` vs `api-gap` (`--confirm-classification` to finalize).
Generated Markdown: `catalogue/RESULTS.md` (do not hand-edit).
