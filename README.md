# Workstation Rebuild — `fedhome` (Fedora 44 KDE)

**Classification:** PUBLIC — addressing replaced with RFC 5737 documentation ranges; identifiers, key material and personal details redacted.
**System:** `fedhome` — Fedora 44 KDE workstation, 192.0.2.150
**Rebuild window:** 26–27 July 2026
**Author:** <author>, RC COMMS
**Document version:** 1.0

---

## 1. Scope and purpose

Full rebuild of the Fedora workstation following a reinstall, and the redesign of its backup architecture after a silent data-integrity failure was found in the original design.

This document covers the workstation and its interfaces to the `ulster` cluster. It does not cover cluster-side configuration beyond the container changes made to support the new backup path.

**Headline outcome:** the workstation's backup architecture was rebuilt from SMB-hosted Borg to `borg serve` over SSH after `borg check` found segment corruption in the original repository. System configuration is now captured by a root-owned job that the previous design structurally could not read.

---

## 2. Hardware and base platform

| Component | Detail |
|---|---|
| CPU | AMD Ryzen 9 3900X (Matisse) |
| Motherboard | ASUSTeK, AMD X570 chipset |
| GPU | XFX Speedster MERC 310 RX 7900 XTX, Navi 31 `gfx1100`, 24 GB, PCI `0c:00.0` |
| RAM | 32 GB |
| Storage | Samsung SSD 980 PRO 2 TB NVMe, PCI `03:00.0` |
| Wireless | Intel Wi-Fi 6 AX200 `[8086:2723]`, driver `iwlwifi`/`iwlmvm`, PCI `04:00.0` |
| Ethernet (unused) | Realtek RTL8125 2.5 GbE `05:00.0`; Intel I211 GbE `06:00.0` |
| Bluetooth | Intel AX200 `[8087:0029]`, firmware `intel/ibt-0040-0041.sfi` |
| Security key | YubiKey 5 `[1050:0407]` — LUKS unlock |

Operating system: Fedora 44 KDE Plasma 6.6.4, kernel 7.1.4-204.fc44. The installation media kernel (6.19.10-300) remains installed and will age out under `installonly_limit`.

---

## 3. Disk encryption

LUKS2 root with FIDO2 enrolment via `systemd-cryptenroll`, YubiKey **with PIN** — deliberate two-factor: possession plus knowledge.

**TPM2 auto-unlock was evaluated and rejected.** `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7` would add a second independent keyslot, so boot would try TPM first and fall back to the YubiKey when PCRs change. It was declined because TPM auto-unlock means a stolen machine boots straight to the display manager — disk encryption then only protects against drive removal, and the login password becomes the entire perimeter.

**Chained TPM-and-FIDO2 as a single requirement is not supported.** LUKS keyslots are independent OR-factors; there is no AND composition. The nearest equivalents are `--tpm2-with-pin=yes` or the current FIDO2-with-PIN configuration.

The passphrase keyslot is retained as recovery. Do not remove it — TPM and FIDO2 slots can both be invalidated by firmware changes.

---

## 4. Filesystem and snapshots

btrfs on LUKS. Snapper configured through Btrfs Assistant:

```
Config │ Subvolume
───────┼──────────
Daily  │ /
```

`/home` is **not** snapshotted. This is intentional and load-bearing: `/home` is Borg's domain, and timeline snapshots of a 91 GB Steam library would consume the NVMe. Do not add a `/home` snapper config without revisiting the Borg exclusion set.

Timers `snapper-boot`, `snapper-cleanup` and `snapper-timeline` are enabled against a `disabled` preset — set by Btrfs Assistant, expected.

---

## 5. Networking

- Primary link: AX200 wireless. Both wired NICs are cabled-capable but unused.
- Management LAN: 192.0.2.0/24, gateway 192.0.2.1, DNS 192.0.2.10 (Pi-hole).
- Tailscale: `fedhome` at <tailscale-ip>, tailnet `<tailnet-owner>`.
- `--accept-routes` is **false**, and correct. `slievemore` advertises subnet routes for 192.0.2.0/24; accepting them on a host already resident on that subnet creates routing ambiguity.

### 5.1 Firmware dependency — recorded because it nearly caused an outage

During the desktop lean-down, wireless firmware packages for non-present hardware were removed. `iwlwifi-mvm-firmware` went with them. **Wireless continued working**, because `iwlwifi` firmware is loaded at driver probe and stays resident until reboot or module reload.

