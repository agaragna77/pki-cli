#!/bin/bash
# IPACTA kra-basic-test for agaragna77/pki-cli — from freeipa generated port
# of Dogtag tests/tmt/kra-basic-test. Host client: pki-cli venv.
# Dogtag-only layout is OMITTED. Remaining checks collect failures
# (no fail-stop) so Install CA/ACME/KRA still run.
set -euo pipefail

REPO_ROOT="${TMT_TREE:-}"
if [[ -z "$REPO_ROOT" || ! -f "$REPO_ROOT/tests/tmt/bin/ipacta-tmt-common.sh" ]]; then
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
source "$REPO_ROOT/tests/tmt/bin/ipacta-tmt-common.sh"
export GITHUB_WORKSPACE="$REPO_ROOT"
export SHARED="${SHARED:-/tmp/workdir/pki}"
export GITHUB_ENV="${TMPDIR:-/tmp}/gha-env-$$"
touch "$GITHUB_ENV"
source_gha_env() { set -a; source "$GITHUB_ENV" 2>/dev/null || true; set +a; }
mkdir -p "$GITHUB_WORKSPACE"
export LC_ALL=C
FAILS=()
fail() { echo "FAIL: $*" >&2; FAILS+=("$*"); }

step "Host pki-cli smoke (venv)"
if ! command -v pki-cli >/dev/null 2>&1; then
    echo "ERROR: pki-cli not on PATH (prepare install-host-pki-cli should create .venv)" >&2
    exit 1
fi
pki-cli --help >/dev/null
echo "pki-cli=$(command -v pki-cli)"

step "Host pki-cli info (expect java-bound / exit 2 until REST)"
set +e
pki-cli info
info_rc=$?
set -e
echo "pki-cli info exit=${info_rc}"
if [[ "$info_rc" -eq 2 ]]; then
    echo "OK: java MainCLI gated (catalogue status java-bound) — expected for this PR"
elif [[ "$info_rc" -eq 0 ]]; then
    echo "NOTE: pki-cli info succeeded (REST path may be wired)"
else
    fail "pki-cli info unexpected exit ${info_rc} (want 2 java-bound or 0 REST pass)"
fi

trap ipacta_cleanup EXIT
ipacta_start_container

