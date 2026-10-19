#!/bin/bash
# Build freeipa-ipacta from Fedora 46 packages (stock FreeIPA + IPACTA).
#
# Installs freeipa-server + ipacta into a systemd container image. Naming
# `ipacta` explicitly selects IPACTA (Provides pki-ca) instead of Dogtag.
#
# A clean Testing Farm guest only needs Docker and network to
# registry.fedoraproject.org. Set SKIP_IPA_BUILD=1 to reuse an existing
# local image, or SKIP_IPA_BUILD=1 + IPA_IMAGE=quay.io/... to pull a
# prebuilt tag.
set -euo pipefail

REPO_ROOT="${1:-${TMT_TREE:-}}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
fi
cd "$REPO_ROOT" 2>/dev/null || true

BASE_IMAGE="${BASE_IMAGE:-registry.fedoraproject.org/fedora:46}"
IPA_IMAGE="${IPA_IMAGE:-freeipa-ipacta:latest}"
# Meta package; pulls python3-ipacta + python3-ipacta-pki.
IPACTA_PKGS="${IPACTA_PKGS:-freeipa-server ipacta freeipa-healthcheck}"

command -v docker >/dev/null \
    || { echo "ERROR: docker required to build freeipa-ipacta" >&2; exit 1; }

# Optional: pull a prebuilt image and tag it as freeipa-ipacta.
if [[ "${SKIP_IPA_BUILD:-0}" == "1" ]]; then
    if [[ -n "${IPA_IMAGE:-}" ]] \
            && { [[ "$IPA_IMAGE" == */* ]] || [[ "$IPA_IMAGE" == quay.io* ]]; }; then
        echo "SKIP_IPA_BUILD=1 — pulling ${IPA_IMAGE}"
        docker pull "${IPA_IMAGE}"
        docker tag "${IPA_IMAGE}" freeipa-ipacta
        docker tag "${IPA_IMAGE}" freeipa-ipacta:latest
    else
        echo "SKIP_IPA_BUILD=1 — IPA_IMAGE unset/local; expecting local freeipa-ipacta"
    fi
    docker image inspect freeipa-ipacta >/dev/null \
        || { echo "ERROR: freeipa-ipacta image not found (set IPA_IMAGE or build)" >&2; exit 1; }
    echo "==== freeipa-ipacta image ready (skip build) ===="
    docker images freeipa-ipacta
    exit 0
fi

echo "==== Building freeipa-ipacta from packages ===="
echo "BASE_IMAGE=${BASE_IMAGE}"
echo "IPA_IMAGE=${IPA_IMAGE}"
echo "IPACTA_PKGS=${IPACTA_PKGS}"

docker pull "$BASE_IMAGE"

CTX=$(mktemp -d)
trap 'rm -rf "$CTX"' EXIT

# Expand BASE_IMAGE / IPACTA_PKGS into the Dockerfile; keep shell vars for RUN.
cat >"$CTX/Dockerfile" <<EOF
FROM ${BASE_IMAGE}
ENV container=docker LANG=en_US.utf8 LANGUAGE=en_US.utf8 LC_ALL=en_US.utf8

RUN echo 'deltarpm = false' >> /etc/dnf/dnf.conf \\
    && dnf -y update \\
    && dnf -y install \\
        systemd \\
        firewalld \\
        glibc-langpack-en \\
        iptables \\
        nss-tools \\
        openldap-clients \\
        openssl \\
        openssh-server \\
        sudo \\
        wget \\
        ${IPACTA_PKGS} \\
    && dnf clean all \\
    && sed -i 's/.*PermitRootLogin .*/#&/g' /etc/ssh/sshd_config \\
    && echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config \\
    && sed -i -e 's@^\\(session.*required.*pam_loginuid\\)@#\\1@' /etc/pam.d/sshd \\
    && systemctl enable sshd \\
    && for i in /usr/lib/systemd/system/*-domainname.service; do \\
         [ -f "\$i" ] && sed -i 's#^ExecStart=/#ExecStart=-/#' "\$i" || true; \\
       done \\
    && { systemctl mask systemd-resolved ||: ; } \\
    && systemctl set-default multi-user.target \\
    && rpm -q ipacta python3-ipacta freeipa-server \\
    && if rpm -q dogtag-pki-ca >/dev/null 2>&1; then \\
         echo "ERROR: dogtag-pki-ca installed; expected IPACTA only" >&2; exit 1; \\
       fi

STOPSIGNAL RTMIN+3
VOLUME ["/run", "/tmp"]
ENTRYPOINT [ "/usr/sbin/init" ]
EOF

echo "==== docker build ${IPA_IMAGE} ===="
docker build --network host \
    -t "$IPA_IMAGE" \
    -t "${IPA_IMAGE%%:*}:latest" \
    -t freeipa-ipacta:latest \
    "$CTX"

docker image inspect freeipa-ipacta:latest >/dev/null
echo "==== freeipa-ipacta ready (Fedora 46 + packaged IPACTA) ===="
docker images freeipa-ipacta
docker run --rm --entrypoint rpm freeipa-ipacta:latest \
    -q ipacta python3-ipacta python3-ipacta-pki freeipa-server freeipa-healthcheck \
    2>/dev/null || true