The failure would have surfaced at the next reboot, on a machine with no wired fallback configured. Reinstated before rebooting.

**Learning:** firmware package removal is a delayed-action change. Verify the running NIC's driver and firmware package before removing anything from `linux-firmware`'s subpackages, and prefer removing them immediately before a planned reboot rather than mid-session.

---

## 6. Desktop lean-down

The KDE live ISO leaves substantial scaffolding behind. Removed in grouped transactions, each inspected with `--assumeno` first.

| Group | Content | Rationale |
|---|---|---|
| Live residue | `livesys-scripts`, `anaconda-live`, `anaconda-install-env-deps`, `dracut-live`, `isomd5sum`, `mediawriter` | `livesys.service` and `livesys-late.service` were **enabled** on an installed system |
| Guest agents | `qemu-guest-agent`, `open-vm-tools-desktop`, `virtualbox-guest-additions`, `spice-vdagent`, `spice-webdavd`, `hyperv-daemons` | Bare metal; four enabled daemons and three autostart entries |
| Intel daemons | `thermald`, `intel-lpmd`, `switcheroo-control`, `mcelog` | Intel-specific, no-ops on Ryzen |
| Unused storage | `iscsi-initiator-utils`, `mdadm`, `hfsplus-tools`, `mactel-boot` | Single NVMe, btrfs, no iSCSI, no md RAID |
| Enterprise identity | `sssd-*`, `realmd` | Not domain-joined |
| Serial-port hazards | `brltty`, `ModemManager` | Both claim USB serial devices on hotplug — a known cause of USB-serial and LTE modem failures |
| Remote desktop | Retained (`krdc`, `krdp`, `krfb`) | Reviewed, kept |
| Firmware | Wireless/GPU firmware for absent vendors | See §5.1 — `iwlwifi-mvm-firmware` reinstated |

Masked rather than removed (dependency reasons or reversibility):

```
lvm2-monitor.service   dm-event.socket   lvm2-lvmpolld.socket
systemd-homed.service  plasma-setup.service   cups-browsed.service
```

`cups-browsed` is masked specifically as attack-surface reduction — it is the component behind the 2024 CUPS remote code execution chain and automatic remote printer discovery is not needed here.

Baloo disabled via `balooctl6 disable`. `localsearch-3.desktop` remains in `/etc/xdg/autostart` — outstanding.

### 6.1 Dependency cascade — udisks2

Removing the guest-agent and live groups autoremoved `udisks2` and `udisks2-btrfs` as orphaned dependencies. Symptom: **external USB drives stopped mounting in Dolphin**, since udisks2 is the mount broker for removable media. `kde-partitionmanager` went the same way.

Resolved by reinstalling. `mdadm` returned as a `kde-partitionmanager` dependency, re-enabling `mdmonitor.service` and `raid-check.timer`.

**Learning:** inspect every `dnf remove` transaction with `--assumeno` before committing, and keep `dnf history info <id>` to hand. `dnf history undo <id>` reverses a group that went too far; etckeeper provides the matching `/etc` diff.

---

## 7. Filesystem mounts

CIFS mounts to `oriel` (CT101, 192.0.2.32). Credentials in `/etc/samba/.creds` and `/etc/samba/.creds-<user2>`, both `0600 root:root`. The second mount uses separate credentials from the `<smb-user>`-authenticated shares.

Recommended fstab options pattern:

```
//192.0.2.32/<share> /mnt/<name> cifs credentials=/etc/samba/.creds-<user>,uid=1000,gid=1000,file_mode=0640,dir_mode=0750,vers=3.1.1,_netdev,x-systemd.automount,x-systemd.idle-timeout=300 0 0
```

`_netdev` plus `x-systemd.automount` prevents boot hangs when `oriel` is unavailable and defers the mount until first access.

---

## 8. Backup architecture

### 8.1 Original design and its failure

Initial build: Vorta/Borg writing to `//192.0.2.32/Downloads/downloads/backups`, mounted at `/mnt/backups`. Repository initialised 26 July 21:52, `repokey-blake2`. Two archives created before the problem was found.

Vorta's scheduled repository check ran at 03:45 on 27 July and failed. Manual `borg check` confirmed:

```
Data integrity error: Segment entry checksum mismatch [segment 19, offset 37258665]
Index object count mismatch.
committed index: 71169 objects
rebuilt index:   70915 objects
```

254 objects referenced by the manifest were absent from segment 19.

**Root cause attribution.** The original repository at `/tank/Downloads/downloads/backups` was retained. Comparing the suspect segment across both locations:

