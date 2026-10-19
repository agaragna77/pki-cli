# Spike: thin IPACTA + Directory Server (no FreeIPA)

**Date:** 2026-10-19  
**Question:** Can IPACTA run with only IPACTA + 389 Directory Server — no
full FreeIPA / no `ipa-server-install` — for pki-cli TMT?

## Conclusion

**Blocked** for a supported thin deploy today.

Standalone IPACTA+DS is an incomplete / undocumented path. The supported
install story is FreeIPA + `ipa-server-install` with packaged IPACTA
providing `pki-ca` / `pki-kra` / `pki-acme`.

## Fallback (current TMT)

Keep using:

- Image: `tests/tmt/bin/build-ipa-runner.sh` → `freeipa-ipacta:latest`
  (Fedora packages: `freeipa-server` + `ipacta` + `freeipa-healthcheck`)
- Install: `ipa-server-install` (+ `ipa-kra-install` for kra-basic)
- Plans: `tests/tmt/plans/ca-basic-test`, `tests/tmt/plans/kra-basic-test`

Treat “no FreeIPA” as **future packaging/product work** (M2+), not a M1
TMT prerequisite.

## Evidence

### 1. Documented install is FreeIPA-only

From upstream `ipacta` README (“Installation with FreeIPA”):

```text
dnf install ipacta freeipa-server
ipa-server-install
```

`doc/installation.md` opens with: ipacta is installed as part of FreeIPA’s
`ipa-server-install` / `ipa-replica-install`.

Runtime docs list **389 Directory Server** as a dependency, but do not
document a DS-only bootstrap that replaces FreeIPA.

Sources (local checkout `~/Projects/ipacta`):

- `README.md` — Installation with FreeIPA
- `doc/installation.md` — FreeIPA-orchestrated install

### 2. Packaging allows IPACTA without Requires: freeipa-server

`ipacta.spec.in` (meta package):

- **Provides:** `pki-ca`, `pki-kra`, `pki-acme` (and conflicts Dogtag server)
- **Requires:** `python3-ipacta`, `python3-ipacta-pki`, `nss-tools`,
  `openssl`, `openldap-clients`, `systemd` — **not** `freeipa-server` or
  `389-ds-base`

So RPMs can install beside a separately provisioned DS in principle.
That is **not** the same as a finished standalone deploy path.

### 3. Standalone installer is unfinished

`src/ipacta/cli/install.py` describes standalone mode (without FreeIPA)
and accepts `--ldap-uri`, but still contains an explicit gap:

```text
# For standalone, we'll need to adapt this
# TODO: Create standalone LDAP connection
```

Dogtag-shaped `bin/pkispawn` exists and `--help` works inside
`freeipa-ipacta:latest`, but the FreeIPA image also ships `freeipa-server`
and is built for the FreeIPA install path used by TMT.

### 4. Short probe (2026-10-19)

```bash
docker run --rm --entrypoint pkispawn freeipa-ipacta:latest --help
# → usage printed (OK)

docker run --rm --entrypoint rpm freeipa-ipacta:latest -q freeipa-server ipacta
# → freeipa-server-… and ipacta-… both installed
```

No attempt was made to complete a green standalone CA against a bare
389-DS: docs + `TODO` already establish the thin path is not ready for
pki-cli TMT. A full DS+`pkispawn` experiment belongs in a later spike
once standalone install is claimed upstream.

## What would change this conclusion

- Upstream documents and finishes standalone IPACTA against existing DS
  (no FreeIPA), **or**
- A verified recipe (packages + commands) reaches running IPACTA REST
  without `ipa-server-install`, recorded with pass criteria.

Until then, pki-cli TMT stays on **freeipa-ipacta + ipa-server-install**.
