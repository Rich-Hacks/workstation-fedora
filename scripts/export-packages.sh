#!/usr/bin/env bash
#
# export-packages.sh — capture a complete restore manifest for this workstation.
#
# Runs as an unprivileged pre-backup hook from Vorta, so the output lands inside
# the Borg source set and travels with every archive. Never uses sudo: everything
# captured here is readable by a normal user.
#
# Designed never to fail the backup. Individual collectors that error are logged
# and skipped; the script always exits 0.
#
# Install:   ~/Scripts/export-packages.sh   (chmod 750)
# Vorta:     Schedule tab -> "Run command before backup":
#                bash /home/feduser/Scripts/export-packages.sh || true
#
# Output:    ~/Scripts/restore-manifest/
# Log:       ~/Scripts/restore-manifest/export.log
#
set -uo pipefail

# Vorta does not run a login shell, so PATH is minimal. Set it explicitly.
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:${HOME}/.local/bin"
export LC_ALL=C

OUT_DIR="${MANIFEST_DIR:-${HOME}/Scripts/restore-manifest}"
LOG_FILE="${OUT_DIR}/export.log"
MAX_LOG_BYTES=1048576

mkdir -p "${OUT_DIR}" || { echo "cannot create ${OUT_DIR}" >&2; exit 0; }

# Trim the log rather than let it grow without bound.
if [[ -f "${LOG_FILE}" ]] && [[ "$(stat -c %s "${LOG_FILE}" 2>/dev/null || echo 0)" -gt "${MAX_LOG_BYTES}" ]]; then
    tail -c 262144 "${LOG_FILE}" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "${LOG_FILE}"
fi

exec >>"${LOG_FILE}" 2>&1
echo "=============================================================="
echo "=== run $(date -Is)"

FAILED=0

