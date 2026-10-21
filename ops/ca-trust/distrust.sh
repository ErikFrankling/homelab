#!/bin/sh
# Distrust roots on the Debian/Ubuntu hosts (proxmox, naiaclaw) ahead of the
# distro's ca-certificates package. A leading "!" in /etc/ca-certificates.conf
# deselects a root and survives package upgrades. Idempotent; run as root:
#   ssh proxmox 'sh -s' < ops/ca-trust/distrust.sh
#   ssh naiaclaw 'sudo sh -s' < ops/ca-trust/distrust.sh
#
# 2026-10-21 emSign ECC Root CA - G3: eight intermediates under it had
# near-zero-entropy keys (Mozilla bug 2083449); NSS 3.131.1 removed the root.
# Drop the line once the distro package no longer ships it.
set -eu
for crt in mozilla/emSign_ECC_Root_CA_-_G3.crt; do
  sed -i "s|^$crt\$|!$crt|" /etc/ca-certificates.conf
  grep -qx "!$crt" /etc/ca-certificates.conf || echo "!$crt" >> /etc/ca-certificates.conf
done
update-ca-certificates --fresh > /dev/null
