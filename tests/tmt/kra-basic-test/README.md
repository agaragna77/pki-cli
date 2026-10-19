# kra-basic-test (Dogtag steps × IPACTA × host pki-cli)

**Source of truth:** Dogtag [`tests/tmt/kra-basic-test`](https://github.com/dogtagpki/pki)
/ [GHA kra-basic-test.yml](https://github.com/dogtagpki/pki/blob/master/.github/workflows/kra-basic-test.yml)
(copied from local `~/Projects/pki` at `b038dcd53aa8fbf3c101cee13dbd416ee247f047`).

**Not** the FreeIPA-generated IPACTA port.

## Adaptation

| Dogtag | This repo |
|--------|-----------|
| `pki-runner` + DS sidecar | `freeipa-ipacta`; DS steps **OMITTED** |
| `pkispawn` CA / KRA | `ipa-server-install` / `ipa-kra-install` |
| `pkidestroy` | IPA uninstall (KRA step OMITTED; removed with CA) |
| `docker exec pki pki …` | host **`pki-cli …`** (exit 2 = java-bound) |
| `pki-server` / Tomcat layout | fail-collect (java-bound / api-gap) |

## Laptop

```bash
cd ~/Projects/pki-cli
tmt plans show '^/tests/tmt/plans/kra-basic-test$'
tmt lint '^/tests/tmt/plans/kra-basic-test$'
tmt lint '^/tests/tmt/kra-basic-test$'
tmt run --until discover plans --name '^/tests/tmt/plans/kra-basic-test$'
```

## Full run

```bash
docker image inspect freeipa-ipacta:latest >/dev/null
tmt --feeling-safe run -vvv -e SKIP_IPA_BUILD=1 \
  plans --name '^/tests/tmt/plans/kra-basic-test$'
```

Expect non-zero while client REST and Dogtag layout gaps remain.