```
<sha256-digest>  /tank/Downloads/downloads/backups/data/0/19
<sha256-digest>  /tank/storage/backups/fedhome/data/0/19
```

Identical. **The corruption predated the migration — the SMB write path produced it; `rsync` copied a file that was already wrong.** Corroborating evidence: segment files carry mode `0744` owned by uid `101000`, which is the CIFS mount's `file_mode` and the `<smb-user>` uid mapping, not anything Borg would choose.

Borg's documentation advises against network filesystems for repositories because it relies on POSIX locking and atomic renames, and CIFS provides neither reliably.

**Critical learning:** `borg info` returned a healthy manifest twice against this corrupt repository. `info` reads the manifest only; **only `borg check` reads segment data.** Any monitoring that treats `borg info` as a health signal is monitoring nothing. A scheduled `borg check` is mandatory, not optional.

Decision: the repository was destroyed rather than repaired. `borg check --repair` resolves missing objects by removing references, producing archives that validate but contain holes — worse than no backup, because it invites false confidence. The archives were 24 hours old with every source byte live.

### 8.2 Target architecture

```
fedhome (<user>) ──ssh──┐
                         ├──> oriel CT101 :22 ──> borg serve (forced command)
fedhome (root, /etc) ────┘                              │
                                                        └─> bind mount mp5
                                                              → pve:/tank/storage/backups
                                                                 └─> sanoid → syncoid (pve2) → restic (Hetzner)
```

Properties gained over the SMB design: correct locking, no CIFS semantics in the write path, per-key repository restriction, and a viable route to append-only hardening.

### 8.3 Cluster-side configuration

Dataset on `pve`:

```
tank/storage/backups   compression=off   atime=off   recordsize=1M
```

`compression=off` because Borg already compresses; ZFS compression on encrypted pre-compressed segments burns CPU for no gain. `recordsize=1M` matches Borg's segment sizing. Placement under `tank/storage` puts it inside the existing restic off-site scope automatically.

Container CT101 (`oriel`) changes:

```
mp5: /tank/storage/backups,mp=/srv/backups
memory: 2048          # raised from 512 — borg serve holds the repository index in RAM
```

Service account: `borg`, container UID 1002, host UID **101002** (unprivileged container 100000 offset).

Host-side ownership:

```
chown -R 101002:101002 /tank/storage/backups
chmod 700 /tank/storage/backups
```

**Confirmed property:** Proxmox uses a plain `bind` mount, not `rbind`, for directory mount points. Child datasets therefore do **not** propagate into the container through `mp3` (`/tank/storage` → `/mnt/storage`). `/mnt/storage/backups` and `/mnt/storage/bencrom` appear as empty stubs. Since `/mnt/storage` is Samba-exported (`valid users = @<smb-group> <smb-user>`), this non-propagation is what keeps both the backup repository and Vaultwarden's dataset off the share. Record this before anyone "fixes" the mount to use `rbind`.

### 8.4 Borg version

Debian 12.15 ships borg 1.2.4; the client is 1.4.4. They interoperate, but the upstream static binary was installed on `oriel` to align versions and decouple from bookworm's freeze:

```
/usr/local/bin/borg   1.4.5   (borg-linux-glibc235-x86_64-gh)
sha256 <sha256-digest>
```

`glibc235` is correct for bookworm's glibc 2.36. Debian's package remains installed; the absolute path in the forced command selects which binary serves. Fetched on `pve` and transferred with `pct push` — `oriel` has no HTTP client and does not need one.

### 8.5 SSH access control

`/home/borg/.ssh/authorized_keys` on `oriel`, `0600 borg:borg`, one line per client:

```
command="/usr/local/bin/borg serve --restrict-to-repository /srv/backups/fedhome",restrict ssh-ed25519 <public-key> fedhome-borg-user
command="/usr/local/bin/borg serve --restrict-to-repository /srv/backups/fedhome-etc",restrict ssh-ed25519 <root key> fedhome-borg-etc
```

`--restrict-to-repository` is tighter than `--restrict-to-path`: the key may operate on that one repository and cannot create others. `restrict` disables pty, agent forwarding, port forwarding, X11 and user-rc.

Both keys are passphraseless. This is deliberate — both drive unattended timers, and the forced command is the compensating control: a stolen key can only speak the Borg protocol to one named repository.

