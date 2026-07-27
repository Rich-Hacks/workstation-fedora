#!/usr/bin/env bash
#
# borg-etc-backup.sh — root-owned capture of system configuration.
#
# Exists because Vorta runs as feduser and cannot read root-only files:
# sshd_config, crypttab, sudoers, shadow, /etc/.git and the Samba credentials
# are all invisible to it. This job covers that gap.
#
set -euo pipefail

export BORG_REPO="ssh://borg@192.0.2.32/srv/backups/fedhome-etc"
export BORG_RSH="ssh -i /root/.ssh/id_ed25519_borg_etc -o BatchMode=yes"
export BORG_PASSCOMMAND="cat /etc/borg/passphrase"

# Build the source list from paths that actually exist, so a missing one
# cannot abort the run under set -e.
SOURCES=()
for p in /etc /root /usr/local/bin /usr/local/sbin /var/spool/cron; do
    [[ -e "${p}" ]] && SOURCES+=("${p}")
done

borg create \
    --stats --show-rc \
    --one-file-system \
    --compression zstd,3 \
    --exclude '/usr/local/lib/ollama' \
    --exclude '/root/.cache' \
    "::etc-{now:%Y-%m-%d-%H%M%S}" \
    "${SOURCES[@]}"

borg prune --list --glob-archives 'etc-*' \
    --keep-daily=7 --keep-weekly=4 --keep-monthly=6
