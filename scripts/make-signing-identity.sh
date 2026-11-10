#!/bin/bash
#
# Creates the self-signed code-signing certificate "Wisp Release" in your login keychain, once.
#
# Why: without an Apple Developer account the app can only be signed ad hoc, and an ad-hoc signature
# changes with every build, so macOS forgets the microphone / screen recording / accessibility grants
# after each update. A stable self-signed certificate keeps the app's "designated requirement" the same
# across builds, so grants survive. It does NOT make Gatekeeper trust the app (the curl installer doesn't
# need that, since curl downloads aren't quarantined).
#
# This changes your keychain: it imports a private key and marks the certificate as trusted for code
# signing for your user. Run it only on the Mac you build releases on. Back up the key afterwards
# (Keychain Access -> export), because a new key means one more permission reset for everyone.

set -euo pipefail

NAME="Wisp Release"

if security find-identity -v -p codesigning | grep -q "\"${NAME}\""; then
    echo "\"${NAME}\" already exists in your keychain. Nothing to do."
    exit 0
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
password="$(uuidgen)"

cat > "${work_dir}/openssl.cnf" <<CONFIG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${NAME}
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG

# /usr/bin/openssl is LibreSSL on macOS; its pkcs12 output imports cleanly into the keychain.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "${work_dir}/key.pem" -out "${work_dir}/cert.pem" -config "${work_dir}/openssl.cnf"
/usr/bin/openssl pkcs12 -export -inkey "${work_dir}/key.pem" -in "${work_dir}/cert.pem" \
    -out "${work_dir}/identity.p12" -passout "pass:${password}"

security import "${work_dir}/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$password" -T /usr/bin/codesign
# Trust it for code signing (macOS asks for your login password).
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "${work_dir}/cert.pem"

echo
security find-identity -v -p codesigning | grep "${NAME}" || echo "Created, but it isn't listed as valid yet; open Keychain Access and check that it is trusted for Code Signing."