Host key fingerprint for `oriel`: `SHA256:<fingerprint>`. Pre-seeded into `/root/.ssh/known_hosts` because `BatchMode=yes` refuses to prompt and would fail the timer silently.

### 8.6 Repository inventory

| Repository | Client | Sources | Retention | Schedule |
|---|---|---|---|---|
| `ssh://borg@192.0.2.32/srv/backups/fedhome` | Vorta as `<user>` | `/home/<user>` | Vorta profile | 10:45 daily |
| `ssh://borg@192.0.2.32/srv/backups/fedhome-etc` | root systemd timer | `/etc`, `/root`, `/usr/local/bin`, `/usr/local/sbin`, `/var/spool/cron` | 7d / 4w / 6m | 10:30 daily |

Both `repokey-blake2`. Keys exported and held in Vaultwarden with their passphrases, as separate entries. The `fedhome-etc` passphrase was generated with `openssl rand -hex 32` so it never entered shell history.

### 8.7 Why a separate root job

Vorta runs as `<user>` and structurally cannot read root-owned configuration. The original `/etc` capture was hollow — every file that matters for a rebuild failed with `Errno 13`:

`shadow`, `gshadow`, `sudoers`, `sudoers.d/`, `crypttab`, `sshd_config`, `sshd_config.d/`, `samba/.creds`, `samba/.creds-<user2>`, `ssh` host keys, `polkit-1/rules.d/`, `nftables/`, `wpa_supplicant.conf`, `.etckeeper`, `.git/`.

No hook rearrangement fixes this; Vorta's pre-backup command also runs unprivileged. Exporting a root-readable bundle into `/home` would work but spills `shadow` and credentials into user-readable space — the wrong trade.

Verified capture after implementation:

```
-rw------- root root   51  etc/samba/.creds
-rw------- root root   51  etc/samba/.creds-<user2>
-rw------- root root 3834  etc/ssh/sshd_config
-r--r----- root root 4375  etc/sudoers
-rw-r--r-- root root 1714  etc/fstab
-rw------- root root  131  etc/crypttab
---------- root root 1301  etc/shadow
```

`/etc` was subsequently **removed from Vorta's sources**. Keeping both leaves a hollow user-readable copy alongside a complete root copy in a different repository — ambiguity at exactly the wrong moment.

### 8.8 Root job implementation

`/usr/local/sbin/borg-etc-backup.sh`, `0700 root:root`. Passphrase at `/etc/borg/passphrase`, `0600 root:root`, consumed via `BORG_PASSCOMMAND`.

Compression `zstd,3` rather than lz4 — `/etc` is small and text-heavy. `--one-file-system` prevents descent into anything mounted beneath the source paths.

Units: `borg-etc.service` (`Type=oneshot`, `Nice=10`, `IOSchedulingClass=idle`) and `borg-etc.timer` (`OnCalendar=*-*-* 10:30:00`, `Persistent=true`, `RandomizedDelaySec=120`).

`After=network-online.target` / `Wants=network-online.target` are required — without them the unit races the interface at boot.

First run: 3,017 files, 148.24 MB original, 57.12 MB compressed, 2.37 seconds.

### 8.9 Exclusions

The initial source set produced 197.80 GB original / 82.59 GB deduplicated. Almost all of it was re-acquirable or already replicated elsewhere.

| Path | Size | Reason |
|---|---|---|
| `~/.local/share/Steam` | 91 G | Re-downloadable from Valve |
| `~/.thunderbird` | 16 G | Corrupt profile pending rebuild — reinstate once rebuilt |
| `~/joplin-forensic-20260713` | 6.0 G | Incident artefact; move to `tank/archive` |
| `~/.local/share/zed` | 355 M | Language servers, re-downloadable |
| `~/Downloads` | 254 M | Transient |
| `~/.local/share/akonadi` | 125 M | Orphaned; `akonadi-server` is not installed |
| `**/node_modules`, `**/.cache`, Trash | — | Standard |

Deliberately **retained**: `~/.config/joplin-desktop` (1.2 G) and `~/.var` — the Joplin notes database and flatpak state. Given the June–July sync failure, a local backup independent of WebDAV is precisely the safety net that was missing. `~/.config/vivaldi` (862 M) retained as profile state.

**Pattern selector note:** Vorta inserts `pf:` when using the folder picker. `pf:` is full-path match — one exact path, no recursion. **`pp:` (path prefix) is what directory-tree exclusion requires.** Use the dialog's Preview tab to confirm patterns resolve against the real filesystem. Borg patterns are case-sensitive: `.thunderbird`, not `.Thunderbird`.

