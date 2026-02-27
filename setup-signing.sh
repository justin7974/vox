#!/bin/bash
#
# One-time setup: create a local code signing certificate for VoiceInput.
# This ensures TCC permissions (microphone, accessibility) persist across rebuilds.
#
# Usage: ./setup-signing.sh
#
set -e

CERT_NAME="VoiceInput Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMPDIR_CERT=$(mktemp -d)

echo "Creating local code signing certificate: \"$CERT_NAME\"..."
echo ""

# Check if certificate already exists
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Certificate \"$CERT_NAME\" already exists. No action needed."
    echo ""
    echo "To verify: security find-identity -v -p codesigning"
    rm -rf "$TMPDIR_CERT"
    exit 0
fi

# Generate self-signed code signing certificate
cat > "$TMPDIR_CERT/cert.conf" <<EOF
[req]
distinguished_name = req_dn
prompt = no
[req_dn]
CN = $CERT_NAME
[v3_codesign]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = CA:false
EOF

openssl req -x509 -newkey rsa:2048 \
    -keyout "$TMPDIR_CERT/key.pem" \
    -out "$TMPDIR_CERT/cert.pem" \
    -days 3650 -nodes \
    -config "$TMPDIR_CERT/cert.conf" \
    -extensions v3_codesign \
    2>/dev/null

# Package as PKCS12 (with password - macOS requires non-empty password for import)
openssl pkcs12 -export \
    -out "$TMPDIR_CERT/cert.p12" \
    -inkey "$TMPDIR_CERT/key.pem" \
    -in "$TMPDIR_CERT/cert.pem" \
    -passout pass:VoiceInputDev \
    -legacy \
    2>/dev/null

# Import to login keychain
security import "$TMPDIR_CERT/cert.p12" \
    -k "$KEYCHAIN" \
    -T /usr/bin/codesign \
    -P "VoiceInputDev"

# Trust the certificate for code signing
security add-trusted-cert -d -r trustRoot -p codeSign \
    -k "$KEYCHAIN" \
    "$TMPDIR_CERT/cert.pem" \
    2>/dev/null || true

# Cleanup temp files
rm -rf "$TMPDIR_CERT"

echo ""
echo "Verifying..."
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ Certificate \"$CERT_NAME\" created successfully!"
    echo ""
    echo "Now run ./build.sh to build and sign the app."
    echo "TCC permissions will persist across rebuilds."
    echo ""
    echo "Note: The first time you build, macOS may ask you to allow"
    echo "      Keychain access for codesign. Click \"Always Allow\"."
else
    echo "❌ Certificate creation may have failed."
    echo ""
    echo "Alternative: Open Keychain Access → Certificate Assistant → Create a Certificate"
    echo "  Name: $CERT_NAME"
    echo "  Type: Code Signing"
    echo "Then run ./build.sh again."
fi
