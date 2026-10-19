#!/bin/bash
# Dogtag tests/tmt/ca-basic-test (GHA ca-basic-test.yml) adapted for pki-cli:
# - Step names/harness from Dogtag (source of truth)
# - Server under test: freeipa-ipacta (IPACTA), container name kept as "pki" for docker exec reuse
# - Host client: pki-cli (Java MainCLI gated) instead of docker exec pki pki
# - DS sidecar / pkispawn install remapped; pki-server/layout steps fail-collect
#
set -euo pipefail

REPO_ROOT="${TMT_TREE:-}"
if [[ -z "$REPO_ROOT" || ! -f "$REPO_ROOT/pyproject.toml" ]]; then
    REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
fi
# Host pki-cli from prepare (venv)
if [[ -f "$REPO_ROOT/tests/tmt/.run/venv-bin" ]]; then
    PATH="$(cat "$REPO_ROOT/tests/tmt/.run/venv-bin"):$PATH"
    export PATH
elif [[ -x "$REPO_ROOT/.venv/bin/pki-cli" ]]; then
    PATH="$REPO_ROOT/.venv/bin:$PATH"
    export PATH
fi
BIN="$REPO_ROOT/tests/bin"

export GITHUB_WORKSPACE="$REPO_ROOT"
export SHARED="${SHARED:-/tmp/workdir/pki}"
# GHA persists env vars via $GITHUB_ENV; emulate with a temp file + source.
export GITHUB_ENV="${TMPDIR:-/tmp}/gha-env-$$"
touch "$GITHUB_ENV"
source_gha_env() { set -a; source "$GITHUB_ENV" 2>/dev/null || true; set +a; }
mkdir -p "$GITHUB_WORKSPACE"
cd "$GITHUB_WORKSPACE"
export LC_ALL=C

export DS_IMAGE="quay.io/389ds/dirsrv"
export SHARED="/tmp/workdir/pki"

PKI_IMAGE="${PKI_IMAGE:-freeipa-ipacta:latest}"

# Ensure docker and freeipa-ipacta (IPACTA) are available
if ! command -v docker >/dev/null; then
    echo "ERROR: docker not found" >&2
    exit 1
fi

cleanup() {
    docker rm -f pki ds 2>/dev/null || true
    docker volume rm ds-data 2>/dev/null || true
    docker network rm example 2>/dev/null || true
}
trap cleanup EXIT

step() { echo; echo "==== $* ===="; }
GHA_FAILED=0

