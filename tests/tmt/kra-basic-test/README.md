# kra-basic-test (TMT / IPACTA + host pki-cli)

Port of FreeIPA generated IPACTA `kra-basic-test` into **pki-cli** for **manual** TMT.

- Image: `freeipa-ipacta` via `tests/tmt/bin/build-ipa-runner.sh` (shared with ca-basic)
- Helpers: `tests/tmt/bin/ipacta-tmt-common.sh`
- Host client: venv **`pki-cli`** from this repo
- Dogtag-only layout probes remain **OMITTED** / failure-collecting as in the freeipa port
- Host `pki-cli info` expected **exit 2** (java-bound) until REST exists

## Laptop checks (no Quay)

```bash
cd ~/Projects/pki-cli
tmt plans show '^/tests/tmt/plans/kra-basic-test$'
tmt lint '^/tests/tmt/plans/kra-basic-test$'
tmt lint '^/tests/tmt/kra-basic-test$'
tmt run --until discover plans --name '^/tests/tmt/plans/kra-basic-test$'
```

## Full local run

```bash
tmt --feeling-safe run -vvv \
  -e 'SKIP_IPA_BUILD=1 IPA_IMAGE=quay.io/agaragna77/freeipa-ipacta:TAG' \
  plans --name '^/tests/tmt/plans/kra-basic-test$'
```
