#!/bin/zsh
# Creates a self-signed code-signing identity, "Stringer Local Signing", in
# its own keychain. Signing with a certificate makes macOS key the permission
# grants (microphone, system audio) to the certificate rather than to the
# binary's hash, so they survive rebuilds. Ad-hoc signing re-prompts — twice —
# after every build.
#
#   ./setup-signing.sh                        create it (build.sh signs with --keychain,
#                                             so your keychain search list is left alone)
#   ./setup-signing.sh --add-to-search-list   also list it, for signing by hand
#   ./setup-signing.sh --export-p12 FILE      export it (for CI: a GitHub secret)
#   ./setup-signing.sh --import-p12 FILE      use an exported identity instead of a new one
# The exported file's password comes from STRINGER_P12_PASSWORD.
#
# Use one identity everywhere (your builds and CI's releases), so permission
# grants survive upgrades from one to the other.
#
# `security find-identity -v` will report "0 valid identities": a self-signed
# root is untrusted, which is expected and does not stop codesign.
set -euo pipefail

NAME="Stringer Local Signing"
KEYCHAIN=${STRINGER_KEYCHAIN:-$HOME/Library/Keychains/stringer-signing.keychain-db}
PASS=${STRINGER_KEYCHAIN_PASSWORD:-stringer-local}
SEARCH_LIST=0 EXPORT= IMPORT=
while (( $# )); do
  case $1 in
    --add-to-search-list) SEARCH_LIST=1 ;;
    --export-p12) EXPORT=$2; shift ;;
    --import-p12) IMPORT=$2; shift ;;
    *) echo "usage: $0 [--add-to-search-list] [--export-p12 FILE | --import-p12 FILE]"; exit 2 ;;
  esac
  shift
done
if [[ -n $EXPORT$IMPORT && -z ${STRINGER_P12_PASSWORD:-} ]]; then
  echo "set STRINGER_P12_PASSWORD"; exit 2
fi

# LibreSSL ships with macOS and writes PKCS#12 that `security import` reads.
# OpenSSL 3+ defaults to AES/PBKDF2, which it cannot ("MAC verification
# failed"), so if that is all there is, force legacy SHA1/3DES.
OPENSSL=/usr/bin/openssl
LEGACY=()
if ! $OPENSSL version | grep -q LibreSSL; then
  LEGACY=(-legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1)
fi

if [[ -f $KEYCHAIN ]] && security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "signing identity already exists in $KEYCHAIN"
else
  TMP=$(mktemp -d)
  trap 'rm -rf $TMP' EXIT
  cat >$TMP/cert.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  P12PASS=$PASS
  if [[ -n $IMPORT ]]; then
    cp "$IMPORT" $TMP/id.p12
    P12PASS=$STRINGER_P12_PASSWORD
  else
    $OPENSSL req -x509 -newkey rsa:2048 -nodes -days 3650 -config $TMP/cert.cnf \
      -keyout $TMP/key.pem -out $TMP/cert.pem 2>/dev/null
    $OPENSSL pkcs12 -export -inkey $TMP/key.pem -in $TMP/cert.pem -name "$NAME" \
      -out $TMP/id.p12 -passout pass:$PASS ${LEGACY[@]}
    if [[ -n $EXPORT ]]; then
      # Written now, from the generated key: exporting it from the keychain
      # later makes macOS ask for the keychain password.
      $OPENSSL pkcs12 -export -inkey $TMP/key.pem -in $TMP/cert.pem -name "$NAME" \
        -out "$EXPORT" -passout pass:$STRINGER_P12_PASSWORD ${LEGACY[@]}
      echo "exported to $EXPORT (keep it secret; it can sign as Stringer)"
      EXPORTED=1
    fi
  fi

  # create-keychain also adds the keychain to the search list; restore the
  # list afterwards unless we were asked to add it.
  before=(${(f)"$(security list-keychains -d user | tr -d '" ')"})
  [[ -f $KEYCHAIN ]] || security create-keychain -p "$PASS" "$KEYCHAIN"
  (( SEARCH_LIST )) || security list-keychains -d user -s $before
  security set-keychain-settings "$KEYCHAIN"   # no auto-lock
  security unlock-keychain -p "$PASS" "$KEYCHAIN"
  security import $TMP/id.p12 -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
  # Let codesign use the key without a dialog.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null
  echo "created \"$NAME\" in $KEYCHAIN"
fi

if (( SEARCH_LIST )); then
  current=(${(f)"$(security list-keychains -d user | tr -d '" ')"})
  if (( ! ${current[(Ie)$KEYCHAIN]} )); then
    security list-keychains -d user -s $current "$KEYCHAIN"
    echo "added $KEYCHAIN to the keychain search list"
  fi
fi
security find-identity -p codesigning "$KEYCHAIN" | grep -q "$NAME" && echo "ok: codesign can use \"$NAME\""

if [[ -n $EXPORT && -z ${EXPORTED:-} ]]; then
  echo "exporting from the keychain: macOS will ask for its password ($PASS)"
  security unlock-keychain -p "$PASS" "$KEYCHAIN"
  security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$STRINGER_P12_PASSWORD" -o "$EXPORT"
  echo "exported to $EXPORT (keep it secret; it can sign as Stringer)"
fi