# capture <output-file> <description> <command...>
# Writes to a temporary file first so a failed collector never leaves a
# truncated manifest behind from a previous good run.
capture() {
    local out="${OUT_DIR}/$1"; shift
    local desc="$1"; shift
    local tmp="${out}.tmp.$$"

    if "$@" > "${tmp}" 2>>"${LOG_FILE}"; then
        mv -f "${tmp}" "${out}"
        printf '  ok      %-28s (%s lines)\n' "${desc}" "$(wc -l < "${out}")"
    else
        rm -f "${tmp}"
        printf '  SKIPPED %-28s (command failed or absent)\n' "${desc}"
        FAILED=$((FAILED + 1))
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# System identity
# --------------------------------------------------------------------------
{
    echo "# Workstation restore manifest"
    echo "# Generated: $(date -Is)"
    echo
    echo "Hostname:      $(hostname)"
    echo "User:          $(id -un) (uid $(id -u))"
    echo "Groups:        $(id -Gn)"
    echo "OS:            $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
    echo "Kernel:        $(uname -r)"
    echo "Desktop:       ${XDG_CURRENT_DESKTOP:-unknown} / ${XDG_SESSION_TYPE:-unknown}"
    echo "CPU:           $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')"
    echo "Memory:        $(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
    echo "GPU:           $(lspci 2>/dev/null | grep -iE 'vga|3d controller' | cut -d: -f3- | sed 's/^ *//' | paste -sd'; ')"
} > "${OUT_DIR}/00-system-info.txt" 2>/dev/null
echo "  ok      system identity"

# --------------------------------------------------------------------------
# RPM packages
# --------------------------------------------------------------------------
# The reinstall list. --userinstalled excludes packages pulled in only as
# dependencies, so restoring this set plus dependency resolution reproduces the
# machine without dragging in cruft that has since been removed upstream.
#
# Output format is NAME-EPOCH:VERSION-RELEASE.ARCH; strip back to bare names so
# the list can be fed straight to dnf install.
if have dnf; then
    if dnf repoquery --userinstalled 2>>"${LOG_FILE}" \
        | sed -E 's/-[0-9]+:.*$//' | sort -u > "${OUT_DIR}/10-packages-userinstalled.txt.tmp.$$" \
        && [[ -s "${OUT_DIR}/10-packages-userinstalled.txt.tmp.$$" ]]; then
        mv -f "${OUT_DIR}/10-packages-userinstalled.txt.tmp.$$" "${OUT_DIR}/10-packages-userinstalled.txt"
        printf '  ok      %-28s (%s packages)\n' "user-installed packages" \
            "$(wc -l < "${OUT_DIR}/10-packages-userinstalled.txt")"
    else
        rm -f "${OUT_DIR}/10-packages-userinstalled.txt.tmp.$$"
        echo "  SKIPPED user-installed packages"
        FAILED=$((FAILED + 1))
    fi
fi

# Full installed set, for forensics rather than restore.
capture "11-packages-all.txt" "all installed packages" \
    bash -c "rpm -qa --qf '%{NAME}\n' | sort -u"

# Versioned, for reproducing an exact point in time if ever needed.
capture "12-packages-all-versioned.txt" "all packages (versioned)" \
    bash -c "rpm -qa | sort"

# Packages with no originating repository. These were installed from a
# downloaded RPM or a vendor script and CANNOT be restored by dnf alone --
# each one needs manual reacquisition. Check this file first after a rebuild.
capture "13-packages-no-repo.txt" "packages without a repo" \
    bash -c "dnf repoquery --installed --qf '%{name} %{from_repo}\n' 2>/dev/null \
             | awk '\$2 == \"\" || \$2 == \"@System\" || \$2 == \"@commandline\" {print \$1}' | sort -u"

# Repository definitions. RPM Fusion, Vivaldi, Insync, Tailscale and friends all
# live here; without them the package list above will not resolve.
capture "14-repos-enabled.txt" "enabled repositories" \
    dnf repolist --enabled

if [[ -d /etc/yum.repos.d ]]; then
    rm -rf "${OUT_DIR}/15-yum.repos.d"
    if cp -a /etc/yum.repos.d "${OUT_DIR}/15-yum.repos.d" 2>>"${LOG_FILE}"; then
        echo "  ok      repo definitions copied"
    else
        echo "  SKIPPED repo definitions"
        FAILED=$((FAILED + 1))
    fi
fi

# --------------------------------------------------------------------------
# Flatpak
# --------------------------------------------------------------------------
if have flatpak; then
    capture "20-flatpak-apps.txt" "flatpak applications" \
        flatpak list --app --columns=application,origin,branch,installation
    capture "21-flatpak-remotes.txt" "flatpak remotes" \
        flatpak remotes --columns=name,url,options
fi

# --------------------------------------------------------------------------
# Language-ecosystem packages, invisible to dnf
# --------------------------------------------------------------------------
have pipx  && capture "30-pipx.txt"  "pipx packages"   pipx list --short
have npm   && capture "31-npm-global.txt" "npm globals" npm ls -g --depth=0
have cargo && capture "32-cargo.txt" "cargo binaries"  cargo install --list
have gem   && capture "33-gem.txt"   "ruby gems"       gem list --local --no-versions

# --------------------------------------------------------------------------
# Ollama models
# --------------------------------------------------------------------------
# Records which models were present. The Modelfiles themselves live in Gitea
# (hybrid-llm-models) -- this is a cross-check, not the source of truth.
if have ollama; then
    capture "40-ollama-models.txt" "ollama models" ollama list
fi

# --------------------------------------------------------------------------
# systemd state
# --------------------------------------------------------------------------
# Masked units matter as much as enabled ones: a rebuild that re-enables
# everything undoes deliberate hardening. Capture both.
capture "50-systemd-enabled.txt" "enabled system units" \
    systemctl list-unit-files --state=enabled --no-pager --no-legend
capture "51-systemd-masked.txt" "masked system units" \
    systemctl list-unit-files --state=masked --no-pager --no-legend
capture "52-systemd-user-enabled.txt" "enabled user units" \
    systemctl --user list-unit-files --state=enabled --no-pager --no-legend
capture "53-systemd-timers.txt" "active timers" \
    systemctl list-timers --all --no-pager --no-legend

# --------------------------------------------------------------------------
# Desktop and mounts
# --------------------------------------------------------------------------
capture "60-autostart-user.txt" "user autostart entries" \
    bash -c "ls -1 \"\${HOME}/.config/autostart\" 2>/dev/null || true"
capture "61-autostart-system.txt" "system autostart entries" \
    bash -c "ls -1 /etc/xdg/autostart 2>/dev/null || true"
capture "62-fstab.txt" "fstab" cat /etc/fstab
capture "63-mounts.txt" "current mounts" \
    findmnt --real --output TARGET,SOURCE,FSTYPE,OPTIONS

# --------------------------------------------------------------------------
# Generate the reinstall driver
# --------------------------------------------------------------------------
# Written fresh each run so it can never drift from the manifest beside it.
cat > "${OUT_DIR}/RESTORE.sh" <<'RESTORE_EOF'
#!/usr/bin/env bash
#
# RESTORE.sh — rebuild this workstation's software set from the manifest.
#
# Generated automatically by export-packages.sh. Run from inside the restored
# manifest directory, on a freshly installed Fedora of the SAME major release
# (check 00-system-info.txt).
#
# This is deliberately interactive and staged. Read each section before running
# it; do not pipe this to a shell unattended.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "=== Stage 1: repository definitions ==="
echo "Third-party repos must exist before the package list will resolve."
echo "Review, then copy:"
echo "    sudo cp -n 15-yum.repos.d/*.repo /etc/yum.repos.d/"
echo "RPM Fusion, if used:"
echo "    sudo dnf install \\"
echo "      https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-\$(rpm -E %fedora).noarch.rpm \\"
echo "      https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-\$(rpm -E %fedora).noarch.rpm"
read -rp "Press Enter when repositories are in place... "

echo
echo "=== Stage 2: packages installed outside any repository ==="
echo "These cannot be restored by dnf and need manual reacquisition:"
cat 13-packages-no-repo.txt 2>/dev/null || echo "(none recorded)"
read -rp "Press Enter to continue... "

echo
echo "=== Stage 3: dnf packages ==="
echo "$(wc -l < 10-packages-userinstalled.txt) packages to install."
echo "Dry run first:"
echo "    sudo dnf install --assumeno \$(tr '\n' ' ' < 10-packages-userinstalled.txt)"
read -rp "Press Enter to run the real install, Ctrl-C to abort... "
sudo dnf install $(tr '\n' ' ' < 10-packages-userinstalled.txt)

echo
echo "=== Stage 4: flatpak ==="
if [[ -s 21-flatpak-remotes.txt ]]; then
    while read -r name url _; do
        [[ -z "${name:-}" ]] && continue
        sudo flatpak remote-add --if-not-exists "${name}" "${url}" || true
    done < 21-flatpak-remotes.txt
fi
if [[ -s 20-flatpak-apps.txt ]]; then
    while read -r app origin _; do
        [[ -z "${app:-}" ]] && continue
        sudo flatpak install -y "${origin}" "${app}" || true
    done < 20-flatpak-apps.txt
fi

echo
echo "=== Stage 5: language ecosystems ==="
[[ -s 30-pipx.txt ]] && echo "pipx:  $(tr '\n' ' ' < 30-pipx.txt)"
[[ -s 32-cargo.txt ]] && echo "cargo: see 32-cargo.txt"
[[ -s 31-npm-global.txt ]] && echo "npm:   see 31-npm-global.txt"
echo "Install these manually -- versions matter more than completeness here."

echo
echo "=== Stage 6: systemd state ==="
echo "Re-apply MASKED units before enabling anything, or hardening is undone:"
cat 51-systemd-masked.txt 2>/dev/null || echo "(none recorded)"
echo
echo "Then compare 50-systemd-enabled.txt against the fresh install and enable"
echo "only what differs. Do not bulk-enable: the fresh install's defaults are"
echo "usually correct."

echo
echo "=== Stage 7: manual follow-up ==="
echo "  - Ollama models:  see 40-ollama-models.txt; rebuild from the"
echo "                    hybrid-llm-models repo in Gitea, not from this file."
echo "  - Mounts:         62-fstab.txt (credentials files are NOT in this"
echo "                    manifest -- retrieve them from Vaultwarden)."
echo "  - Restore \$HOME from Borg separately; this manifest covers software only."
echo
echo "Done."
RESTORE_EOF
chmod 755 "${OUT_DIR}/RESTORE.sh"
echo "  ok      RESTORE.sh regenerated"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
{
    echo "Manifest generated: $(date -Is)"
    echo "Collectors failed:  ${FAILED}"
    echo
    echo "Files:"
    ls -la "${OUT_DIR}" | sed 's/^/  /'
} > "${OUT_DIR}/INDEX.txt"

echo "=== complete: ${FAILED} collector(s) skipped"

# Always succeed. A manifest failure must never abort the backup itself.
exit 0
