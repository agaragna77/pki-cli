# ca-basic-test (Dogtag steps × IPACTA × host pki-cli)

**Source of truth:** Dogtag [`tests/tmt/ca-basic-test`](https://github.com/dogtagpki/pki)
/ [GHA ca-basic-test.yml](https://github.com/dogtagpki/pki/blob/master/.github/workflows/ca-basic-test.yml)
(copied from local `~/Projects/pki` at `b038dcd53aa8fbf3c101cee13dbd416ee247f047`).

**Not** the FreeIPA-generated IPACTA port.

## Adaptation

| Dogtag | This repo |
|--------|-----------|
| `pki-runner` + DS sidecar | `freeipa-ipacta` (IPACTA embeds DS); DS steps **OMITTED** |
| `pkispawn` / `pkidestroy` | `ipa-server-install` / uninstall |
| `docker exec pki pki …` | host **`pki-cli …`** (exit 2 = java-bound until REST) |
| `pki-server` / Tomcat layout | kept by step name; **fail-collect** (java-bound / api-gap) |
| Container name `pki` | kept (IPACTA image) for `docker exec` reuse |

## Laptop (no Quay)

```bash
cd ~/Projects/pki-cli
tmt plans show '^/tests/tmt/plans/ca-basic-test$'
tmt lint '^/tests/tmt/plans/ca-basic-test$'
tmt lint '^/tests/tmt/ca-basic-test$'
tmt run --until discover plans --name '^/tests/tmt/plans/ca-basic-test$'
```

## Full run

Prefer a local image if you already have one (this machine often has `freeipa-ipacta:latest`):

```bash
docker image inspect freeipa-ipacta:latest >/dev/null
tmt --feeling-safe run -vvv -e SKIP_IPA_BUILD=1 \
  plans --name '^/tests/tmt/plans/ca-basic-test$'
```

Or pull a real Quay tag (not a placeholder). Current example on
`quay.io/agaragna77/freeipa-ipacta`:

```bash
IPA_IMAGE=quay.io/agaragna77/freeipa-ipacta:idm-8254-tmt-ca-basic-1bc6b548f
tmt --feeling-safe run -vvv \
  -e "SKIP_IPA_BUILD=1 IPA_IMAGE=${IPA_IMAGE}" \
  plans --name '^/tests/tmt/plans/ca-basic-test$'
```

List tags: `skopeo list-tags docker://quay.io/agaragna77/freeipa-ipacta`

Or let prepare **build** from Fedora packages (slow; no prebuilt image needed):

```bash
tmt --feeling-safe run -vvv \
  plans --name '^/tests/tmt/plans/ca-basic-test$'
```

Expect non-zero overall while client REST and Dogtag layout gaps remain — that is OK for this PR.
