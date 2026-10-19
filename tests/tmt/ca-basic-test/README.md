# ca-basic-test (TMT / IPACTA + host pki-cli)

Port of FreeIPA [`tests/tmt/ca-basic-test`](https://github.com/freeipa/freeipa)
IPACTA coverage into **pki-cli** for **manual** TMT (no GHA in this repo).

## Model

- One IPA container (`freeipa-ipacta`) — Directory Server + KDC + httpd + IPACTA.
- Host client: editable **`pki-cli`** from this repository (venv), not Dogtag Java `pki`.
- In-container `/usr/bin/pki` checks remain IPACTA drop-in verification.
- Host `pki-cli info` is expected to **exit 2** (Java MainCLI gated → catalogue `java-bound`) until pure-Python REST exists.

## Layout

| Path | Role |
|------|------|
| `tests/tmt/plans/ca-basic-test.fmf` | Plan (Docker, IPA image, host venv) |
| `tests/tmt/bin/build-ipa-runner.sh` | Fedora packages → `freeipa-ipacta` (or Quay pull) |
| `tests/tmt/ca-basic-test/` | Test (`main.fmf` + `test.sh`) |

## Laptop checks (no Quay)

```bash
cd ~/Projects/pki-cli
tmt plans ls | grep ca-basic-test
tmt plans show '^/tests/tmt/plans/ca-basic-test$'
tmt tests show '^/tests/tmt/ca-basic-test$'
tmt lint '^/tests/tmt/plans/ca-basic-test$'
tmt lint '^/tests/tmt/ca-basic-test$'
tmt run --until discover plans --name '^/tests/tmt/plans/ca-basic-test$'
```

## Full local run (Docker + image)

```bash
# Reuse Quay image (recommended)
tmt --feeling-safe run -vvv \
  -e 'SKIP_IPA_BUILD=1 IPA_IMAGE=quay.io/agaragna77/freeipa-ipacta:TAG' \
  plans --name '^/tests/tmt/plans/ca-basic-test$'

# Or build from Fedora packages in prepare (slow)
tmt --feeling-safe run -vvv \
  plans --name '^/tests/tmt/plans/ca-basic-test$'
```

Patterns match [JARVIS IDM-8254](https://github.com/) / `POCs/IDM-8254/README.md` on the workstation that tracks that runbook.

**Acceptable:** execute fails later on gated `pki-cli` REST commands (exit 2). Container IPACTA layout checks may still pass.