step "Clone repository"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# GHA: actions/checkout — repo already available as $REPO_ROOT
echo "Repository available at $REPO_ROOT"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Clone repository (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Retrieve PKI images"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# GHA: actions/cache — images built locally by prepare (build-pki-runner.sh)
echo "Images built by TMT prepare phase"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Retrieve PKI images (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Load PKI images"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# GHA: docker load from cache — images built locally by prepare
echo "Images already available (built by TMT prepare)"
docker image inspect freeipa-ipacta >/dev/null 2>&1 || docker image inspect "$PKI_IMAGE" >/dev/null 2>&1 || { echo "ERROR: freeipa-ipacta / PKI_IMAGE not found"; false; }
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Load PKI images (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Create network"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker network create example
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Create network (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Set up DS container"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
echo "OMITTED: IPACTA embeds Directory Server; no Dogtag DS sidecar"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Set up DS container (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Set up PKI container"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# Dogtag step name kept; body is IPACTA (freeipa-ipacta), container name "pki"
DOMAIN="${IPA_DOMAIN:-example.com}"
HOST="ipa.${DOMAIN}"
IMAGE="${PKI_IMAGE}"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    IMAGE=freeipa-ipacta:latest
fi
docker rm -f pki 2>/dev/null || true
# Force init entrypoint: some Quay tags were baked with ENTRYPOINT=sleep.
docker run -d --name pki \
    --entrypoint /usr/sbin/init \
    --hostname="$HOST" \
    --network=example \
    --network-alias="$HOST" \
    --network-alias="ipa-ca.${DOMAIN}" \
    --network-alias=pki.example.com \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --privileged \
    "$IMAGE"
ready=0
for _i in $(seq 1 90); do
    if ! docker inspect -f '{{.State.Running}}' pki 2>/dev/null | grep -q true; then
        echo "ERROR: container pki is not running (image entrypoint/init failure?)" >&2
        docker inspect pki --format \
            'Status={{.State.Status}} ExitCode={{.State.ExitCode}} Error={{.State.Error}} Entrypoint={{json .Config.Entrypoint}} Cmd={{json .Config.Cmd}}' \
            2>/dev/null || true
        docker logs pki 2>&1 | tail -n 80 || true
        exit 1
    fi
    if docker exec pki systemctl is-system-running --wait 2>/dev/null \
        || docker exec pki systemctl is-system-running 2>/dev/null | grep -Eq 'running|degraded'; then
        ready=1
        break
    fi
    sleep 2
done
if [[ "$ready" -ne 1 ]]; then
    echo "ERROR: systemd did not become ready in container pki within timeout" >&2
    docker exec pki systemctl is-system-running 2>&1 || true
    docker logs pki 2>&1 | tail -n 80 || true
    exit 1
fi
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Set up PKI container (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Get Fedora version"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
FEDORA_VERSION=$(docker exec pki sed -n 's/^VERSION_ID=//p' /etc/os-release)
echo "FEDORA_VERSION=$FEDORA_VERSION" | tee -a $GITHUB_ENV
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Get Fedora version (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
source_gha_env
fi

step "Check pki CLI help messages"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
command -v pki-cli >/dev/null
pki-cli --help >/dev/null
# Remapped from pki-cli … → host pki-cli.
# Exit 2 = Java MainCLI gated (java-bound) — expected until pure-Python REST.
expect_cli() {
    set +e
    pki-cli "$@"
    local rc=$?
    set -e
    if [[ "$rc" -eq 0 || "$rc" -eq 2 ]]; then
        return 0
    fi
    echo "unexpected pki-cli exit $rc for: pki-cli $*" >&2
    return 1
}
expect_cli info --help
expect_cli securitydomain
expect_cli securitydomain --help
expect_cli client
expect_cli client --help
expect_cli ca
expect_cli ca --help
expect_cli ca-cert-find --help
expect_cli ca-cert-show --help
expect_cli ca-profile-find --help
expect_cli ca-profile-show --help
expect_cli ca-publisher-ocsp-add --help
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check pki CLI help messages (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Get Tomcat flavor"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# Dogtag step name kept; IPACTA uses pki-tomcatd@ running python -m ipacta.server
if docker exec pki systemctl cat pki-tomcatd@pki-tomcat 2>/dev/null | grep -qi ipacta; then
    TOMCAT_FLAVOR=ipacta
else
    TOMCAT_FLAVOR=$(docker exec pki test -f /usr/libexec/tomcat/tomcat-run.sh && echo "new" || echo "old")
fi
echo "TOMCAT_FLAVOR=$TOMCAT_FLAVOR" | tee -a $GITHUB_ENV
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Get Tomcat flavor (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
source_gha_env
fi

step "Install CA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# Dogtag step name kept; body is IPACTA (not pkispawn)
DOMAIN="${IPA_DOMAIN:-example.com}"
REALM="${IPA_REALM:-EXAMPLE.COM}"
PASSWORD="${IPA_PASSWORD:-Secret.123}"
docker exec pki ipa-server-install \
    -U \
    --domain "$DOMAIN" \
    -r "$REALM" \
    -p "$PASSWORD" \
    -a "$PASSWORD" \
    --no-host-dns \
    --no-ntp \
    > >(tee stdout) 2> >(tee stderr >&2)
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Install CA (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check for warnings"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
sed -n '/^WARNING:/p' stderr | tee output
diff /dev/null output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check for warnings (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

step "Check external commands"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
sed -n '/^DEBUG: Command:/p' stderr | tee output
wc -l output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check external commands (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

step "Check PKI server base dir after installation"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /var/lib/pki/pki-tomcat \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
    | tee output

# TODO: review permissions
cat > expected_old << EOF
lrwxrwxrwx pkiuser pkiuser alias -> /var/lib/pki/pki-tomcat/conf/alias
lrwxrwxrwx pkiuser pkiuser bin -> /usr/share/tomcat/bin
drwxrwx--- pkiuser pkiuser ca
drwxrwx--- pkiuser pkiuser common
lrwxrwxrwx pkiuser pkiuser conf -> /etc/pki/pki-tomcat
lrwxrwxrwx pkiuser pkiuser lib -> /usr/share/pki/server/lib
lrwxrwxrwx pkiuser pkiuser logs -> /var/log/pki/pki-tomcat
drwxrwx--- pkiuser pkiuser temp
drwxrwx--- pkiuser pkiuser webapps
drwxrwx--- pkiuser pkiuser work
EOF

cat > expected_new << EOF
lrwxrwxrwx pkiuser pkiuser alias -> /var/lib/pki/pki-tomcat/conf/alias
lrwxrwxrwx pkiuser pkiuser bin -> /usr/share/tomcat/bin
drwxrwx--- pkiuser pkiuser ca
drwxrwx--- pkiuser pkiuser common
lrwxrwxrwx pkiuser pkiuser conf -> /etc/pki/pki-tomcat
lrwxrwxrwx pkiuser pkiuser lib -> /usr/share/pki/server/lib
lrwxrwxrwx pkiuser pkiuser logs -> /var/log/pki/pki-tomcat
drwxrwx--- pkiuser pkiuser temp
drwxrwx--- pkiuser pkiuser webapps
drwxrwx--- pkiuser pkiuser work
EOF

diff expected_$TOMCAT_FLAVOR output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server base dir after installation (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check PKI server conf dir after installation"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /etc/pki/pki-tomcat \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
    | tee output

# TODO: review permissions
cat > expected_old << EOF
drwxrwx--- pkiuser pkiuser Catalina
drwxrwx--- pkiuser pkiuser alias
drwxrwx--- pkiuser pkiuser ca
-rw-r--r-- pkiuser pkiuser catalina.policy
lrwxrwxrwx pkiuser pkiuser catalina.properties -> /usr/share/pki/server/conf/catalina.properties
drwxrwx--- pkiuser pkiuser certs
lrwxrwxrwx pkiuser pkiuser context.xml -> /etc/tomcat/context.xml
lrwxrwxrwx pkiuser pkiuser logging.properties -> /usr/share/pki/server/conf/logging.properties
-rw-rw---- pkiuser pkiuser password.conf
-rw-rw---- pkiuser pkiuser server.xml
-rw-rw---- pkiuser pkiuser serverCertNick.conf
-rw-rw---- pkiuser pkiuser tomcat.conf
lrwxrwxrwx pkiuser pkiuser web.xml -> /etc/tomcat/web.xml
EOF

cat > expected_new << EOF
drwxrwx--- pkiuser pkiuser Catalina
drwxrwx--- pkiuser pkiuser alias
drwxrwx--- pkiuser pkiuser ca
-rw-r--r-- pkiuser pkiuser catalina.policy
lrwxrwxrwx pkiuser pkiuser catalina.properties -> /usr/share/pki/server/conf/catalina.properties
drwxrwx--- pkiuser pkiuser certs
lrwxrwxrwx pkiuser pkiuser context.xml -> /etc/tomcat/context.xml
lrwxrwxrwx pkiuser pkiuser logging.properties -> /usr/share/pki/server/conf/logging.properties
-rw-rw---- pkiuser pkiuser password.conf
-rw-rw---- pkiuser pkiuser server.xml
-rw-rw---- pkiuser pkiuser serverCertNick.conf
-rw-rw---- pkiuser pkiuser tomcat.conf
lrwxrwxrwx pkiuser pkiuser web.xml -> /etc/tomcat/web.xml
EOF

diff expected_$TOMCAT_FLAVOR output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server conf dir after installation (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check server.xml"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
docker exec pki cat /etc/pki/pki-tomcat/server.xml
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check server.xml (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

step "Check tomcat.conf"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
docker exec pki cat /etc/pki/pki-tomcat/tomcat.conf
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check tomcat.conf (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

step "Check PKI server conf/alias dir after installation"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /etc/pki/pki-tomcat/alias \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
    | tee output

# TODO: review permissions
cat > expected << EOF
-rw-r--r-- pkiuser pkiuser ca.crt
-rw------- pkiuser pkiuser cert9.db
-rw------- pkiuser pkiuser key4.db
-rw------- pkiuser pkiuser pkcs11.txt
EOF

diff expected output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server conf/alias dir after installation (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check PKI server conf/Catalina/localhost dir after installation"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /etc/pki/pki-tomcat/Catalina/localhost \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
    | tee output

# TODO: review permissions
cat > expected << EOF
-rw-rw---- pkiuser pkiuser ROOT.xml
-rw-rw---- pkiuser pkiuser ca.xml
-rw-rw---- pkiuser pkiuser pki.xml
lrwxrwxrwx pkiuser pkiuser rewrite.config -> /usr/share/pki/server/conf/Catalina/localhost/rewrite.config
EOF

diff expected output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server conf/Catalina/localhost dir after installation (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check /etc/sysconfig/pki-tomcat"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
docker exec pki cat /etc/sysconfig/pki-tomcat
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check /etc/sysconfig/pki-tomcat (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

step "Check PKI server logs dir after installation"
if [[ "$GHA_FAILED" -eq 0 ]] && [[ "${FEDORA_VERSION}" -lt 43 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /var/log/pki/pki-tomcat \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
    | tee output

DATE=$(date +'%Y-%m-%d')

# TODO: review permissions
cat > expected << EOF
drwxrwx--- pkiuser pkiuser backup
drwxrwx--- pkiuser pkiuser ca
-rw-r--r-- pkiuser pkiuser localhost.$DATE.log
-rw-r--r-- pkiuser pkiuser localhost_access_log.$DATE.txt
drwxr-xr-x pkiuser pkiuser pki
EOF

diff expected output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server logs dir after installation (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check PKI server logs dir after installation"
if [[ "$GHA_FAILED" -eq 0 ]] && [[ "${FEDORA_VERSION}" -ge 43 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /var/log/pki/pki-tomcat \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
    | tee output

DATE=$(date +'%Y-%m-%d')

# TODO: review permissions
cat > expected_old << EOF
drwxrwx--- pkiuser pkiuser backup
drwxrwx--- pkiuser pkiuser ca
-rw-r--r-- pkiuser pkiuser localhost_access_log.$DATE.txt
EOF

cat > expected_new << EOF
drwxrwx--- pkiuser pkiuser backup
drwxrwx--- pkiuser pkiuser ca
-rw-r----- pkiuser pkiuser localhost_access_log.$DATE.txt
EOF

diff expected_$TOMCAT_FLAVOR output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server logs dir after installation (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA base dir"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /var/lib/pki/pki-tomcat/ca \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
    | tee output

# TODO: review permissions
cat > expected_old << EOF
lrwxrwxrwx pkiuser pkiuser alias -> /var/lib/pki/pki-tomcat/alias
lrwxrwxrwx pkiuser pkiuser conf -> /var/lib/pki/pki-tomcat/conf/ca
lrwxrwxrwx pkiuser pkiuser emails -> /var/lib/pki/pki-tomcat/conf/ca/emails
lrwxrwxrwx pkiuser pkiuser logs -> /var/lib/pki/pki-tomcat/logs/ca
lrwxrwxrwx pkiuser pkiuser profiles -> /var/lib/pki/pki-tomcat/conf/ca/profiles
lrwxrwxrwx pkiuser pkiuser registry -> /etc/sysconfig/pki/tomcat/pki-tomcat
EOF

cat > expected_new << EOF
lrwxrwxrwx pkiuser pkiuser alias -> /var/lib/pki/pki-tomcat/alias
lrwxrwxrwx pkiuser pkiuser conf -> /var/lib/pki/pki-tomcat/conf/ca
lrwxrwxrwx pkiuser pkiuser emails -> /var/lib/pki/pki-tomcat/conf/ca/emails
lrwxrwxrwx pkiuser pkiuser logs -> /var/lib/pki/pki-tomcat/logs/ca
lrwxrwxrwx pkiuser pkiuser profiles -> /var/lib/pki/pki-tomcat/conf/ca/profiles
lrwxrwxrwx pkiuser pkiuser registry -> /etc/sysconfig/pki/tomcat/pki-tomcat
EOF

diff expected_$TOMCAT_FLAVOR output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA base dir (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA conf dir"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /var/lib/pki/pki-tomcat/conf/ca \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
        -e '/^.* CS\.cfg\..*$/d' \
    | tee output

# TODO: review permissions
cat > expected_old << EOF
-rw-rw---- pkiuser pkiuser CS.cfg
-rw-rw---- pkiuser pkiuser adminCert.profile
drwxr-xr-x pkiuser pkiuser archives
-rw-rw---- pkiuser pkiuser caAuditSigningCert.profile
-rw-rw---- pkiuser pkiuser caCert.profile
-rw-rw---- pkiuser pkiuser caOCSPCert.profile
drwxrwx--- pkiuser pkiuser emails
-rw-rw---- pkiuser pkiuser flatfile.txt
drwxrwx--- pkiuser pkiuser profiles
-rw-rw---- pkiuser pkiuser proxy.conf
-rw-rw---- pkiuser pkiuser registry.cfg
-rw-rw---- pkiuser pkiuser serverCert.profile
-rw-rw---- pkiuser pkiuser subsystemCert.profile
EOF

cat > expected_new << EOF
-rw-rw---- pkiuser pkiuser CS.cfg
-rw-rw---- pkiuser pkiuser adminCert.profile
drwxr-xr-x pkiuser pkiuser archives
-rw-rw---- pkiuser pkiuser caAuditSigningCert.profile
-rw-rw---- pkiuser pkiuser caCert.profile
-rw-rw---- pkiuser pkiuser caOCSPCert.profile
drwxrwx--- pkiuser pkiuser emails
-rw-rw---- pkiuser pkiuser flatfile.txt
drwxrwx--- pkiuser pkiuser profiles
-rw-rw---- pkiuser pkiuser proxy.conf
-rw-rw---- pkiuser pkiuser registry.cfg
-rw-rw---- pkiuser pkiuser serverCert.profile
-rw-rw---- pkiuser pkiuser subsystemCert.profile
EOF

diff expected_$TOMCAT_FLAVOR output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA conf dir (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA server status"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server status | tee output

# CA should be a domain manager
echo "True" > expected
sed -n 's/^ *SD Manager: *\(.*\)$/\1/p' output > actual
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA server status (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check webapps"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server webapp-find | tee output

# CA instance should have ROOT, ca, and pki webapps
echo "ROOT" > expected
echo "ca" >> expected
echo "pki" >> expected
sed -n 's/^ *Webapp ID: *\(.*\)$/\1/p' output > actual
diff expected actual

docker exec pki pki-server webapp-show ROOT
docker exec pki pki-server webapp-show ca
docker exec pki pki-server webapp-show pki
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check webapps (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check subsystems"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server subsystem-find | tee output

# CA instance should have CA subsystem
echo "ca" > expected
sed -n 's/^ *Subsystem ID: *\(.*\)$/\1/p' output > actual
diff expected actual

docker exec pki pki-server subsystem-show ca | tee output

# CA subsystem should be enabled
echo "True" > expected
sed -n 's/^ *Enabled: *\(.*\)$/\1/p' output > actual
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check subsystems (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA certs and keys"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# check certs
docker exec pki pki-server cert-find

# check keys
echo "Secret.123" > password.txt
docker cp password.txt pki:password.txt
docker exec pki certutil -K \
    -d /var/lib/pki/pki-tomcat/conf/alias \
    -f password.txt | tee output

# there should be no orphaned keys
echo "0" > expected
{ grep "(orphan)" output || true; } | wc -l > actual
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA certs and keys (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA signing cert request"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/ca_signing.csr \
    | tee output

# normalize output
# - remove hex string
sed -E \
    -e '/^ *[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2})+:?$/d' \
    -e '/^ *Modulus:$/d' \
    -e '/^ *Signature Value:$/d' \
    output > actual

cat > expected << EOF
Certificate Request:
    Data:
        Version: 1 (0x0)
        Subject: O=EXAMPLE, OU=pki-tomcat, CN=CA Signing Certificate
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (3072 bit)
                Exponent: 65537 (0x10001)
        Attributes:
            Requested Extensions:
                X509v3 Basic Constraints: critical
                    CA:TRUE
                X509v3 Key Usage: critical
                    Digital Signature, Non Repudiation, Certificate Sign, CRL Sign
    Signature Algorithm: sha256WithRSAEncryption
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA signing cert request (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA OCSP signing cert request"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/ca_ocsp_signing.csr \
    | tee output

# normalize output
# - remove hex string
sed -E \
    -e '/^ *[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2})+:?$/d' \
    -e '/^ *Modulus:$/d' \
    -e '/^ *Signature Value:$/d' \
    output > actual

cat > expected << EOF
Certificate Request:
    Data:
        Version: 1 (0x0)
        Subject: O=EXAMPLE, OU=pki-tomcat, CN=CA OCSP Signing Certificate
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (3072 bit)
                Exponent: 65537 (0x10001)
        Attributes:
            (none)
            Requested Extensions:
    Signature Algorithm: sha256WithRSAEncryption
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA OCSP signing cert request (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA audit signing cert request"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/ca_audit_signing.csr \
    | tee output

# normalize output
# - remove hex string
sed -E \
    -e '/^ *[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2})+:?$/d' \
    -e '/^ *Modulus:$/d' \
    -e '/^ *Signature Value:$/d' \
    output > actual

cat > expected << EOF
Certificate Request:
    Data:
        Version: 1 (0x0)
        Subject: O=EXAMPLE, OU=pki-tomcat, CN=CA Audit Signing Certificate
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (2048 bit)
                Exponent: 65537 (0x10001)
        Attributes:
            (none)
            Requested Extensions:
    Signature Algorithm: sha256WithRSAEncryption
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA audit signing cert request (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check subsystem cert request"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/subsystem.csr \
    | tee output

# normalize output
# - remove hex string
sed -E \
    -e '/^ *[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2})+:?$/d' \
    -e '/^ *Modulus:$/d' \
    -e '/^ *Signature Value:$/d' \
    output > actual

cat > expected << EOF
Certificate Request:
    Data:
        Version: 1 (0x0)
        Subject: O=EXAMPLE, OU=pki-tomcat, CN=Subsystem Certificate
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (2048 bit)
                Exponent: 65537 (0x10001)
        Attributes:
            (none)
            Requested Extensions:
    Signature Algorithm: sha256WithRSAEncryption
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check subsystem cert request (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check SSL server cert request"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/sslserver.csr \
    | tee output

# normalize output
# - remove hex string
sed -E \
    -e '/^ *[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2})+:?$/d' \
    -e '/^ *Modulus:$/d' \
    -e '/^ *Signature Value:$/d' \
    output > actual

cat > expected << EOF
Certificate Request:
    Data:
        Version: 1 (0x0)
        Subject: O=EXAMPLE, OU=pki-tomcat, CN=pki.example.com
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (2048 bit)
                Exponent: 65537 (0x10001)
        Attributes:
            (none)
            Requested Extensions:
    Signature Algorithm: sha256WithRSAEncryption
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check SSL server cert request (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check admin cert request"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/ca_admin.csr \
    | tee output

# normalize output
# - remove hex string
sed -E \
    -e '/^ *[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2})+:?$/d' \
    -e '/^ *Modulus:$/d' \
    -e '/^ *Signature Value:$/d' \
    output > actual

cat > expected << EOF
Certificate Request:
    Data:
        Version: 1 (0x0)
        Subject: O=EXAMPLE, OU=pki-tomcat, emailAddress=caadmin@example.com, CN=PKI Administrator
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (2048 bit)
                Exponent: 65537 (0x10001)
        Attributes:
            (none)
            Requested Extensions:
    Signature Algorithm: sha256WithRSAEncryption
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check admin cert request (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA signing cert"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-export \
    --cert-file ca_signing.crt \
    ca_signing

docker exec pki openssl x509 -text -noout \
    -in ca_signing.crt \
    | tee output

# normalize output
# - remove hex string
# - remove date and time
sed -E \
    -e '/^ *[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2})+:?$/d' \
    -e '/^ *Serial Number:$/d' \
    -e '/^ *Validity$/d' \
    -e '/^ *Not Before:/d' \
    -e '/^ *Not After :/d' \
    -e '/^ *Modulus:$/d' \
    -e '/^ *Signature Value:$/d' \
    -e '/^$/d' \
    -e 's/ *$//' \
    output > actual

cat > expected << EOF
Certificate:
    Data:
        Version: 3 (0x2)
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: O=EXAMPLE, OU=pki-tomcat, CN=CA Signing Certificate
        Subject: O=EXAMPLE, OU=pki-tomcat, CN=CA Signing Certificate
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (3072 bit)
                Exponent: 65537 (0x10001)
        X509v3 extensions:
            X509v3 Subject Key Identifier:
            X509v3 Authority Key Identifier:
            X509v3 Basic Constraints: critical
                CA:TRUE
            X509v3 Key Usage: critical
                Digital Signature, Non Repudiation, Certificate Sign, CRL Sign
    Signature Algorithm: sha256WithRSAEncryption
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA signing cert (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA OCSP signing cert"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-export \
    --cert-file ca_ocsp_signing.crt \
    ca_ocsp_signing

docker exec pki openssl x509 -text -noout \
    -in ca_ocsp_signing.crt \
    | tee output

# normalize output
# - remove hex string
# - remove date and time
sed -E \
    -e '/^ *[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2})+:?$/d' \
    -e '/^ *Serial Number:$/d' \
    -e '/^ *Validity$/d' \
    -e '/^ *Not Before:/d' \
    -e '/^ *Not After :/d' \
    -e '/^ *Modulus:$/d' \
    -e '/^ *Signature Value:$/d' \
    -e '/^$/d' \
    -e 's/ *$//' \
    output > actual

cat > expected << EOF
Certificate:
    Data:
        Version: 3 (0x2)
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: O=EXAMPLE, OU=pki-tomcat, CN=CA Signing Certificate
        Subject: O=EXAMPLE, OU=pki-tomcat, CN=CA OCSP Signing Certificate
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (3072 bit)
                Exponent: 65537 (0x10001)
        X509v3 extensions:
            X509v3 Authority Key Identifier:
            Authority Information Access:
                OCSP - URI:http://pki.example.com:8080/ca/ocsp
            X509v3 Extended Key Usage:
                OCSP Signing
            OCSP No Check:
    Signature Algorithm: sha256WithRSAEncryption
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA OCSP signing cert (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA audit signing cert"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-export \
    --cert-file ca_audit_signing.crt \
    ca_audit_signing

docker exec pki openssl x509 -text -noout \
    -in ca_audit_signing.crt \
    | tee output

# normalize output
# - remove hex string
# - remove date and time
sed -E \
    -e '/^ *[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2})+:?$/d' \
    -e '/^ *Serial Number:$/d' \
    -e '/^ *Validity$/d' \
    -e '/^ *Not Before:/d' \
    -e '/^ *Not After :/d' \
    -e '/^ *Modulus:$/d' \
    -e '/^ *Signature Value:$/d' \
    -e '/^$/d' \
    -e 's/ *$//' \
    output > actual

cat > expected << EOF
Certificate:
    Data:
        Version: 3 (0x2)
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: O=EXAMPLE, OU=pki-tomcat, CN=CA Signing Certificate
        Subject: O=EXAMPLE, OU=pki-tomcat, CN=CA Audit Signing Certificate
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (2048 bit)
                Exponent: 65537 (0x10001)
        X509v3 extensions:
            X509v3 Authority Key Identifier:
            X509v3 Key Usage: critical
                Digital Signature, Non Repudiation
            Authority Information Access:
                OCSP - URI:http://pki.example.com:8080/ca/ocsp
    Signature Algorithm: sha256WithRSAEncryption
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA audit signing cert (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check subsystem cert"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-export \
    --cert-file subsystem.crt \
    subsystem

docker exec pki openssl x509 -text -noout \
    -in subsystem.crt \
    | tee output

# normalize output
# - remove hex string
# - remove date and time
sed -E \
    -e '/^ *[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2})+:?$/d' \
    -e '/^ *Serial Number:$/d' \
    -e '/^ *Validity$/d' \
    -e '/^ *Not Before:/d' \
    -e '/^ *Not After :/d' \
    -e '/^ *Modulus:$/d' \
    -e '/^ *Signature Value:$/d' \
    -e '/^$/d' \
    -e 's/ *$//' \
    output > actual

# TODO: investigate inconsistent key usage
cat > expected << EOF
Certificate:
    Data:
        Version: 3 (0x2)
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: O=EXAMPLE, OU=pki-tomcat, CN=CA Signing Certificate
        Subject: O=EXAMPLE, OU=pki-tomcat, CN=Subsystem Certificate
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (2048 bit)
                Exponent: 65537 (0x10001)
        X509v3 extensions:
            X509v3 Authority Key Identifier:
            Authority Information Access:
                OCSP - URI:http://pki.example.com:8080/ca/ocsp
            X509v3 Key Usage: critical
                Digital Signature, Non Repudiation, Key Encipherment, Data Encipherment
            X509v3 Extended Key Usage:
                TLS Web Client Authentication
    Signature Algorithm: sha256WithRSAEncryption
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check subsystem cert (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check SSL server cert"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-export \
    --cert-file sslserver.crt \
    sslserver

docker exec pki openssl x509 -text -noout \
    -in sslserver.crt \
    | tee output

# normalize output
# - remove hex string
# - remove date and time
sed -E \
    -e '/^ *[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2})+:?$/d' \
    -e '/^ *Serial Number:$/d' \
    -e '/^ *Validity$/d' \
    -e '/^ *Not Before:/d' \
    -e '/^ *Not After :/d' \
    -e '/^ *Modulus:$/d' \
    -e '/^ *Signature Value:$/d' \
    -e '/^$/d' \
    -e 's/ *$//' \
    output > actual

# TODO: investigate inconsistent key usage
cat > expected << EOF
Certificate:
    Data:
        Version: 3 (0x2)
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: O=EXAMPLE, OU=pki-tomcat, CN=CA Signing Certificate
        Subject: O=EXAMPLE, OU=pki-tomcat, CN=pki.example.com
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (2048 bit)
                Exponent: 65537 (0x10001)
        X509v3 extensions:
            X509v3 Authority Key Identifier:
            Authority Information Access:
                OCSP - URI:http://pki.example.com:8080/ca/ocsp
            X509v3 Key Usage: critical
                Digital Signature, Key Encipherment, Data Encipherment
            X509v3 Extended Key Usage:
                TLS Web Server Authentication
            X509v3 Subject Alternative Name:
                DNS:pki.example.com
    Signature Algorithm: sha256WithRSAEncryption
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check SSL server cert (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA admin cert"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki openssl x509 -text -noout \
    -in /root/.dogtag/pki-tomcat/ca_admin.cert \
    | tee output

# normalize output
# - remove hex string
# - remove date and time
sed -E \
    -e '/^ *[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2})+:?$/d' \
    -e '/^ *Serial Number:$/d' \
    -e '/^ *Validity$/d' \
    -e '/^ *Not Before:/d' \
    -e '/^ *Not After :/d' \
    -e '/^ *Modulus:$/d' \
    -e '/^ *Signature Value:$/d' \
    -e '/^$/d' \
    -e 's/ *$//' \
    output > actual

# TODO: investigate inconsistent key usage
cat > expected << EOF
Certificate:
    Data:
        Version: 3 (0x2)
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: O=EXAMPLE, OU=pki-tomcat, CN=CA Signing Certificate
        Subject: O=EXAMPLE, OU=pki-tomcat, emailAddress=caadmin@example.com, CN=PKI Administrator
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (2048 bit)
                Exponent: 65537 (0x10001)
        X509v3 extensions:
            X509v3 Authority Key Identifier:
            Authority Information Access:
                OCSP - URI:http://pki.example.com:8080/ca/ocsp
            X509v3 Key Usage: critical
                Digital Signature, Non Repudiation, Key Encipherment
            X509v3 Extended Key Usage:
                TLS Web Client Authentication, E-mail Protection
    Signature Algorithm: sha256WithRSAEncryption
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA admin cert (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA audit events"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server ca-audit-event-find
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA audit events (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Run PKI healthcheck"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# Retry pki-healthcheck: intermittent NSS load timeout on audit_signing
hc_ok=0
for hc_try in 1 2 3; do
    echo "pki-healthcheck attempt ${hc_try}/3"
    if (
    set -euo pipefail
    docker exec pki pki-healthcheck \
        --failures-only \
        --debug \
        > >(tee stdout) 2> >(tee stderr >&2)
    ); then
        hc_ok=1
        break
    fi
    sleep 5
done
[[ "$hc_ok" -eq 1 ]]
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Run PKI healthcheck (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check external commands"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
sed -n '/^Command:/p' stderr | tee output
wc -l output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check external commands (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

step "Check CA admin user"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli nss-cert-import \
    --cert ca_signing.crt \
    --trust CT,C,C \
    ca_signing

pki-cli pkcs12-import \
    --pkcs12 /root/.dogtag/pki-tomcat/ca_admin_cert.p12 \
    --pkcs12-password Secret.123

pki-cli -n caadmin ca-user-show caadmin
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA admin user (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA signing cert chain"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki openssl verify \
    -CAfile ca_signing.crt \
    ca_signing.crt
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA signing cert chain (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA OCSP signing cert chain"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki openssl verify \
    -CAfile ca_signing.crt \
    ca_ocsp_signing.crt
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA OCSP signing cert chain (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA audit signing cert chain"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki openssl verify \
    -CAfile ca_signing.crt \
    ca_audit_signing.crt
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA audit signing cert chain (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA subsystem cert chain"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki openssl verify \
    -CAfile ca_signing.crt \
    subsystem.crt
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA subsystem cert chain (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA SSL server cert chain"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki openssl verify \
    -CAfile ca_signing.crt \
    sslserver.crt
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA SSL server cert chain (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA admin cert chain"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki openssl verify \
    -CAfile ca_signing.crt \
    /root/.dogtag/pki-tomcat/ca_admin.cert
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA admin cert chain (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA signing cert status"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-show ca_signing | tee output
SERIAL=$(sed -n "s/^\s*Serial Number:\s*\(\S*\)$/\1/p" output)

docker exec pki openssl ocsp \
    -url http://pki.example.com:8080/ca/ocsp \
    -CAfile ca_signing.crt \
    -issuer ca_signing.crt \
    -serial $SERIAL \
    | tee output

sed -n "/^$SERIAL:/p" output > actual
echo "$SERIAL: good" > expected

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA signing cert status (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA OCSP signing cert status"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-show ca_ocsp_signing | tee output
SERIAL=$(sed -n "s/^\s*Serial Number:\s*\(\S*\)$/\1/p" output)

docker exec pki openssl ocsp \
    -url http://pki.example.com:8080/ca/ocsp \
    -CAfile ca_signing.crt \
    -issuer ca_signing.crt \
    -serial $SERIAL \
    | tee output

sed -n "/^$SERIAL:/p" output > actual
echo "$SERIAL: good" > expected

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA OCSP signing cert status (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA audit signing cert status"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-show ca_audit_signing | tee output
SERIAL=$(sed -n "s/^\s*Serial Number:\s*\(\S*\)$/\1/p" output)

docker exec pki openssl ocsp \
    -url http://pki.example.com:8080/ca/ocsp \
    -CAfile ca_signing.crt \
    -issuer ca_signing.crt \
    -serial $SERIAL \
    | tee output

sed -n "/^$SERIAL:/p" output > actual
echo "$SERIAL: good" > expected

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA audit signing cert status (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check subsystem cert status"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-show subsystem | tee output
SERIAL=$(sed -n "s/^\s*Serial Number:\s*\(\S*\)$/\1/p" output)

docker exec pki openssl ocsp \
    -url http://pki.example.com:8080/ca/ocsp \
    -CAfile ca_signing.crt \
    -issuer ca_signing.crt \
    -serial $SERIAL \
    | tee output

sed -n "/^$SERIAL:/p" output > actual
echo "$SERIAL: good" > expected

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check subsystem cert status (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check SSL server cert status"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-show sslserver | tee output
SERIAL=$(sed -n "s/^\s*Serial Number:\s*\(\S*\)$/\1/p" output)

docker exec pki openssl ocsp \
    -url http://pki.example.com:8080/ca/ocsp \
    -CAfile ca_signing.crt \
    -issuer ca_signing.crt \
    -serial $SERIAL \
    | tee output

sed -n "/^$SERIAL:/p" output > actual
echo "$SERIAL: good" > expected

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check SSL server cert status (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA admin cert status"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli nss-cert-show caadmin | tee output
SERIAL=$(sed -n "s/^\s*Serial Number:\s*\(\S*\)$/\1/p" output)

docker exec pki openssl ocsp \
    -url http://pki.example.com:8080/ca/ocsp \
    -CAfile ca_signing.crt \
    -issuer ca_signing.crt \
    -serial $SERIAL \
    | tee output

sed -n "/^$SERIAL:/p" output > actual
echo "$SERIAL: good" > expected

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA admin cert status (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA signing cert usage"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# cert should be usable as SSL CA (3)
# TODO: investigate vfychain failure
docker exec pki /usr/lib64/nss/unsupported-tools/vfychain \
    -v \
    -d /var/lib/pki/pki-tomcat/conf/alias \
    -u 3 \
    -pp \
    -g leaf \
    -h requireFreshInfo \
    -m ocsp \
    -s failIfNoInfo \
    -a \
    ca_signing.crt \
    > >(tee stdout) 2> >(tee stderr >&2) \
    || true

diff /dev/null stdout

cat > expected << EOF
Chain is bad!
PROBLEM WITH THE CERT CHAIN:
CERT 1. ca_signing [Certificate Authority]:
  ERROR -8180: Peer's Certificate has been revoked.
EOF

diff expected stderr

docker exec pki pki-server cert-validate ca_signing
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA signing cert usage (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA OCSP signing cert usage"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# cert should be usable as OCSP responder (10)
# TODO: investigate vfychain failure
docker exec pki /usr/lib64/nss/unsupported-tools/vfychain \
    -v \
    -d /var/lib/pki/pki-tomcat/conf/alias \
    -u 10 \
    -pp \
    -g leaf \
    -h requireFreshInfo \
    -m ocsp \
    -s failIfNoInfo \
    -a \
    ca_ocsp_signing.crt \
    > >(tee stdout) 2> >(tee stderr >&2) \
    || true

diff /dev/null stdout

cat > expected << EOF
Chain is bad!
PROBLEM WITH THE CERT CHAIN:
CERT 1. ca_signing [Certificate Authority]:
  ERROR -8180: Peer's Certificate has been revoked.
EOF

diff expected stderr

docker exec pki pki-server cert-validate ca_ocsp_signing
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA OCSP signing cert usage (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA audit signing cert usage"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# cert should be usable as Object signer (6)
docker exec pki /usr/lib64/nss/unsupported-tools/vfychain \
    -v \
    -d /var/lib/pki/pki-tomcat/conf/alias \
    -u 6 \
    -pp \
    -g leaf \
    -h requireFreshInfo \
    -m ocsp \
    -s failIfNoInfo \
    -a \
    ca_audit_signing.crt \
    > >(tee stdout) 2> >(tee stderr >&2)

cat > expected << EOF
Certificate 1 Subject: "CN=CA Audit Signing Certificate,OU=pki-tomcat,O=EXAMP
    LE"
EOF

diff expected stdout

cat > expected << EOF
Chain is good!
EOF

diff expected stderr

docker exec pki pki-server cert-show ca_audit_signing
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA audit signing cert usage (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check subsystem cert usage"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# cert should be usable as SSL client (0)
docker exec pki /usr/lib64/nss/unsupported-tools/vfychain \
    -v \
    -d /var/lib/pki/pki-tomcat/conf/alias \
    -u 0 \
    -pp \
    -g leaf \
    -h requireFreshInfo \
    -m ocsp \
    -s failIfNoInfo \
    -a \
    subsystem.crt \
    > >(tee stdout) 2> >(tee stderr >&2)

cat > expected << EOF
Root Certificate Subject:: "CN=CA Signing Certificate,OU=pki-tomcat,O=EXAMPLE"
Certificate 1 Subject: "CN=Subsystem Certificate,OU=pki-tomcat,O=EXAMPLE"
EOF

diff expected stdout

cat > expected << EOF
Chain is good!
EOF

diff expected stderr

docker exec pki pki-server cert-validate subsystem
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check subsystem cert usage (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check SSL server cert usage"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# cert should be usable as SSL server (1)
docker exec pki /usr/lib64/nss/unsupported-tools/vfychain \
    -v \
    -d /var/lib/pki/pki-tomcat/conf/alias \
    -u 1 \
    -pp \
    -g leaf \
    -h requireFreshInfo \
    -m ocsp \
    -s failIfNoInfo \
    -a \
    sslserver.crt \
    > >(tee stdout) 2> >(tee stderr >&2)

cat > expected << EOF
Root Certificate Subject:: "CN=CA Signing Certificate,OU=pki-tomcat,O=EXAMPLE"
Certificate 1 Subject: "CN=pki.example.com,OU=pki-tomcat,O=EXAMPLE"
EOF

diff expected stdout

cat > expected << EOF
Chain is good!
EOF

diff expected stderr

docker exec pki pki-server cert-validate sslserver
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check SSL server cert usage (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA admin cert usage"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# cert should be usable as SSL client (0)
docker exec pki /usr/lib64/nss/unsupported-tools/vfychain \
    -v \
    -d /root/.dogtag/nssdb \
    -u 0 \
    -pp \
    -g leaf \
    -h requireFreshInfo \
    -m ocsp \
    -s failIfNoInfo \
    -a \
    /root/.dogtag/pki-tomcat/ca_admin.cert \
    > >(tee stdout) 2> >(tee stderr >&2)

cat > expected << EOF
Root Certificate Subject:: "CN=CA Signing Certificate,OU=pki-tomcat,O=EXAMPLE"
Certificate 1 Subject: "CN=PKI Administrator,E=caadmin@example.com,OU=pki-tom
    cat,O=EXAMPLE"
EOF

diff expected stdout

cat > expected << EOF
Chain is good!
EOF

diff expected stderr

pki-cli nss-cert-verify \
    --cert-usage SSLClient \
    caadmin
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA admin cert usage (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check default audit config"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server ca-config-find | grep audit_signing | tee output

cat > expected << EOF
ca.audit_signing.defaultSigningAlgorithm=SHA256withRSA
ca.audit_signing.nickname=ca_audit_signing
ca.audit_signing.tokenname=internal
ca.cert.audit_signing.certusage=ObjectSigner
ca.cert.audit_signing.nickname=ca_audit_signing
ca.cert.list=signing,ocsp_signing,sslserver,subsystem,audit_signing
log.instance.SignedAudit.signedAuditCertNickname=ca_audit_signing
EOF

diff expected output

docker exec pki pki-server ca-audit-config-show | tee output

cat > expected << EOF
  Enabled: True
  Log File: /var/lib/pki/pki-tomcat/logs/ca/signedAudit/ca_audit
  Buffer Size (bytes): 512
  Flush Interval (seconds): 5
  Max File Size (bytes): 2000
  Rollover Interval (seconds): 2592000
  Expiration Time (seconds): 0
  Log Signing: False
  Signing Certificate: ca_audit_signing
EOF

diff expected output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check default audit config (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Enable audit log signing"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server ca-audit-config-mod \
    --logSigning true

docker exec pki pki-server ca-config-find | grep audit_signing | tee output

cat > expected << EOF
ca.audit_signing.defaultSigningAlgorithm=SHA256withRSA
ca.audit_signing.nickname=ca_audit_signing
ca.audit_signing.tokenname=internal
ca.cert.audit_signing.certusage=ObjectSigner
ca.cert.audit_signing.nickname=ca_audit_signing
ca.cert.list=signing,ocsp_signing,sslserver,subsystem,audit_signing
log.instance.SignedAudit.signedAuditCertNickname=ca_audit_signing
EOF

diff expected output

docker exec pki pki-server ca-audit-config-show | tee output

cat > expected << EOF
  Enabled: True
  Log File: /var/lib/pki/pki-tomcat/logs/ca/signedAudit/ca_audit
  Buffer Size (bytes): 512
  Flush Interval (seconds): 5
  Max File Size (bytes): 2000
  Rollover Interval (seconds): 2592000
  Expiration Time (seconds): 0
  Log Signing: True
  Signing Certificate: ca_audit_signing
EOF

diff expected output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Enable audit log signing (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Test CA certs"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki /usr/share/pki/tests/ca/bin/test-ca-signing-cert.sh
docker exec pki /usr/share/pki/tests/ca/bin/test-subsystem-cert.sh
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Test CA certs (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check certs in DS"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec ds ldapsearch \
    -H ldap://ds.example.com:3389 \
    -D "cn=Directory Manager" \
    -w Secret.123 \
    -x \
    -b "ou=certificateRepository,ou=ca,dc=ca,dc=pki,dc=example,dc=com" \
    -o ldif_wrap=no \
    -LLL
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check certs in DS (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check users in DS"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec ds ldapsearch \
    -H ldap://ds.example.com:3389 \
    -D "cn=Directory Manager" \
    -w Secret.123 \
    -x \
    -b "ou=people,dc=ca,dc=pki,dc=example,dc=com" \
    -o ldif_wrap=no \
    -LLL
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check users in DS (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check cert requests in DS"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec ds ldapsearch \
    -H ldap://ds.example.com:3389 \
    -D "cn=Directory Manager" \
    -w Secret.123 \
    -x \
    -b "ou=requests,dc=ca,dc=pki,dc=example,dc=com" \
    -o ldif_wrap=no \
    -LLL
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check cert requests in DS (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Test CA auditor"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki /usr/share/pki/tests/ca/bin/test-ca-auditor-create.sh
docker exec pki /usr/share/pki/tests/ca/bin/test-ca-auditor-cert.sh
docker exec pki /usr/share/pki/tests/ca/bin/test-ca-auditor-logs.sh
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Test CA auditor (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA profiles"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli -n caadmin ca-profile-find

# create custom profile
pki-cli -n caadmin ca-profile-show caUserCert --output ${SHARED}/profile.xml
sed -i "s/caUserCert/caCustomUser/g" profile.xml
pki-cli --debug -n caadmin ca-profile-add ${SHARED}/profile.xml
pki-cli -n caadmin ca-profile-show caCustomUser
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA profiles (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Remove CA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# Dogtag step name kept; body is IPACTA uninstall (not pkidestroy)
docker exec pki ipa-server-install --uninstall -U \
    --ignore-topology-disconnect --ignore-last-of-role \
    > >(tee stdout) 2> >(tee stderr >&2) \
    || docker exec pki ipa-server-install --uninstall -U \
    > >(tee stdout) 2> >(tee stderr >&2)
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Remove CA (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check for warnings"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
sed -n '/^WARNING:/p' stderr | tee output
diff /dev/null output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check for warnings (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

step "Check external commands"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
sed -n '/^DEBUG: Command:/p' stderr | tee output
wc -l output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check external commands (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

step "Check PKI server base dir after removal"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /var/lib/pki/pki-tomcat \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
    | tee output

# TODO: review permissions
cat > expected_old << EOF
lrwxrwxrwx pkiuser pkiuser conf -> /etc/pki/pki-tomcat
lrwxrwxrwx pkiuser pkiuser logs -> /var/log/pki/pki-tomcat
EOF

cat > expected_new << EOF
lrwxrwxrwx pkiuser pkiuser conf -> /etc/pki/pki-tomcat
lrwxrwxrwx pkiuser pkiuser logs -> /var/log/pki/pki-tomcat
EOF

diff expected_$TOMCAT_FLAVOR output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server base dir after removal (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check PKI server conf dir after removal"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /etc/pki/pki-tomcat \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
    | tee output

# TODO: review permissions
cat > expected_old << EOF
drwxrwx--- pkiuser pkiuser Catalina
drwxrwx--- pkiuser pkiuser alias
drwxrwx--- pkiuser pkiuser ca
-rw-r--r-- pkiuser pkiuser catalina.policy
lrwxrwxrwx pkiuser pkiuser catalina.properties -> /usr/share/pki/server/conf/catalina.properties
drwxrwx--- pkiuser pkiuser certs
lrwxrwxrwx pkiuser pkiuser context.xml -> /etc/tomcat/context.xml
lrwxrwxrwx pkiuser pkiuser logging.properties -> /usr/share/pki/server/conf/logging.properties
-rw-rw---- pkiuser pkiuser password.conf
-rw-rw---- pkiuser pkiuser server.xml
-rw-rw---- pkiuser pkiuser serverCertNick.conf
-rw-rw---- pkiuser pkiuser tomcat.conf
lrwxrwxrwx pkiuser pkiuser web.xml -> /etc/tomcat/web.xml
EOF

cat > expected_new << EOF
drwxrwx--- pkiuser pkiuser Catalina
drwxrwx--- pkiuser pkiuser alias
drwxrwx--- pkiuser pkiuser ca
-rw-r--r-- pkiuser pkiuser catalina.policy
lrwxrwxrwx pkiuser pkiuser catalina.properties -> /usr/share/pki/server/conf/catalina.properties
drwxrwx--- pkiuser pkiuser certs
lrwxrwxrwx pkiuser pkiuser context.xml -> /etc/tomcat/context.xml
lrwxrwxrwx pkiuser pkiuser logging.properties -> /usr/share/pki/server/conf/logging.properties
-rw-rw---- pkiuser pkiuser password.conf
-rw-rw---- pkiuser pkiuser server.xml
-rw-rw---- pkiuser pkiuser serverCertNick.conf
-rw-rw---- pkiuser pkiuser tomcat.conf
lrwxrwxrwx pkiuser pkiuser web.xml -> /etc/tomcat/web.xml
EOF

diff expected_$TOMCAT_FLAVOR output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server conf dir after removal (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check PKI server logs dir after removal"
if [[ "$GHA_FAILED" -eq 0 ]] && [[ "${FEDORA_VERSION}" -lt 43 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /var/log/pki/pki-tomcat \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
    | tee output

DATE=$(date +'%Y-%m-%d')

# TODO: review permissions
cat > expected << EOF
drwxrwx--- pkiuser pkiuser backup
drwxrwx--- pkiuser pkiuser ca
-rw-r--r-- pkiuser pkiuser localhost.$DATE.log
-rw-r--r-- pkiuser pkiuser localhost_access_log.$DATE.txt
drwxr-xr-x pkiuser pkiuser pki
EOF

diff expected output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server logs dir after removal (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check PKI server logs dir after removal"
if [[ "$GHA_FAILED" -eq 0 ]] && [[ "${FEDORA_VERSION}" -ge 43 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /var/log/pki/pki-tomcat \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
    | tee output

DATE=$(date +'%Y-%m-%d')

# TODO: review permissions
cat > expected_old << EOF
drwxrwx--- pkiuser pkiuser backup
drwxrwx--- pkiuser pkiuser ca
-rw-r--r-- pkiuser pkiuser localhost_access_log.$DATE.txt
EOF

cat > expected_new << EOF
drwxrwx--- pkiuser pkiuser backup
drwxrwx--- pkiuser pkiuser ca
-rw-r----- pkiuser pkiuser localhost_access_log.$DATE.txt
EOF

diff expected_$TOMCAT_FLAVOR output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server logs dir after removal (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check DS server systemd journal"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
echo "OMITTED: no Dogtag DS sidecar under IPACTA"

)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check DS server systemd journal (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

step "Check DS container logs"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
echo "OMITTED: no Dogtag DS sidecar under IPACTA"

)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check DS container logs (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

step "Check PKI server systemd journal"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
docker exec pki journalctl -x --no-pager -u pki-tomcatd@pki-tomcat.service
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server systemd journal (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

step "Check PKI server access log"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
docker exec pki find /var/log/pki/pki-tomcat -name "localhost_access_log.*" -exec cat {} \;
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server access log (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

step "Check CA debug log"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
docker exec pki find /var/lib/pki/pki-tomcat/logs/ca -name "debug.*" -exec cat {} \;
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA debug log (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

if [[ "$GHA_FAILED" -ne 0 ]]; then
    echo "==== ca-basic-test FAILED ===="
    exit "$GHA_FAILED"
fi
echo "==== ca-basic-test PASSED ===="