step "Clone repository"
set +e
(
set -euo pipefail
omit "Clone repository"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Clone repository (rc=$_rc)"
fi

step "Retrieve PKI images"
set +e
(
set -euo pipefail
omit "Retrieve PKI images"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Retrieve PKI images (rc=$_rc)"
fi

step "Load PKI images"
set +e
(
set -euo pipefail
docker image inspect "$IPA_IMAGE" >/dev/null
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Load PKI images (rc=$_rc)"
fi

step "Create network"
set +e
(
set -euo pipefail
echo "network example already created"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Create network (rc=$_rc)"
fi

step "Set up DS container"
set +e
(
set -euo pipefail
omit "Set up DS container"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Set up DS container (rc=$_rc)"
fi

step "Set up PKI container"
set +e
(
set -euo pipefail
echo "IPA container already running as $CONTAINER"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Set up PKI container (rc=$_rc)"
fi

step "Get Fedora version"
set +e
(
set -euo pipefail
FEDORA_VERSION=$(iexec sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
echo "FEDORA_VERSION=$FEDORA_VERSION"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Get Fedora version (rc=$_rc)"
fi

step "Get Tomcat flavor"
set +e
(
set -euo pipefail
iexec systemctl cat "$IPACTA_UNIT" | head -20 || true
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Get Tomcat flavor (rc=$_rc)"
fi

step "Check pki kra CLI help messages"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki kra
docker exec "$CONTAINER" pki kra --help
docker exec "$CONTAINER" pki kra-key-find --help
docker exec "$CONTAINER" pki kra-key-show --help
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check pki kra CLI help messages (rc=$_rc)"
fi

step "Install CA"
set +e
(
set -euo pipefail
ipacta_install_ca
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Install CA (rc=$_rc)"
fi

step "Check keywrap config in CA"
set +e
(
set -euo pipefail
# OAEP should be disabled
docker exec "$CONTAINER" pki-server ca-config-find \
    | sed -n \
        -e '/^keyWrap\./p' \
    | sort \
    | tee output
diff /dev/null output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check keywrap config in CA (rc=$_rc)"
fi

step "Check security domain config in CA"
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
docker exec "$CONTAINER" pki-server ca-config-find | grep ^securitydomain. | sort | tee actual
diff expected actual
docker exec "$CONTAINER" pki-server cert-export ca_signing --cert-file ${SHARED}/ca_signing.crt
docker exec "$CONTAINER" pki nss-cert-import \
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
docker exec "$CONTAINER" pki securitydomain-show | tee output
diff expected output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check security domain config in CA (rc=$_rc)"
fi

step "Check CA admin cert"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" ls -la /root/.dogtag/pki-tomcat
docker exec "$CONTAINER" cat /root/.dogtag/pki-tomcat/ca_admin.cert
docker exec "$CONTAINER" openssl x509 -text -noout -in /root/.dogtag/pki-tomcat/ca_admin.cert
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check CA admin cert (rc=$_rc)"
fi

step "Install KRA"
set +e
(
set -euo pipefail
ipacta_install_kra
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Install KRA (rc=$_rc)"
fi

step "Check for warnings"
set +e
(
set -euo pipefail
omit "Check for warnings"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check for warnings (rc=$_rc)"
fi

step "Check external commands"
set +e
(
set -euo pipefail
omit "Check external commands"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check external commands (rc=$_rc)"
fi

step "Check PKI server base dir after installation"
set +e
(
set -euo pipefail
omit "Check PKI server base dir after installation"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server base dir after installation (rc=$_rc)"
fi

step "Check PKI server conf dir after installation"
set +e
(
set -euo pipefail
omit "Check PKI server conf dir after installation"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server conf dir after installation (rc=$_rc)"
fi

step "Check server.xml"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" cat /etc/pki/pki-tomcat/server.xml
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check server.xml (rc=$_rc)"
fi

step "Check PKI server conf/alias dir after installation"
set +e
(
set -euo pipefail
omit "Check PKI server conf/alias dir after installation"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server conf/alias dir after installation (rc=$_rc)"
fi

step "Check PKI server conf/Catalina/localhost dir after installation"
set +e
(
set -euo pipefail
omit "Check PKI server conf/Catalina/localhost dir after installation"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server conf/Catalina/localhost dir after installation (rc=$_rc)"
fi

step "Check PKI server logs dir after installation"
set +e
(
set -euo pipefail
omit "Check PKI server logs dir after installation"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server logs dir after installation (rc=$_rc)"
fi

step "Check PKI server logs dir after installation"
set +e
(
set -euo pipefail
omit "Check PKI server logs dir after installation"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server logs dir after installation (rc=$_rc)"
fi

step "Check KRA base dir"
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec "$CONTAINER" ls -l /var/lib/pki/pki-tomcat/kra \
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
    fail "Check KRA base dir (rc=$_rc)"
fi

step "Check KRA conf dir"
set +e
(
set -euo pipefail
# check file types, owners, and permissions
docker exec "$CONTAINER" ls -l /var/lib/pki/pki-tomcat/conf/kra \
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
    fail "Check KRA conf dir (rc=$_rc)"
fi

step "Check keywrap config in KRA"
set +e
(
set -euo pipefail
# OAEP should be disabled
docker exec "$CONTAINER" pki-server kra-config-find \
    | sed -n \
        -e '/^keyWrap\./p' \
    | sort \
    | tee output
diff /dev/null output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check keywrap config in KRA (rc=$_rc)"
fi

step "Check transport unit config in KRA"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki-server kra-config-find \
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
    fail "Check transport unit config in KRA (rc=$_rc)"
fi

step "Check storage unit config in KRA"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki-server kra-config-find \
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
    fail "Check storage unit config in KRA (rc=$_rc)"
fi

step "Check PKCS #12 encryption config in KRA"
set +e
(
set -euo pipefail
# PKCS #12 encryption should not be configured
docker exec "$CONTAINER" pki-server kra-config-find \
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
    fail "Check PKCS #12 encryption config in KRA (rc=$_rc)"
fi

step "Check PKI server system certs"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki-server cert-find
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server system certs (rc=$_rc)"
fi

step "Check PKI server status"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki-server status | tee output
# CA should be a domain manager, but KRA should not
echo "True" > expected
echo "False" >> expected
sed -n 's/^ *SD Manager: *\(.*\)$/\1/p' output > actual
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server status (rc=$_rc)"
fi

step "Check KRA storage cert"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki-server cert-export \
    --cert-file kra_storage.crt \
    kra_storage
docker exec "$CONTAINER" openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/kra_storage.csr
docker exec "$CONTAINER" openssl x509 -text -noout -in kra_storage.crt
docker exec "$CONTAINER" pki-server cert-validate kra_storage
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check KRA storage cert (rc=$_rc)"
fi

step "Check KRA transport cert"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki-server cert-export \
    --cert-file kra_transport.crt \
    kra_transport
docker exec "$CONTAINER" openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/kra_transport.csr
docker exec "$CONTAINER" openssl x509 -text -noout -in kra_transport.crt
docker exec "$CONTAINER" pki-server cert-validate kra_transport
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check KRA transport cert (rc=$_rc)"
fi

step "Check subsystem cert"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki-server cert-export \
    --cert-file subsystem.crt \
    subsystem
docker exec "$CONTAINER" openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/subsystem.csr
docker exec "$CONTAINER" openssl x509 -text -noout -in subsystem.crt
docker exec "$CONTAINER" pki-server cert-validate subsystem
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check subsystem cert (rc=$_rc)"
fi

step "Check SSL server cert"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki-server cert-export \
    --cert-file sslserver.crt \
    sslserver
docker exec "$CONTAINER" openssl req -text -noout \
    -in /var/lib/pki/pki-tomcat/conf/certs/sslserver.csr
docker exec "$CONTAINER" openssl x509 -text -noout -in sslserver.crt
docker exec "$CONTAINER" pki-server cert-validate sslserver
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check SSL server cert (rc=$_rc)"
fi

step "Check CA admin cert after installing KRA"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" ls -la /root/.dogtag/pki-tomcat
docker exec "$CONTAINER" cat /root/.dogtag/pki-tomcat/ca_admin.cert
docker exec "$CONTAINER" openssl x509 -text -noout \
    -in /root/.dogtag/pki-tomcat/ca_admin.cert
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check CA admin cert after installing KRA (rc=$_rc)"
fi

step "Check security domain after installing KRA"
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
docker exec "$CONTAINER" pki-server kra-config-find | grep ^securitydomain. | sort | tee actual
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
docker exec "$CONTAINER" pki securitydomain-show | tee output
diff expected output
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check security domain after installing KRA (rc=$_rc)"
fi

step "Run PKI healthcheck"
set +e
(
set -euo pipefail
# Retry pki-healthcheck: intermittent NSS load timeout on audit_signing
hc_ok=0
for hc_try in 1 2 3; do
    echo "pki-healthcheck attempt ${hc_try}/3"
    if (
    set -euo pipefail
    docker exec "$CONTAINER" pki-healthcheck \
        --failures-only \
        --debug \
        > stdout 2> stderr
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
    fail "Run PKI healthcheck (rc=$_rc)"
fi

step "Check external commands"
set +e
(
set -euo pipefail
omit "Check external commands"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check external commands (rc=$_rc)"
fi

step "Check CA info"
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
docker exec "$CONTAINER" curl -ks https://pki.example.com:8443/ca/v2/info \
    | python -m json.tool \
    | tee actual
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check CA info (rc=$_rc)"
fi

step "Check KRA info"
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
docker exec "$CONTAINER" curl -ks https://pki.example.com:8443/kra/v2/info \
    | python -m json.tool \
    | tee actual
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check KRA info (rc=$_rc)"
fi

step "Check KRA admin"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki-server cert-export \
    --cert-file ca_signing.crt \
    ca_signing
docker exec "$CONTAINER" pki nss-cert-import \
    --cert ca_signing.crt \
    --trust CT,C,C \
    ca_signing
docker exec "$CONTAINER" pki pkcs12-import \
    --pkcs12 /root/.dogtag/pki-tomcat/ca_admin_cert.p12 \
    --pkcs12-password Secret.123
docker exec "$CONTAINER" pki nss-cert-verify \
    --cert-usage SSLClient \
    caadmin
docker exec "$CONTAINER" pki -n caadmin kra-user-show kraadmin
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check KRA admin (rc=$_rc)"
fi

step "Check KRA connector in CA"
set +e
(
set -euo pipefail
TRANSPORT_CERT=$(docker exec "$CONTAINER" openssl x509 \
    -in kra_transport.crt \
    -outform der \
    | base64 --wrap=0)
docker exec "$CONTAINER" pki-server ca-config-find | grep ^ca\.connector.KRA\. | tee output
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
docker exec "$CONTAINER" pki-server ca-connector-find | tee output
# KRA connector should be configured
cat > expected << EOF
  Connector ID: KRA
  Enabled: true
  URL: https://pki.example.com:8443
  Nickname: subsystem
EOF
diff expected output
# REST API should return KRA connector info
docker exec "$CONTAINER" pki -n caadmin ca-kraconnector-show | tee output
sed -n 's/\s*Host:\s\+\(\S\+\):.*/\1/p' output > actual
echo pki.example.com > expected
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check KRA connector in CA (rc=$_rc)"
fi

step "Import transport cert"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki nss-cert-import \
    --cert kra_transport.crt \
    kra_transport
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Import transport cert (rc=$_rc)"
fi

step "Check initial key requests"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check initial key requests (rc=$_rc)"
fi

step "Check initial keys"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check initial keys (rc=$_rc)"
fi

step "Generate AES key"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Generate AES key (rc=$_rc)"
fi

step "Check key requests after AES key generation"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check key requests after AES key generation (rc=$_rc)"
fi

step "Check keys after AES key generation"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check keys after AES key generation (rc=$_rc)"
fi

step "Generate RSA key"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Generate RSA key (rc=$_rc)"
fi

step "Check key requests after RSA key generation"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check key requests after RSA key generation (rc=$_rc)"
fi

step "Check keys after RSA key generation"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check keys after RSA key generation (rc=$_rc)"
fi

step "Enroll cert with key archival"
set +e
(
set -euo pipefail
# generate key and cert request
# https://github.com/dogtagpki/pki/wiki/Generating-Certificate-Request-with-PKI-NSS
docker exec "$CONTAINER" pki \
    nss-cert-request \
    --type crmf \
    --subject UID=testuser \
    --transport kra_transport \
    --csr testuser.csr
docker exec "$CONTAINER" cat testuser.csr
# issue cert
# https://github.com/dogtagpki/pki/wiki/Issuing-Certificates
docker exec "$CONTAINER" pki \
    -u caadmin \
    -w Secret.123 \
    ca-cert-issue \
    --request-type crmf \
    --profile caUserCert \
    --subject UID=testuser \
    --csr-file testuser.csr \
    --output-file testuser.crt
# import cert into NSS database
docker exec "$CONTAINER" pki nss-cert-import --cert testuser.crt testuser
# the cert should match the key (trust flags must be u,u,u)
echo "u,u,u" > expected
docker exec "$CONTAINER" pki nss-cert-show testuser | tee output
sed -n "s/^\s*Trust Flags:\s*\(\S*\)$/\1/p" output > actual
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Enroll cert with key archival (rc=$_rc)"
fi

step "Check key requests after enrollment"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check key requests after enrollment (rc=$_rc)"
fi

step "Check keys after enrollment"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check keys after enrollment (rc=$_rc)"
fi

step "Check archived cert key"
set +e
(
set -euo pipefail
# find archived key by owner
docker exec "$CONTAINER" pki \
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
docker exec "$CONTAINER" ldapsearch \
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
    fail "Check archived cert key (rc=$_rc)"
fi

step "Retrieve cert key"
set +e
(
set -euo pipefail
KEY_ID=$(cat cert.key_id)
echo "Key ID: $KEY_ID"
# export cert into Base64-encoded format
BASE64_CERT=$(docker exec "$CONTAINER" pki nss-cert-export --format DER testuser | base64 --wrap=0)
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
docker exec "$CONTAINER" pki \
    -n caadmin \
    kra-key-retrieve \
    --input $SHARED/request.json \
    --transport kra_transport \
    --output-data archived.p12
# import PKCS #12 file into NSS database with the passphrase
docker exec "$CONTAINER" pki \
    -d nssdb \
    pkcs12-import \
    --pkcs12 archived.p12 \
    --password Secret.123
# remove archived cert from NSS database
docker exec "$CONTAINER" pki -d nssdb nss-cert-del UID=testuser
# import original cert into NSS database
docker exec "$CONTAINER" pki -d nssdb nss-cert-import --cert testuser.crt testuser
# the original cert should match the archived key (trust flags must be u,u,u)
echo "u,u,u" > expected
docker exec "$CONTAINER" pki -d nssdb nss-cert-show testuser | tee output
sed -n "s/^\s*Trust Flags:\s*\(\S*\)$/\1/p" output > actual
diff expected actual
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Retrieve cert key (rc=$_rc)"
fi

step "Check key requests after retrieval"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check key requests after retrieval (rc=$_rc)"
fi

step "Check keys after retrieval"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check keys after retrieval (rc=$_rc)"
fi

step "Deactivate cert key"
set +e
(
set -euo pipefail
KEY_ID=$(cat cert.key_id)
echo "KEY_ID: $KEY_ID"
docker exec "$CONTAINER" pki \
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
    fail "Deactivate cert key (rc=$_rc)"
fi

step "Check key requests after deactivation"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check key requests after deactivation (rc=$_rc)"
fi

step "Check keys after deactivation"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check keys after deactivation (rc=$_rc)"
fi

step "Archive secret"
set +e
(
set -euo pipefail
# generate random secret
head -c 1K < /dev/urandom > secret.archived
docker exec "$CONTAINER" pki \
    -n caadmin \
    kra-key-archive \
    --clientKeyID test-secret \
    --transport kra_transport \
    --input-data $SHARED/secret.archived \
    -v
# get key ID
docker exec "$CONTAINER" pki \
    -n caadmin \
    kra-key-find \
    --clientKeyID test-secret | tee output
sed -n 's/^ *Key ID: *\(.*\)$/\1/p' output > cert.key_id
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Archive secret (rc=$_rc)"
fi

step "Check key requests after secret archival"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check key requests after secret archival (rc=$_rc)"
fi

step "Check keys after secret archival"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check keys after secret archival (rc=$_rc)"
fi

step "Retrieve secret"
set +e
(
set -euo pipefail
KEY_ID=$(cat cert.key_id)
echo "KEY_ID: $KEY_ID"
docker exec "$CONTAINER" pki \
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
    fail "Retrieve secret (rc=$_rc)"
fi

step "Check key requests after secret retrieval"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check key requests after secret retrieval (rc=$_rc)"
fi

step "Check keys after secret retrieval"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pki \
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
    fail "Check keys after secret retrieval (rc=$_rc)"
fi

step "Remove KRA"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" pkidestroy \
    -s KRA \
    --debug \
    > stdout 2> stderr
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Remove KRA (rc=$_rc)"
fi

step "Check for warnings"
set +e
(
set -euo pipefail
omit "Check for warnings"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check for warnings (rc=$_rc)"
fi

step "Check external commands"
set +e
(
set -euo pipefail
omit "Check external commands"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check external commands (rc=$_rc)"
fi

step "Remove CA"
set +e
(
set -euo pipefail
ipacta_uninstall
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Remove CA (rc=$_rc)"
fi

step "Check PKI server base dir after removal"
set +e
(
set -euo pipefail
omit "Check PKI server base dir after removal"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server base dir after removal (rc=$_rc)"
fi

step "Check PKI server conf dir after removal"
set +e
(
set -euo pipefail
omit "Check PKI server conf dir after removal"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server conf dir after removal (rc=$_rc)"
fi

step "Check PKI server logs dir after removal"
set +e
(
set -euo pipefail
omit "Check PKI server logs dir after removal"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server logs dir after removal (rc=$_rc)"
fi

step "Check PKI server logs dir after removal"
set +e
(
set -euo pipefail
omit "Check PKI server logs dir after removal"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server logs dir after removal (rc=$_rc)"
fi

step "Check PKI server systemd journal"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" journalctl -x --no-pager -u pki-tomcatd@pki-tomcat.service
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server systemd journal (rc=$_rc)"
fi

step "Check PKI server access log"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" find /var/log/pki/pki-tomcat -name "localhost_access_log.*" -exec cat {} \;
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check PKI server access log (rc=$_rc)"
fi

step "Check CA debug log"
set +e
(
set -euo pipefail
omit "Check CA debug log"
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check CA debug log (rc=$_rc)"
fi

step "Check KRA debug log"
set +e
(
set -euo pipefail
docker exec "$CONTAINER" find /var/lib/pki/pki-tomcat/logs/kra -name "debug.*" -exec cat {} \;
)
_rc=$?
set -euo pipefail
if [[ $_rc -ne 0 ]]; then
    fail "Check KRA debug log (rc=$_rc)"
fi

echo
if [[ ${#FAILS[@]} -eq 0 ]]; then
    echo "==== IPACTA kra-basic-test PASSED ===="
    exit 0
fi
echo "==== IPACTA kra-basic-test FAILED (${#FAILS[@]} check(s)) ====" >&2
for item in "${FAILS[@]}"; do echo " - $item" >&2; done
exit 1

