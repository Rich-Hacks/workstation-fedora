# workstation-fedora

Build notes, scripts and configuration for a Fedora 44 KDE workstation used for
homelab administration, cybersecurity work and local LLM inference.

This is a real machine, not a reference build. Everything here was arrived at by
running it, breaking it, and writing down what broke. The gotchas are the point —
several of them cost hours and none of them are obvious from the documentation.

Addressing throughout uses [RFC 5737](https://datatracker.ietf.org/doc/html/rfc5737)
documentation ranges (`192.0.2.0/24`). Substitute your own.

---

## Contents

- [Hardware](#hardware)
- [Repository layout](#repository-layout)
- [Base install and disk encryption](#base-install-and-disk-encryption)
- [Filesystem and snapshots](#filesystem-and-snapshots)
- [Desktop lean-down](#desktop-lean-down)
- [Network mounts](#network-mounts)
- [Backups](#backups)
- [Local LLM](#local-llm)
- [Monitoring](#monitoring)
- [Gotchas](#gotchas)
- [Roadmap](#roadmap)

---

## Hardware

| Component | Detail |
|---|---|
| CPU | AMD Ryzen 9 3900X |
| GPU | Radeon RX 7900 XTX (Navi 31, `gfx1100`), 24 GB |
| RAM | 32 GB |
| Storage | 2 TB NVMe (btrfs on LUKS2) |
| Wireless | Intel Wi-Fi 6 AX200 |
| Security key | YubiKey 5 (LUKS unlock) |

OS: Fedora 44 KDE Plasma 6.6, kernel 7.1.

---

## Repository layout

```
scripts/
  export-packages.sh      Pre-backup system manifest generator
  borg-etc-backup.sh      Root-owned /etc backup job
config/
  zed/settings.json       Editor configuration
  ollama-override.conf    systemd drop-in for Ollama
  fstab.example           CIFS mount pattern
docs/
  workstation-rebuild.md  Full build writeup
```

---

## Base install and disk encryption

LUKS2 root with a FIDO2 keyslot enrolled via `systemd-cryptenroll`, YubiKey
**with PIN** — possession plus knowledge.

```bash
sudo systemd-cryptenroll --fido2-device=auto /dev/nvme0n1p3
```

### TPM2 auto-unlock: evaluated, declined

You can add a TPM2 slot alongside FIDO2 — LUKS keyslots are independent, so boot
tries TPM first and falls back to the key when PCRs change:

```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/nvme0n1p3
```

Declined here because TPM auto-unlock means a stolen machine boots straight to
the display manager. Disk encryption then only protects against drive removal,
and your login password becomes the entire perimeter. Reasonable for a desktop
that never leaves the house; know what you're trading.

**Chained TPM *and* FIDO2 as a single requirement is not possible.** Keyslots are
OR-factors; there is no AND composition. The closest equivalents are
`--tpm2-with-pin=yes` or FIDO2-with-PIN.

Keep the passphrase slot. TPM and FIDO2 slots can both be invalidated by a
firmware update.

---

## Filesystem and snapshots

btrfs on LUKS, managed with [Btrfs Assistant](https://gitlab.com/btrfs-assistant/btrfs-assistant)
over snapper.

```
Config │ Subvolume
───────┼──────────
Daily  │ /
```

**`/home` is deliberately not snapshotted.** Two reasons: Borg owns `/home`, and
timeline snapshots of a ~90 GB Steam library will eat the drive. If you add a
`/home` config, revisit your backup exclusions at the same time or you'll be
storing the same data three ways.

Btrfs Assistant enables `snapper-boot`, `snapper-cleanup` and `snapper-timeline`
against a `disabled` preset. That's expected, not a misconfiguration.

---

## Desktop lean-down

The KDE live ISO leaves a lot behind. Audit with:

```bash
dnf repoquery --userinstalled | sort
systemctl list-unit-files --state=enabled --no-pager
ls /etc/xdg/autostart
systemd-analyze blame | head -25
```

What came off this machine:

| Group | Packages | Why |
|---|---|---|
| Live ISO residue | `livesys-scripts`, `anaconda-live`, `dracut-live`, `isomd5sum` | `livesys.service` was **enabled** on an installed system |
| VM guest agents | `qemu-guest-agent`, `open-vm-tools-desktop`, `virtualbox-guest-additions`, `spice-vdagent`, `hyperv-daemons` | Bare metal. Four enabled daemons, three autostart entries |
| Intel daemons | `thermald`, `intel-lpmd`, `switcheroo-control` | Intel-specific, no-ops on AMD |
| Unused storage | `iscsi-initiator-utils`, `mdadm`, `hfsplus-tools`, `mactel-boot` | Single NVMe, no iSCSI, no md RAID |
| Enterprise identity | `sssd-*`, `realmd` | Not domain-joined |
| Serial-port hazards | `brltty`, `ModemManager` | See gotchas — both claim USB serial devices |

Masked rather than removed, for reversibility or dependency reasons:

```bash
sudo systemctl mask --now \
  lvm2-monitor.service dm-event.socket lvm2-lvmpolld.socket \
  systemd-homed.service plasma-setup.service cups-browsed.service
```

`cups-browsed` is masked as attack-surface reduction — it's the component behind
the 2024 CUPS RCE chain, and automatic remote printer discovery is rarely wanted.

**Run every removal with `--assumeno` first and read the transaction.** See the
`udisks2` entry under gotchas for why.

---

## Network mounts

CIFS to a NAS, credentials in root-owned files:

```bash
sudo install -m 600 -o root -g root /dev/null /etc/samba/.creds
sudo sudoedit /etc/samba/.creds     # username=… / password=…
```

```
//192.0.2.32/<share> /mnt/<name> cifs credentials=/etc/samba/.creds,uid=1000,gid=1000,file_mode=0640,dir_mode=0750,vers=3.1.1,_netdev,x-systemd.automount,x-systemd.idle-timeout=300 0 0
```

`_netdev` plus `x-systemd.automount` is the important part: no boot hang when the
NAS is down, and the mount is deferred until first access.

---

## Backups

Two Borg repositories over SSH, plus btrfs snapshots for fast local rollback.
Different jobs, different failure modes, different repositories.

### Why not SMB

The first iteration wrote a Borg repository to a CIFS mount. It failed:

```
Data integrity error: Segment entry checksum mismatch [segment 19, offset 37258665]
Index object count mismatch.
committed index: 71169 objects
rebuilt index:   70915 objects
```

254 objects referenced by the manifest were missing. Hashing the suspect segment
in both the original and migrated locations gave identical digests, proving the
corruption came from the SMB write path rather than the migration.

Borg needs POSIX locking and atomic renames. CIFS provides neither reliably, and
[upstream advises against it](https://borgbackup.readthedocs.io/en/stable/faq.html).
It works right up until it doesn't.

**The repository reported healthy throughout.** `borg info` returned a clean
manifest twice. `info` reads the manifest; only `check` reads segment data. If
your monitoring calls `borg info`, it is monitoring nothing.

### Architecture

```
workstation (user) ──ssh──┐
                          ├──> NAS :22 ──> borg serve (forced command)
workstation (root) ───────┘                     │
                                                └─> ZFS dataset
                                                      └─> snapshots → replication → off-site
```

Server side, one line per client in `authorized_keys`:

```
command="/usr/local/bin/borg serve --restrict-to-repository /srv/backups/home",restrict ssh-ed25519 AAAA… user@workstation
```

`--restrict-to-repository` is tighter than `--restrict-to-path` — the key can
operate on that one repository and cannot create others. `restrict` disables pty,
agent forwarding, port forwarding and X11 in a single token.

Both keys are passphraseless because both drive unattended timers. The forced
command is the compensating control: a stolen key can only speak the Borg
protocol to one named repository.

### Two jobs, and why

| Repository | Runs as | Sources | Schedule |
|---|---|---|---|
| `home` | Vorta, desktop user | `/home/<user>` | daily |
| `etc` | root, systemd timer | `/etc`, `/root`, `/usr/local/{bin,sbin}` | daily, 15 min earlier |

**Vorta runs as your desktop user and cannot back up your system configuration.**
Every file that matters for a rebuild fails with `Errno 13`: `shadow`, `sudoers`,
`crypttab`, `sshd_config`, `polkit` rules, Samba credentials, `/etc/.git`. No hook
arrangement fixes this — Vorta's pre-backup command also runs unprivileged.

The answer is a second Borg client running as root, to its own repository. Not the
same repository with a different prefix: separate retention, unambiguous restores.

Verify yours actually captured them:

```bash
borg list <repo>::<archive> | grep -E 'etc/(shadow|sudoers|crypttab)$|sshd_config$'
```

If those lines are missing, your `/etc` backup is decorative.

### Exclusions

The first run was 197 GB original, 82 GB deduplicated. Almost all of it was
re-acquirable or already replicated:

```
pp:/home/<user>/.local/share/Steam        # re-downloadable
pp:/home/<user>/.local/share/zed          # language servers
pp:/home/<user>/.local/share/akonadi      # orphaned if you use Thunderbird
pp:/home/<user>/Downloads
**/node_modules
**/.cache
```

After exclusions: ~2 GB, and the run went from 25 minutes to under 5.

**Vorta's folder picker inserts `pf:`, which is wrong for directories.** `pf:` is
full-path match — one exact path, no recursion. You want `pp:` (path prefix).
Patterns are also case-sensitive: `.thunderbird`, not `.Thunderbird`. The dialog's
**Preview** tab resolves patterns against your real filesystem — use it.

### Restore manifest

`scripts/export-packages.sh` runs as a Vorta pre-backup hook and writes a full
software inventory inside the backup source set, so it travels with every archive:
package lists, repository definitions, flatpaks, pipx/npm/cargo, enabled **and
masked** systemd units, autostart entries, fstab. It regenerates a staged
`RESTORE.sh` on every run.

Hook command:

```
bash /home/<user>/Scripts/export-packages.sh || true
```

The `|| true` is deliberate — Vorta aborts a backup if the pre-backup command
fails, and a missing manifest is worth less than a missing archive.

Two files in the output matter more than the rest:

- **`13-packages-no-repo.txt`** — packages installed from a downloaded RPM or a
  vendor script. These are invisible to `dnf install` and are what turns a
  two-hour rebuild into a two-day one.
- **`51-systemd-masked.txt`** — a restore that replays only "enabled" silently
  undoes your hardening.

---

## Local LLM

Ollama against the 7900 XTX via ROCm.

**Don't add the `repo.radeon.com` repository on Fedora.** It's pinned to RHEL's
kernel and userspace and causes version skew. The Ollama installer bundles its own
ROCm runtime, and the `amdgpu` kernel driver is already in-tree. Install Fedora's
`rocminfo` and `rocm-smi` for diagnostics only.

```bash
sudo dnf install rocminfo rocm-smi
rocminfo | grep -i gfx1100
curl -fsSL https://ollama.com/install.sh | sh
```

`gfx1100` is natively supported — no `HSA_OVERRIDE_GFX_VERSION` needed.

`config/ollama-override.conf`:

```ini
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
Environment="OLLAMA_HOST=192.0.2.150:11434"
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_MAX_LOADED_MODELS=2"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Restart=on-failure
```

Notes that cost time to learn:

- `After=network-online.target` is **mandatory** when binding a specific address,
  or the unit races the interface at boot.
- `OLLAMA_FLASH_ATTENTION=1` is a prerequisite for `OLLAMA_KV_CACHE_TYPE`. Without
  it the KV cache quantisation is silently ignored.
- `OLLAMA_KEEP_ALIVE=-1` is a trap on a 24 GB card once you run a 27B model —
  pinning everything starves the embedder. Use an idle timeout plus
  `MAX_LOADED_MODELS` and let LRU handle it.
- **The installer resets systemd overrides.** Re-check after every upgrade.
- Binding to a specific interface means the `ollama` CLI can't find its own server,
  because it defaults to `127.0.0.1:11434`. Export `OLLAMA_HOST` in your shell rc
  and in any script that shells out to it.

Firewall, source-restricted rather than open to the LAN:

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.0.2.13/32" port port="11434" protocol="tcp" accept'
sudo firewall-cmd --reload
```

Keep your Modelfiles in git. Not on the workstation. Ask me how I know.

---

## Monitoring

Four layers, in descending order of value:

1. **Heartbeat push monitors.** Each backup job pings an
   [Uptime Kuma](https://github.com/louislam/uptime-kuma) push URL on success; if
   the ping doesn't arrive within the window, you get alerted. This catches the
   failure that actually happens — the job quietly stopping. Run the monitor on
   different hardware from the thing it watches.

   ```bash
   curl -fsS -m 10 --retry 3 "http://192.0.2.50:3001/api/push/<token>" >/dev/null || true
   ```

2. **`OnFailure=` on the systemd unit**, and Vorta's failure notifications.

3. **Scheduled `borg check`.** Not `borg info`. Monthly on the small repository,
   fortnightly on the large one. This is what caught the corruption above.

4. **Quarterly restore drill.** Extract a known file and diff it against the live
   copy. Nothing else proves the chain works.

---

## Gotchas

**Removing firmware packages is a delayed-action change.** Wireless firmware is
loaded at driver probe and stays resident. Remove `iwlwifi-mvm-firmware` and your
wifi keeps working — until the next reboot, on a machine with no wired fallback.
Check what you actually have before pruning `linux-firmware` subpackages:

```bash
lspci -nnk | grep -A3 -Ei 'network|wireless'
```

**`udisks2` can get autoremoved as an orphaned dependency**, and then USB drives
stop mounting in Dolphin with no obvious cause. Inspect transactions with
`--assumeno`, and remember `dnf history info <id>` and `dnf history undo <id>`.

**`brltty` claims USB serial devices on hotplug.** It's a braille display driver,
and it's the classic reason your USB-serial adapter, Arduino or LTE modem stops
being recognised. `ModemManager` does the same thing by probing serial ports.

**Two file indexers can run at once.** KDE ships `baloo_file.desktop` and some
installs also carry `localsearch-3.desktop`. Check `/etc/xdg/autostart`.

**`plocate-updatedb.timer` will index your network mounts** unless `/etc/updatedb.conf`
prunes them. Add `cifs` to `PRUNEFS`.

**Files copied via FAT/exFAT lose their permission bits**, so git reports every
file as `mode change 100644 => 100755`. Don't paper over it with
`core.fileMode false` — reset the tree to match the index, or re-clone.

**Set `IdentitiesOnly yes`** in `~/.ssh/config` if you use multiple GitHub
accounts. Without it SSH offers every loaded key and GitHub authenticates you as
whichever matches first — the standard way people push to the wrong account.

**`etckeeper` writes noise when you run `dnf` unprivileged.** Harmless; add
`--no-plugins` where the output matters.

---

## Roadmap

Things planned or under consideration:

- **etckeeper → git remote.** Push `/etc` history to a private forge for diffable
  config history off the machine.
- **Append-only Borg keys.** Two server-side keys — append-only for the client,
  full access for a server-side prune timer. Makes the backup ransomware-resistant
  from the client's perspective.
- **Wired networking.** Both onboard NICs are unused; the 2.5 GbE would make
  restore drills and `borg check --verify-data` considerably less painful.
- **Steam on a dedicated drive**, which makes the largest exclusion moot.
- **SELinux confinement** for the Ollama service beyond the default unconfined
  systemd unit.
- **Secure Boot with a local MOK**, currently unsigned.
- **Automated restore drill** — a scripted extract-and-diff, run quarterly by a
  timer rather than by memory.
- **`ansible` or `mkosi` for the rebuild path.** The manifest tells you what to
  reinstall; it doesn't do it for you. A declarative rebuild is the logical next
  step.

---

## Related

- Writeup and background: [richhacks.blog](https://richhacks.blog)

## Disclaimer

These are notes from one machine, published because the failure modes are more
useful than the successes. Nothing here is a hardened reference build — read it,
understand it, and adapt it. Test your restores.

## Licence

MIT for scripts and configuration. Documentation under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
