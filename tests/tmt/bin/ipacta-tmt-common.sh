# Shared IPACTA TMT helpers. Sourced by generated tests/tmt/*/test.sh
# shellcheck shell=bash

IPA_IMAGE="${IPA_IMAGE:-freeipa-ipacta:latest}"
CONTAINER="${CONTAINER_NAME:-ipa}"
DOMAIN="${IPA_DOMAIN:-example.com}"
REALM="${IPA_REALM:-EXAMPLE.COM}"
PASSWORD="${IPA_PASSWORD:-Secret.123}"
HOST="ipa.${DOMAIN}"
WORKDIR="${WORKDIR:-/tmp/ipacta-tmt-workdir}"
IPACTA_UNIT="${IPACTA_UNIT:-pki-tomcatd@pki-tomcat}"

iexec() { docker exec "$CONTAINER" "$@"; }

step() { echo; echo "==== $* ===="; }

omit() {
    echo "OMITTED (IPACTA/FreeIPA layout): $*"
}

if ! command -v docker >/dev/null; then
    echo "ERROR: docker not found" >&2
    exit 1
fi
if ! docker image inspect "$IPA_IMAGE" >/dev/null 2>&1; then
    echo "ERROR: Docker image '$IPA_IMAGE' not found (run prepare / build-ipa-runner.sh)" >&2
    exit 1
fi

mkdir -p "$WORKDIR"

ipacta_cleanup() {
    docker rm -f "$CONTAINER" client 2>/dev/null || true
    docker network rm example 2>/dev/null || true
    rm -rf "$WORKDIR"
}

ipacta_start_container() {
    docker network inspect example >/dev/null 2>&1 || docker network create example
    docker rm -f "$CONTAINER" 2>/dev/null || true
    docker run -d --name "$CONTAINER" \
        --hostname="$HOST" \
        --network=example \
        --network-alias="$HOST" \
        --network-alias="ipa-ca.${DOMAIN}" \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        --privileged \
        -v "$WORKDIR:$WORKDIR" \
        "$IPA_IMAGE" \
        /usr/sbin/init
    local _i
    for _i in $(seq 1 90); do
        if iexec systemctl is-system-running --wait 2>/dev/null \
            || iexec systemctl is-system-running 2>/dev/null | grep -Eq 'running|degraded'; then
            break
        fi
        sleep 2
    done
}

ipacta_install_ca() {
    iexec ipa-server-install \
        -U \
        --domain "$DOMAIN" \
        -r "$REALM" \
        -p "$PASSWORD" \
        -a "$PASSWORD" \
        --no-host-dns \
        --no-ntp
}

ipacta_install_kra() {
    iexec ipa-kra-install -U -p "$PASSWORD"
}

ipacta_install_acme() {
    iexec ipa-acme-manage enable
}

ipacta_uninstall() {
    iexec ipa-server-install --uninstall -U --ignore-topology-disconnect --ignore-last-of-role \
        || iexec ipa-server-install --uninstall -U || true
}
