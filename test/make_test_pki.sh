#!/bin/sh
# Build a throwaway PKI shaped like the Robot Raconteur node PKI, for rrs+tcp
# tests. Nothing here is trusted outside the tests: the client has to be given
# root.pem explicitly.
#
#   root.pem      self-signed, critical 1.3.6.1.4.1.45455.1.1.3.1 (root)
#   intermediate  signed by root, critical ...3.2 (intermediate)
#   node certs    signed by intermediate, critical ...3.3 (node),
#                 subject "/CN=Robot Raconteur Node {nodeid}"
#
# Usage: make_test_pki.sh OUTDIR GOOD_ID WRONGCN_ID NOOID_ID EXTRAEXT_ID
#
# Writes a server config dir per node id, OUTDIR/<name>/certificates/<id>.p12,
# for ROBOTRACONTEUR_USER_CONFIG_DIR:
#   good      correct certificate for GOOD_ID
#   wrongcn   served by WRONGCN_ID, but the certificate names GOOD_ID
#   nooid     certificate for NOOID_ID without the node OID extension
#   extraext  certificate for EXTRAEXT_ID with an extra unknown critical extension
set -e
out=$1; good=$2; wrongcn=$3; nooid=$4; extraext=$5
mkdir -p "$out"; cd "$out"
oid=1.3.6.1.4.1.45455.1.1.3
key() { openssl ecparam -name prime256v1 -genkey -noout -out "$1" 2>/dev/null; }

key root.key
openssl req -x509 -new -key root.key -days 2 -sha256 -out root.pem \
  -subj "/C=US/O=Racket RR Test/CN=Test Robot Raconteur Node Root CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "$oid.1=critical,ASN1:BOOLEAN:TRUE"

key inter.key
openssl req -new -key inter.key -out inter.csr \
  -subj "/C=US/O=Racket RR Test/CN=Test Robot Raconteur Node Intermediate CA"
printf '%s\n' "basicConstraints=critical,CA:TRUE,pathlen:0" \
  "keyUsage=critical,keyCertSign,cRLSign" "$oid.2=critical,ASN1:BOOLEAN:TRUE" > inter.ext
openssl x509 -req -in inter.csr -CA root.pem -CAkey root.key -CAcreateserial \
  -days 2 -sha256 -extfile inter.ext -out inter.pem 2>/dev/null

# node NAME SERVER_ID CERT_ID EXTRA_EXT_LINES...
node() {
  name=$1; server_id=$2; cert_id=$3; shift 3
  key $name.key
  openssl req -new -key $name.key -out $name.csr -subj "/CN=Robot Raconteur Node $cert_id"
  printf '%s\n' "basicConstraints=critical,CA:FALSE" \
    "keyUsage=critical,digitalSignature,keyEncipherment" "$@" > $name.ext
  openssl x509 -req -in $name.csr -CA inter.pem -CAkey inter.key -CAcreateserial \
    -days 2 -sha256 -extfile $name.ext -out $name.pem 2>/dev/null
  mkdir -p $name/certificates
  openssl pkcs12 -export -passout pass: -inkey $name.key -in $name.pem -certfile inter.pem \
    -out "$name/certificates/$server_id.p12"
}

node good     "$good"     "$good"     "$oid.3=critical,ASN1:BOOLEAN:TRUE"
node wrongcn  "$wrongcn"  "$good"     "$oid.3=critical,ASN1:BOOLEAN:TRUE"
node nooid    "$nooid"    "$nooid"
node extraext "$extraext" "$extraext" "$oid.3=critical,ASN1:BOOLEAN:TRUE" \
                                      "1.3.6.1.4.1.99999.1=critical,ASN1:BOOLEAN:TRUE"
