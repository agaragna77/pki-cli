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

## TMT (manual)

Dogtag-rooted plan: `tests/tmt/plans/ca-basic-test` (IPACTA backend + host `pki-cli`).

```bash
tmt plans show '^/tests/tmt/plans/ca-basic-test$'
tmt lint '^/tests/tmt/plans/ca-basic-test$'
tmt run --until discover plans --name '^/tests/tmt/plans/ca-basic-test$'
```

See `tests/tmt/ca-basic-test/README.md`. No GHA in this repo yet.

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

### Java MainCLI gate

Remote commands that still went through Dogtag Java `MainCLI` are refused with exit status 2.
Record them as `java-bound`:

```bash
pki-cli info   # expected: ERROR … Java MainCLI path is disabled; exit 2
python scripts/catalogue_propose.py --command 'pki-cli info' --status java-bound --notes 'gated'
python scripts/catalogue_regen.py
```