Result: first run against the rebuilt repository completed in 4 minutes 47 seconds, against 25 minutes previously.

### 8.10 Restore manifest

`~/Scripts/export-packages.sh` runs as a Vorta pre-backup hook, writing to `~/Scripts/restore-manifest/` — inside the Borg source set, so it travels with every archive.

Hook command:

```
bash /home/<user>/Scripts/export-packages.sh || true
```

Captures: user-installed and full package lists, packages with no originating repository, repository definitions and a copy of `/etc/yum.repos.d`, flatpak apps and remotes, pipx/npm/cargo, Ollama models, enabled **and masked** systemd units, timers, autostart entries, fstab and mounts. Regenerates `RESTORE.sh` on every run so the driver cannot drift from the manifest beside it.

Design constraints:

- No `sudo` — everything captured is readable unprivileged.
- No `set -e` on the outer script; every collector wrapped; unconditional `exit 0`. A manifest failure must never abort a backup.
- `PATH` set explicitly — Vorta does not run a login shell.
- `OLLAMA_HOST` set explicitly — see §11.2.
- `dnf --no-plugins --skip-file-locks` under `timeout 120`, because `dnf-makecache.timer` can hold the lock.

Masked units are captured alongside enabled ones: a rebuild that restores only "enabled" silently undoes deliberate hardening.

First run: 351 user-installed packages; only `rpmfusion-free-release`, `rpmfusion-nonfree-release` and `vivaldi-stable` lack an originating repository, and the first two are bootstrap packages already handled in `RESTORE.sh`.

---

## 9. Configuration management

etckeeper installed, git backend, dnf hook active. Baseline commit `e3ce854`, first automatic hook commit `049c584`.

Running `dnf` as an unprivileged user produces harmless `Permission denied` noise from `/etc/etckeeper/pre-install.d/10packagelist` attempting to write `/var/cache/etckeeper`. Cosmetic; `--no-plugins` silences it where the output matters.

etckeeper provides history and diffs. It is **not** the backup transport — that is the root Borg job in §8.8.

---

## 10. Git and code signing

Identity: <author>, `<commit-address>`.

Four keys, separated so revoking one does not cascade:

| Key | Purpose |
|---|---|
| `~/.ssh/id_ed25519_gitea` | Gitea (`spelga`, 192.0.2.17) |
| `~/.ssh/id_ed25519_gh_rich` | GitHub `<github-primary>` |
| `~/.ssh/id_ed25519_gh_hacks` | GitHub `<github-secondary>` |
| `~/.ssh/id_ed25519_sign` | Commit signing, fingerprint `SHA256:<fingerprint>` |
| `~/.ssh/id_ed25519_borg` | Borg `/home` repository |
| `/root/.ssh/id_ed25519_borg_etc` | Borg `/etc` repository |

`~/.ssh/config` uses host aliases with `IdentitiesOnly yes`. This matters: without it, SSH offers every loaded key and GitHub authenticates as whichever matches first — the standard cause of pushing to the wrong account.

Signing via `gpg.format ssh`, `commit.gpgsign true`, `gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers`. Verified:

```
Good "git" signature for <commit-address> with ED25519 key SHA256:DzTk…
```

**Forge split:** Gitea is canonical for private material — infrastructure documentation, INTERNAL-tier content, scripts. GitHub is required for the blog because Cloudflare Pages builds from it. Public repositories go to GitHub with Gitea configured as a push mirror. The control that keeps this safe is that INTERNAL-tier repositories have no GitHub remote configured at all — absence of the remote beats remembering not to push.

`gitleaks` 8.30.0 installed as the local pre-push gate.

### 10.1 USB transfer artefact

The `richhacks` working copy was moved via USB and showed 44 modified files at `+0 −0` — `mode change 100644 => 100755` throughout, the signature of a filesystem without POSIX permission bits.

Resolved by resetting the working tree to match the index rather than setting `core.fileMode false`, which would hide the discrepancy while leaving the tree wrong:

```
git ls-files -s | awk '$1=="100644"{ $1=$2=$3=""; sub(/^ +/,""); print }' | tr '\n' '\0' | xargs -0 chmod 644
```

A fresh clone remains preferable once key uploads are complete — a USB copy also carries a stale index.

---

## 11. Development and LLM toolchain

### 11.1 Editor and languages

