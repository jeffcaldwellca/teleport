#!/bin/bash
# Starts the local docker servers the gated integration suites expect
# (TeleportTests/TransferIntegrationTests.swift, CLIIntegrationTests.swift),
# replacing any previous ones. All accounts are testuser / testpass.
#
#   FTP              127.0.0.1:2121   writable dir /ftp/testuser
#   SFTP             127.0.0.1:2222   writable dir /upload
#   FTPS (explicit)  127.0.0.1:2122   self-signed cert, TLS session reuse required
#   FTPS (implicit)  127.0.0.1:990    same cert
#
# Then: TEST_RUNNER_TELEPORT_IT=1 xcodebuild test -project Teleport.xcodeproj -scheme Teleport ...
set -euo pipefail

CERTS="$(mktemp -d)/teleport-it-certs"
mkdir -p "$CERTS"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout "$CERTS/key.pem" -out "$CERTS/cert.pem" \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null

docker rm -f teleport-it-ftp teleport-it-sftp teleport-it-ftps teleport-it-ftps-implicit >/dev/null 2>&1 || true

docker run -d --name teleport-it-ftp -p 2121:21 -p 30000-30009:30000-30009 \
  -e USERS="testuser|testpass" -e ADDRESS=127.0.0.1 \
  -e MIN_PORT=30000 -e MAX_PORT=30009 delfer/alpine-ftp-server >/dev/null

docker run -d --name teleport-it-sftp -p 2222:22 \
  atmoz/sftp testuser:testpass:::upload >/dev/null

docker run -d --name teleport-it-ftps -p 2122:21 -p 30010-30019:30010-30019 \
  -v "$CERTS:/certs:ro" \
  -e USERS="testuser|testpass" -e ADDRESS=127.0.0.1 \
  -e MIN_PORT=30010 -e MAX_PORT=30019 \
  -e TLS_CERT=/certs/cert.pem -e TLS_KEY=/certs/key.pem delfer/alpine-ftp-server >/dev/null

# Implicit TLS has no switch in the image, so run vsftpd directly. The config
# file comes first: later options override it (background, listen port).
docker run -d --name teleport-it-ftps-implicit -p 990:990 -p 30020-30029:30020-30029 \
  -v "$CERTS:/certs:ro" -e USERS="testuser|testpass" \
  delfer/alpine-ftp-server vsftpd /etc/vsftpd/vsftpd.conf \
  -opasv_min_port=30020 -opasv_max_port=30029 -opasv_address=127.0.0.1 \
  -orsa_cert_file=/certs/cert.pem -orsa_private_key_file=/certs/key.pem \
  -ossl_enable=YES -oallow_anon_ssl=NO -oforce_local_data_ssl=YES -oforce_local_logins_ssl=YES \
  -ossl_ciphers=HIGH -oimplicit_ssl=YES -olisten_port=990 -obackground=NO >/dev/null

echo "Test servers started: teleport-it-ftp, teleport-it-sftp, teleport-it-ftps, teleport-it-ftps-implicit"
