#!/bin/bash
# Dogtag tests/tmt/kra-basic-test (GHA kra-basic-test.yml) adapted for pki-cli:
# - Step names/harness from Dogtag (source of truth)
# - Server: freeipa-ipacta (IPACTA), container name "pki"
# - Host client: pki-cli; Install CA/KRA via ipa-server-install / ipa-kra-install
#
set -euo pipefail

REPO_ROOT="${TMT_TREE:-}"
if [[ -z "$REPO_ROOT" || ! -f "$REPO_ROOT/pyproject.toml" ]]; then
    REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
fi
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

# Ensure docker and pki-runner are available
if ! command -v docker >/dev/null; then
    echo "ERROR: docker not found" >&2
    exit 1
fi

cleanup() {
    docker rm -f ds pki 2>/dev/null || true
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

step "Get Tomcat flavor"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
TOMCAT_FLAVOR=$(docker exec pki test -f /usr/libexec/tomcat/tomcat-run.sh && echo "new" || echo "old")
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

step "Check pki kra CLI help messages"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
command -v pki-cli >/dev/null
pki-cli --help >/dev/null
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
expect_cli kra
expect_cli kra --help
expect_cli kra-key-find --help
expect_cli kra-key-show --help
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check pki kra CLI help messages (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Install CA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
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
    --no-ntp
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Install CA (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check keywrap config in CA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# OAEP should be disabled
docker exec pki pki-server ca-config-find \
    | sed -n \
        -e '/^keyWrap\./p' \
    | sort \
    | tee output

diff /dev/null output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check keywrap config in CA (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check security domain config in CA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# CA should run security domain service
cat > expected << EOF
securitydomain.checkIP=false
securitydomain.checkinterval=300000
securitydomain.flushinterval=86400000
securitydomain.host=pki.example.com
securitydomain.httpport=8080
securitydomain.httpsadminport=8443
securitydomain.name=EXAMPLE
securitydomain.select=new
securitydomain.source=ldap
EOF

docker exec pki pki-server ca-config-find | grep ^securitydomain. | sort | tee actual
diff expected actual

docker exec pki pki-server cert-export ca_signing --cert-file ${SHARED}/ca_signing.crt

pki-cli nss-cert-import \
    --cert $SHARED/ca_signing.crt \
    --trust CT,C,C \
    ca_signing

# REST API should return security domain info
cat > expected << EOF
  Domain: EXAMPLE

  CA Subsystem:

    Host ID: CA pki.example.com 8443
    Hostname: pki.example.com
    Port: 8080
    Secure Port: 8443
    Domain Manager: TRUE

EOF
pki-cli securitydomain-show | tee output
diff expected output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check security domain config in CA (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA admin cert"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki ls -la /root/.dogtag/pki-tomcat
docker exec pki cat /root/.dogtag/pki-tomcat/ca_admin.cert
docker exec pki openssl x509 -text -noout -in /root/.dogtag/pki-tomcat/ca_admin.cert
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA admin cert (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Install KRA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
PASSWORD="${IPA_PASSWORD:-Secret.123}"
docker exec pki ipa-kra-install -U -p "$PASSWORD" \
    > >(tee stdout) 2> >(tee stderr >&2)
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Install KRA (rc=$_rc)" >&2
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
drwxrwx--- pkiuser pkiuser kra
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
drwxrwx--- pkiuser pkiuser kra
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
drwxrwx--- pkiuser pkiuser kra
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
drwxrwx--- pkiuser pkiuser kra
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
-rw------- pkiuser pkiuser ca.crt
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
-rw-rw---- pkiuser pkiuser kra.xml
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
drwxrwx--- pkiuser pkiuser kra
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
drwxrwx--- pkiuser pkiuser kra
-rw-r--r-- pkiuser pkiuser localhost_access_log.$DATE.txt
EOF

cat > expected_new << EOF
drwxrwx--- pkiuser pkiuser backup
drwxrwx--- pkiuser pkiuser ca
drwxrwx--- pkiuser pkiuser kra
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

step "Check KRA base dir"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /var/lib/pki/pki-tomcat/kra \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
    | tee output

# TODO: review permissions
cat > expected_old << EOF
lrwxrwxrwx pkiuser pkiuser alias -> /var/lib/pki/pki-tomcat/alias
lrwxrwxrwx pkiuser pkiuser conf -> /var/lib/pki/pki-tomcat/conf/kra
lrwxrwxrwx pkiuser pkiuser logs -> /var/lib/pki/pki-tomcat/logs/kra
lrwxrwxrwx pkiuser pkiuser registry -> /etc/sysconfig/pki/tomcat/pki-tomcat
EOF

cat > expected_new << EOF
lrwxrwxrwx pkiuser pkiuser alias -> /var/lib/pki/pki-tomcat/alias
lrwxrwxrwx pkiuser pkiuser conf -> /var/lib/pki/pki-tomcat/conf/kra
lrwxrwxrwx pkiuser pkiuser logs -> /var/lib/pki/pki-tomcat/logs/kra
lrwxrwxrwx pkiuser pkiuser registry -> /etc/sysconfig/pki/tomcat/pki-tomcat
EOF

diff expected_$TOMCAT_FLAVOR output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check KRA base dir (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check KRA conf dir"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec pki ls -l /var/lib/pki/pki-tomcat/conf/kra \
    | sed \
        -e '/^total/d' \
        -e 's/^\(\S*\)\./\1/' \
        -e 's/^\(\S*\) *\S* *\(\S*\) *\(\S*\) *\S* *\S* *\S* *\S* *\(.*\)$/\1 \2 \3 \4/' \
    | tee output

# TODO: review permissions
cat > expected_old << EOF
-rw-rw---- pkiuser pkiuser CS.cfg
-rw-rw---- pkiuser pkiuser registry.cfg
EOF

cat > expected_new << EOF
-rw-rw---- pkiuser pkiuser CS.cfg
-rw-rw---- pkiuser pkiuser registry.cfg
EOF

diff expected_$TOMCAT_FLAVOR output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check KRA conf dir (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check keywrap config in KRA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# OAEP should be disabled
docker exec pki pki-server kra-config-find \
    | sed -n \
        -e '/^keyWrap\./p' \
    | sort \
    | tee output

diff /dev/null output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check keywrap config in KRA (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check transport unit config in KRA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server kra-config-find \
    | sed -n \
        -e '/^kra\.transportUnit\./p' \
    | sort \
    | tee output

cat > expected << EOF
kra.transportUnit.nickName=kra_transport
kra.transportUnit.signingAlgorithm=SHA256withRSA
EOF

diff expected output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check transport unit config in KRA (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check storage unit config in KRA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server kra-config-find \
    | sed -n \
        -e '/^kra\.storageUnit\.wrapping\._/d' \
        -e '/^kra\.storageUnit\./p' \
    | sort \
    | tee output

cat > expected << EOF
kra.storageUnit.nickName=kra_storage
kra.storageUnit.wrapping.0.payloadEncryptionAlgorithm=DESede
kra.storageUnit.wrapping.0.payloadEncryptionIV=AQEBAQEBAQE=
kra.storageUnit.wrapping.0.payloadEncryptionMode=CBC
kra.storageUnit.wrapping.0.payloadEncryptionPadding=PKCS5Padding
kra.storageUnit.wrapping.0.payloadWrapAlgorithm=DES3/CBC/Pad
kra.storageUnit.wrapping.0.payloadWrapIV=AQEBAQEBAQE=
kra.storageUnit.wrapping.0.sessionKeyKeyGenAlgorithm=DESede
kra.storageUnit.wrapping.0.sessionKeyLength=168
kra.storageUnit.wrapping.0.sessionKeyType=DESede
kra.storageUnit.wrapping.0.sessionKeyWrapAlgorithm=RSA
kra.storageUnit.wrapping.1.payloadEncryptionAlgorithm=AES
kra.storageUnit.wrapping.1.payloadEncryptionIVLen=16
kra.storageUnit.wrapping.1.payloadEncryptionMode=CBC
kra.storageUnit.wrapping.1.payloadEncryptionPadding=PKCS5Padding
kra.storageUnit.wrapping.1.payloadWrapAlgorithm=AES KeyWrap/Padding
kra.storageUnit.wrapping.1.sessionKeyKeyGenAlgorithm=AES
kra.storageUnit.wrapping.1.sessionKeyLength=128
kra.storageUnit.wrapping.1.sessionKeyType=AES
kra.storageUnit.wrapping.1.sessionKeyWrapAlgorithm=RSA
kra.storageUnit.wrapping.2.payloadEncryptionAlgorithm=AES
kra.storageUnit.wrapping.2.payloadEncryptionIVLen=16
kra.storageUnit.wrapping.2.payloadEncryptionMode=CBC
kra.storageUnit.wrapping.2.payloadEncryptionPadding=PKCS5Padding
kra.storageUnit.wrapping.2.payloadWrapAlgorithm=AES KeyWrap/Padding
kra.storageUnit.wrapping.2.sessionKeyLength=256
kra.storageUnit.wrapping.2.sessionKeyType=AES
kra.storageUnit.wrapping.choice=1
EOF

diff expected output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check storage unit config in KRA (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check PKCS #12 encryption config in KRA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# PKCS #12 encryption should not be configured
docker exec pki pki-server kra-config-find \
    | sed -n \
        -e '/^kra\.legacyPKCS12=/p' \
        -e '/^kra\.nonLegacyAlg=/p' \
    | sort \
    | tee output

diff /dev/null output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKCS #12 encryption config in KRA (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check PKI server system certs"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-find
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server system certs (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check PKI server status"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server status | tee output

# CA should be a domain manager, but KRA should not
echo "True" > expected
echo "False" >> expected
sed -n 's/^ *SD Manager: *\(.*\)$/\1/p' output > actual
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check PKI server status (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check KRA storage cert"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-export \
    --cert-file kra_storage.crt \
    kra_storage

docker exec pki openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/kra_storage.csr

docker exec pki openssl x509 -text -noout -in kra_storage.crt

docker exec pki pki-server cert-validate kra_storage
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check KRA storage cert (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check KRA transport cert"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-export \
    --cert-file kra_transport.crt \
    kra_transport

docker exec pki openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/kra_transport.csr

docker exec pki openssl x509 -text -noout -in kra_transport.crt

docker exec pki pki-server cert-validate kra_transport
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check KRA transport cert (rc=$_rc)" >&2
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

docker exec pki openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/subsystem.csr

docker exec pki openssl x509 -text -noout -in subsystem.crt

docker exec pki pki-server cert-validate subsystem
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

docker exec pki openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/sslserver.csr

docker exec pki openssl x509 -text -noout -in sslserver.crt

docker exec pki pki-server cert-validate sslserver
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check SSL server cert (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check CA admin cert after installing KRA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki ls -la /root/.dogtag/pki-tomcat
docker exec pki cat /root/.dogtag/pki-tomcat/ca_admin.cert

docker exec pki openssl x509 -text -noout \
    -in /root/.dogtag/pki-tomcat/ca_admin.cert
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA admin cert after installing KRA (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check security domain after installing KRA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# KRA should join security domain in CA
cat > expected << EOF
securitydomain.host=pki.example.com
securitydomain.httpport=8080
securitydomain.httpsadminport=8443
securitydomain.name=EXAMPLE
securitydomain.select=existing
EOF

docker exec pki pki-server kra-config-find | grep ^securitydomain. | sort | tee actual
diff expected actual

# REST API should return security domain info
cat > expected << EOF
  Domain: EXAMPLE

  CA Subsystem:

    Host ID: CA pki.example.com 8443
    Hostname: pki.example.com
    Port: 8080
    Secure Port: 8443
    Domain Manager: TRUE

  KRA Subsystem:

    Host ID: KRA pki.example.com 8443
    Hostname: pki.example.com
    Port: 8080
    Secure Port: 8443
    Domain Manager: FALSE

EOF

pki-cli securitydomain-show | tee output
diff expected output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check security domain after installing KRA (rc=$_rc)" >&2
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

step "Check CA info"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
cat > expected << EOF
{
    "ArchivalMechanism": "keywrap",
    "EncryptionAlgorithm": "AES/CBC/PKCS5Padding",
    "KeyWrapAlgorithm": "AES KeyWrap/Padding",
    "RsaPublicKeyWrapAlgorithm": "RSA",
    "CaRsaPublicKeyWrapAlgorithm": "RSA",
    "Attributes": {
        "Attribute": []
    }
}
EOF

docker exec pki curl -ks https://pki.example.com:8443/ca/v2/info \
    | python -m json.tool \
    | tee actual

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check CA info (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check KRA info"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
cat > expected << EOF
{
    "ArchivalMechanism": "keywrap",
    "RecoveryMechanism": "keywrap",
    "EncryptionAlgorithm": "AES/CBC/PKCS5Padding",
    "WrapAlgorithm": "AES KeyWrap/Padding",
    "RsaPublicKeyWrapAlgorithm": "RSA",
    "Attributes": {
        "Attribute": []
    }
}
EOF

docker exec pki curl -ks https://pki.example.com:8443/kra/v2/info \
    | python -m json.tool \
    | tee actual

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check KRA info (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check KRA admin"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki pki-server cert-export \
    --cert-file ca_signing.crt \
    ca_signing

pki-cli nss-cert-import \
    --cert ca_signing.crt \
    --trust CT,C,C \
    ca_signing

pki-cli pkcs12-import \
    --pkcs12 /root/.dogtag/pki-tomcat/ca_admin_cert.p12 \
    --pkcs12-password Secret.123

pki-cli nss-cert-verify \
    --cert-usage SSLClient \
    caadmin

pki-cli -n caadmin kra-user-show kraadmin
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check KRA admin (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check KRA connector in CA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
TRANSPORT_CERT=$(docker exec pki openssl x509 \
    -in kra_transport.crt \
    -outform der \
    | base64 --wrap=0)

docker exec pki pki-server ca-config-find | grep ^ca\.connector.KRA\. | tee output

# KRA connector should be configured
cat > expected << EOF
ca.connector.KRA.enable=true
ca.connector.KRA.host=pki.example.com
ca.connector.KRA.local=false
ca.connector.KRA.nickName=subsystem
ca.connector.KRA.port=8443
ca.connector.KRA.timeout=30
ca.connector.KRA.transportCert=$TRANSPORT_CERT
ca.connector.KRA.uri=/kra/agent/kra/connector
EOF

diff expected output

docker exec pki pki-server ca-connector-find | tee output

# KRA connector should be configured
cat > expected << EOF
  Connector ID: KRA
  Enabled: true
  URL: https://pki.example.com:8443
  Nickname: subsystem
EOF

diff expected output

# REST API should return KRA connector info
pki-cli -n caadmin ca-kraconnector-show | tee output
sed -n 's/\s*Host:\s\+\(\S\+\):.*/\1/p' output > actual
echo pki.example.com > expected
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check KRA connector in CA (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Import transport cert"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli nss-cert-import \
    --cert kra_transport.crt \
    kra_transport
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Import transport cert (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check initial key requests"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-request-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/entries matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

diff /dev/null actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check initial key requests (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check initial keys"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/key(s) matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

diff /dev/null actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check initial keys (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Generate AES key"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-generate \
    --key-algorithm AES \
    --key-size 256 \
    --usages encrypt,decrypt \
    test-aes-keygen \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/Key generation request info/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

cat > expected << EOF
  Type: symkeyGenRequest
  Status: complete
EOF

diff expected actual

sed -n 's/^ *Key ID: *\(.*\)$/\1/p' output > test-aes-keygen.key_id
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Generate AES key (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check key requests after AES key generation"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-request-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/entries matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 1 key request
cat > expected << EOF
  Type: symkeyGenRequest
  Status: complete
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check key requests after AES key generation (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check keys after AES key generation"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/key(s) matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 1 key
cat > expected << EOF
  Client Key ID: test-aes-keygen
  Status: active
  Algorithm: AES
  Size: 256
  Owner: kraadmin
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check keys after AES key generation (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Generate RSA key"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-generate \
    --key-algorithm RSA \
    --key-size 2048 \
    test-rsa-keygen \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/Key generation request info/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

cat > expected << EOF
  Type: asymkeyGenRequest
  Status: complete
EOF

diff expected actual

sed -n 's/^ *Key ID: *\(.*\)$/\1/p' output > test-rsa-keygen.key_id
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Generate RSA key (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check key requests after RSA key generation"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-request-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/entries matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 2 key requests
cat > expected << EOF
  Type: symkeyGenRequest
  Status: complete

  Type: asymkeyGenRequest
  Status: complete
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check key requests after RSA key generation (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check keys after RSA key generation"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/key(s) matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 2 keys
cat > expected << EOF
  Client Key ID: test-aes-keygen
  Status: active
  Algorithm: AES
  Size: 256
  Owner: kraadmin

  Client Key ID: test-rsa-keygen
  Status: active
  Algorithm: RSA
  Size: 2048
  Owner: kraadmin
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check keys after RSA key generation (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Enroll cert with key archival"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# generate key and cert request
# https://github.com/dogtagpki/pki/wiki/Generating-Certificate-Request-with-PKI-NSS
pki-cli \
    nss-cert-request \
    --type crmf \
    --subject UID=testuser \
    --transport kra_transport \
    --csr testuser.csr

docker exec pki cat testuser.csr

# issue cert
# https://github.com/dogtagpki/pki/wiki/Issuing-Certificates
pki-cli \
    -u caadmin \
    -w Secret.123 \
    ca-cert-issue \
    --request-type crmf \
    --profile caUserCert \
    --subject UID=testuser \
    --csr-file testuser.csr \
    --output-file testuser.crt

# import cert into NSS database
pki-cli nss-cert-import --cert testuser.crt testuser

# the cert should match the key (trust flags must be u,u,u)
echo "u,u,u" > expected
pki-cli nss-cert-show testuser | tee output
sed -n "s/^\s*Trust Flags:\s*\(\S*\)$/\1/p" output > actual
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Enroll cert with key archival (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check key requests after enrollment"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-request-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/entries matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 3 key requests
cat > expected << EOF
  Type: symkeyGenRequest
  Status: complete

  Type: asymkeyGenRequest
  Status: complete

  Type: enrollment
  Status: complete
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check key requests after enrollment (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check keys after enrollment"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/key(s) matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 3 keys
cat > expected << EOF
  Client Key ID: test-aes-keygen
  Status: active
  Algorithm: AES
  Size: 256
  Owner: kraadmin

  Client Key ID: test-rsa-keygen
  Status: active
  Algorithm: RSA
  Size: 2048
  Owner: kraadmin

  Algorithm: 1.2.840.113549.1.1.1
  Size: 2048
  Owner: UID=testuser
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check keys after enrollment (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check archived cert key"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# find archived key by owner
pki-cli \
    -n caadmin \
    kra-key-find \
    --owner UID=testuser \
    | tee output

KEY_ID=$(sed -n "s/^\s*Key ID:\s*\(\S*\)$/\1/p" output)
echo "Key ID: $KEY_ID"
echo $KEY_ID > cert.key_id

DEC_KEY_ID=$(python -c "print(int('$KEY_ID', 16))")
echo "Dec Key ID: $DEC_KEY_ID"

# get key record
docker exec ds ldapsearch \
    -H ldap://ds.example.com:3389 \
    -x \
    -D "cn=Directory Manager" \
    -w Secret.123 \
    -b "cn=$DEC_KEY_ID,ou=keyRepository,ou=kra,dc=kra,dc=pki,dc=example,dc=com" \
    -o ldif_wrap=no \
    -LLL | tee output

# encryption mode should be "false" by default
echo "false" > expected
sed -n 's/^metaInfo:\s*payloadEncrypted:\(.*\)$/\1/p' output > actual
diff expected actual

# key wrap algorithm should be "AES KeyWrap/Padding" by default
echo "AES KeyWrap/Padding" > expected
sed -n 's/^metaInfo:\s*payloadWrapAlgorithm:\(.*\)$/\1/p' output > actual
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check archived cert key (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Retrieve cert key"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
KEY_ID=$(cat cert.key_id)
echo "Key ID: $KEY_ID"

# export cert into Base64-encoded format
BASE64_CERT=$(pki-cli nss-cert-export --format DER testuser | base64 --wrap=0)
echo "Cert: $BASE64_CERT"

# create retrieval request with key ID, cert, and passphrase
cat > request.json <<EOF
{
  "ClassName" : "com.netscape.certsrv.key.KeyRecoveryRequest",
  "Attributes" : {
    "Attribute" : [ {
      "name" : "keyId",
      "value" : "$KEY_ID"
    }, {
      "name" : "certificate",
      "value" : "$BASE64_CERT"
    }, {
      "name" : "passphrase",
      "value" : "Secret.123"
    } ]
  }
}
EOF

# retrieve archived cert and key into PKCS #12 file
# https://github.com/dogtagpki/pki/wiki/Retrieving-Archived-Key
pki-cli \
    -n caadmin \
    kra-key-retrieve \
    --input $SHARED/request.json \
    --transport kra_transport \
    --output-data archived.p12

# import PKCS #12 file into NSS database with the passphrase
pki-cli \
    -d nssdb \
    pkcs12-import \
    --pkcs12 archived.p12 \
    --password Secret.123

# remove archived cert from NSS database
pki-cli -d nssdb nss-cert-del UID=testuser

# import original cert into NSS database
pki-cli -d nssdb nss-cert-import --cert testuser.crt testuser

# the original cert should match the archived key (trust flags must be u,u,u)
echo "u,u,u" > expected
pki-cli -d nssdb nss-cert-show testuser | tee output
sed -n "s/^\s*Trust Flags:\s*\(\S*\)$/\1/p" output > actual
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Retrieve cert key (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check key requests after retrieval"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-request-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/entries matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 4 key requests
cat > expected << EOF
  Type: symkeyGenRequest
  Status: complete

  Type: asymkeyGenRequest
  Status: complete

  Type: enrollment
  Status: complete

  Type: recovery
  Status: complete
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check key requests after retrieval (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check keys after retrieval"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/key(s) matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 3 keys
cat > expected << EOF
  Client Key ID: test-aes-keygen
  Status: active
  Algorithm: AES
  Size: 256
  Owner: kraadmin

  Client Key ID: test-rsa-keygen
  Status: active
  Algorithm: RSA
  Size: 2048
  Owner: kraadmin

  Algorithm: 1.2.840.113549.1.1.1
  Size: 2048
  Owner: UID=testuser
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check keys after retrieval (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Deactivate cert key"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
KEY_ID=$(cat cert.key_id)
echo "KEY_ID: $KEY_ID"

pki-cli \
    -n caadmin \
    kra-key-mod \
    --status inactive \
    $KEY_ID \
    | tee output

cat > expected << EOF
  Key ID: $KEY_ID
  Status: inactive
  Algorithm: 1.2.840.113549.1.1.1
  Size: 2048
  Owner: UID=testuser
EOF

diff expected output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Deactivate cert key (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check key requests after deactivation"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-request-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/entries matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 4 key requests
cat > expected << EOF
  Type: symkeyGenRequest
  Status: complete

  Type: asymkeyGenRequest
  Status: complete

  Type: enrollment
  Status: complete

  Type: recovery
  Status: complete
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check key requests after deactivation (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check keys after deactivation"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/key(s) matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 3 keys
cat > expected << EOF
  Client Key ID: test-aes-keygen
  Status: active
  Algorithm: AES
  Size: 256
  Owner: kraadmin

  Client Key ID: test-rsa-keygen
  Status: active
  Algorithm: RSA
  Size: 2048
  Owner: kraadmin

  Status: inactive
  Algorithm: 1.2.840.113549.1.1.1
  Size: 2048
  Owner: UID=testuser
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check keys after deactivation (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Archive secret"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# generate random secret
head -c 1K < /dev/urandom > secret.archived

pki-cli \
    -n caadmin \
    kra-key-archive \
    --clientKeyID test-secret \
    --transport kra_transport \
    --input-data $SHARED/secret.archived \
    -v

# get key ID
pki-cli \
    -n caadmin \
    kra-key-find \
    --clientKeyID test-secret | tee output

sed -n 's/^ *Key ID: *\(.*\)$/\1/p' output > cert.key_id
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Archive secret (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check key requests after secret archival"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-request-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/entries matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 5 key requests
cat > expected << EOF
  Type: symkeyGenRequest
  Status: complete

  Type: asymkeyGenRequest
  Status: complete

  Type: enrollment
  Status: complete

  Type: recovery
  Status: complete

  Type: securityDataEnrollment
  Status: complete
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check key requests after secret archival (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check keys after secret archival"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/key(s) matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 4 keys
cat > expected << EOF
  Client Key ID: test-aes-keygen
  Status: active
  Algorithm: AES
  Size: 256
  Owner: kraadmin

  Client Key ID: test-rsa-keygen
  Status: active
  Algorithm: RSA
  Size: 2048
  Owner: kraadmin

  Status: inactive
  Algorithm: 1.2.840.113549.1.1.1
  Size: 2048
  Owner: UID=testuser

  Client Key ID: test-secret
  Status: active
  Owner: kraadmin
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check keys after secret archival (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Retrieve secret"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
KEY_ID=$(cat cert.key_id)
echo "KEY_ID: $KEY_ID"

pki-cli \
    -n caadmin \
    kra-key-retrieve \
    --keyID $KEY_ID \
    --transport kra_transport \
    --output-data $SHARED/secret.retrieved \
    -v

diff secret.archived secret.retrieved
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Retrieve secret (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check key requests after secret retrieval"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-request-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/entries matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 6 key requests
cat > expected << EOF
  Type: symkeyGenRequest
  Status: complete

  Type: asymkeyGenRequest
  Status: complete

  Type: enrollment
  Status: complete

  Type: recovery
  Status: complete

  Type: securityDataEnrollment
  Status: complete

  Type: securityDataRecovery
  Status: complete
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check key requests after secret retrieval (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Check keys after secret retrieval"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
pki-cli \
    -n caadmin \
    kra-key-find \
    | tee output

# normalize output
sed \
    -e '/-----/d' \
    -e '/key(s) matched/d' \
    -e '/Number of entries returned/d' \
    -e '/^ *Request ID:/d' \
    -e '/^ *Key ID:/d' \
    -e '/^ *Creation Time:/d' \
    -e '/^ *Modification Time:/d' \
    output > actual

# there should be 4 keys
cat > expected << EOF
  Client Key ID: test-aes-keygen
  Status: active
  Algorithm: AES
  Size: 256
  Owner: kraadmin

  Client Key ID: test-rsa-keygen
  Status: active
  Algorithm: RSA
  Size: 2048
  Owner: kraadmin

  Status: inactive
  Algorithm: 1.2.840.113549.1.1.1
  Size: 2048
  Owner: UID=testuser

  Client Key ID: test-secret
  Status: active
  Owner: kraadmin
EOF

diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check keys after secret retrieval (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
fi

step "Remove KRA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
# Dogtag step name kept; IPACTA has no separate kra destroy — uninstall with CA
echo "OMITTED: IPACTA KRA removed with ipa-server-install --uninstall (Remove CA)"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Remove KRA (rc=$_rc)" >&2
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

step "Remove CA"
if [[ "$GHA_FAILED" -eq 0 ]]; then
set +e
(
set -euo pipefail
docker exec pki ipa-server-install --uninstall -U \
    --ignore-topology-disconnect --ignore-last-of-role \
    || docker exec pki ipa-server-install --uninstall -U
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Remove CA (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi
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
drwxrwx--- pkiuser pkiuser kra
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
drwxrwx--- pkiuser pkiuser kra
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
drwxrwx--- pkiuser pkiuser kra
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
drwxrwx--- pkiuser pkiuser kra
-rw-r--r-- pkiuser pkiuser localhost_access_log.$DATE.txt
EOF

cat > expected_new << EOF
drwxrwx--- pkiuser pkiuser backup
drwxrwx--- pkiuser pkiuser ca
drwxrwx--- pkiuser pkiuser kra
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

step "Check KRA debug log"
# GHA if: always() — run even after prior step failures; may fail the test
set +e
(
set -euo pipefail
docker exec pki find /var/lib/pki/pki-tomcat/logs/kra -name "debug.*" -exec cat {} \;
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    echo "FAIL: Check KRA debug log (rc=$_rc)" >&2
    GHA_FAILED=$_rc
fi

if [[ "$GHA_FAILED" -ne 0 ]]; then
    echo "==== kra-basic-test FAILED ===="
    exit "$GHA_FAILED"
fi
echo "==== kra-basic-test PASSED ===="