Zed installed via the vendor script to `~/.local/`. Configuration at `~/.config/zed/settings.json` and `keymap.json`, both held in project knowledge and in Gitea. JetBrains Mono for the buffer font; a Nerd Font variant is required in Konsole for Starship glyphs.

Node 22, pnpm 10.33, pipx, pandoc 3.7 (required by the four-tier documentation pipeline). Starship and zoxide installed; `bash-color-prompt` should be removed as it sets `PS1` from `/etc/profile.d` and conflicts with Starship.

### 11.2 Ollama and ROCm

Installed via the vendor script, which bundles its own ROCm runtime. **The `repo.radeon.com` RHEL repository is deliberately not used** — it is pinned to an older kernel and userspace and causes version skew on Fedora 44. Only Fedora's `rocminfo` and `rocm-smi` are installed, for diagnostics.

GPU confirmed as `gfx1100`, natively supported; no `HSA_OVERRIDE_GFX_VERSION` required.

Bound to the management interface per estate policy, not `0.0.0.0`:

```
OLLAMA_HOST=192.0.2.150:11434
```

**Consequence to remember:** the `ollama` CLI defaults to `127.0.0.1:11434` and will report "could not connect to ollama server" against a perfectly healthy service. `OLLAMA_HOST` must be exported for interactive use and inside any script that shells out to it.

`/dev/kfd` and `/dev/dri/renderD128` are mode `0666` under Fedora's defaults, which makes `render`/`video` group membership decorative. Acceptable for a single-user desktop; a udev rule to `0660 root:render` would tighten it.

Model definitions live in the `hybrid-llm-models` repository on Gitea — never only on the workstation. The previous generation of Modelfiles was lost twice, once to this rebuild and once to corruption.

---

## 12. Incident summary

| # | Incident | Root cause | Resolution |
|---|---|---|---|
| 1 | Borg repository segment corruption | SMB write path; Borg requires POSIX locking and atomic renames | Repository destroyed and rebuilt over SSH |
| 2 | Wireless firmware removed while in use | Firmware loads at probe; removal is delayed-action | Reinstated before reboot |
| 3 | USB media unmountable | `udisks2` autoremoved as an orphaned dependency | Reinstalled |
| 4 | Hollow `/etc` backup | Vorta runs unprivileged | Root-owned Borg job to a separate repository |
| 5 | 44 spurious file modifications in git | USB transit through a filesystem without permission bits | Working tree reset to index |
| 6 | `ruff` installed under root's pipx | `sudo pipx install` | Reinstall as `<user>` |

---

## 13. Outstanding

- `localsearch-3.desktop` still autostarting alongside disabled Baloo
- ibus CJK input-method stack still installed
- `bash-color-prompt` conflicts with Starship
- SSH public keys not yet uploaded to GitHub or Gitea — blocks all pushes
- `ruff` reinstall as `<user>`; Zed Python formatter inactive until then
- Ollama base tags to verify; systemd override and firewall rules to apply; `build-models.sh` to run
- Old CIFS repository at `/tank/Downloads/downloads/backups` (~77 GiB) retained as forensic evidence — reclaim after the postmortem is written
- Nightly shutdown timer not recreated; must sit after 10:45 or both jobs will miss their windows
- Steam library relocation to the spare 1 TB NVMe would render its exclusion moot

---

## 14. Estate learnings

1. **`borg info` is not a health check.** It reads the manifest only. A repository with corrupt segments reports clean. Only `borg check` reads data.
2. **Borg over CIFS/SMB produces silent corruption.** Not theoretical — observed here, attributable by hash comparison to the SMB write path.
3. **`borg check --repair` is destructive.** It removes references to missing objects, producing archives that validate but have holes.
4. **Firmware removal is delayed-action.** Loaded firmware persists until reboot; the failure surfaces later, often during an unrelated change.
5. **Proxmox directory mount points use `bind`, not `rbind`.** Child ZFS datasets do not propagate into containers — relied upon here to keep the backup repository and Vaultwarden's dataset outside a Samba share.
6. **Unprivileged backup agents cannot capture system configuration.** Any design where the backup client runs as a desktop user needs a separate privileged job.
7. **Masked units are part of the configuration.** A restore that only replays "enabled" silently undoes hardening.
8. **`pf:` is not `pp:`.** Vorta's folder picker inserts full-path match where prefix match is meant.
9. **Vendor install scripts reset systemd overrides.** Re-verify Ollama's binding after every upgrade.
10. **Binding to a specific interface breaks CLI clients that assume loopback.** Correct for security; requires an environment variable everywhere the CLI is used.
