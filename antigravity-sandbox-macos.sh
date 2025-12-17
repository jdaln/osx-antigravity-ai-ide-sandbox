#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Antigravity macOS sandbox wrapper (sandbox-exec + SBPL)
#
# Usage:
#   ~/bin/antigravity-sandbox-macos.sh
#   ANTIGRAVITY_PERSIST_REAL_CONFIG=1 ~/bin/antigravity-sandbox-macos.sh
#
# Optional toggles:
#   ANTIGRAVITY_DISABLE_CHROMIUM_SANDBOX=1  (default: 1)
#   ANTIGRAVITY_DISABLE_GPU=1               (default: 0)
#   ANTIGRAVITY_SANDBOX_SHELL=/bin/zsh      (default: /bin/zsh)
###############################################################################

REAL_HOME="${HOME}"

APP_BUNDLE="${ANTIGRAVITY_APP_BUNDLE:-/Applications/Antigravity.app}"
INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"

SANDBOX_ROOT="${REAL_HOME}/.sandboxes/antigravity"
SANDBOX_HOME="${REAL_HOME}/.sandboxes/antigravity-home"
PROFILE="${SANDBOX_ROOT}/antigravity.sb"

WORKDIR1="${ANTIGRAVITY_WORKDIR1:-${REAL_HOME}/AIProjects/Antigravity}"
WORKDIR2="${ANTIGRAVITY_WORKDIR2:-${REAL_HOME}/AIProjects/Shared}"

PERSIST="${ANTIGRAVITY_PERSIST_REAL_CONFIG:-0}"
DISABLE_CHROMIUM_SANDBOX="${ANTIGRAVITY_DISABLE_CHROMIUM_SANDBOX:-1}"
DISABLE_GPU="${ANTIGRAVITY_DISABLE_GPU:-0}"

SANDBOX_SHELL="${ANTIGRAVITY_SANDBOX_SHELL:-/bin/zsh}"

mkdir -p "${SANDBOX_ROOT}" "${SANDBOX_HOME}" "${WORKDIR1}" "${WORKDIR2}"

# Resolve actual .app executable robustly
if [ ! -f "${INFO_PLIST}" ]; then
  echo "Info.plist not found at: ${INFO_PLIST}" >&2
  exit 1
fi
BUNDLE_EXEC="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${INFO_PLIST}" 2>/dev/null
)"
APP="${APP_BUNDLE}/Contents/MacOS/${BUNDLE_EXEC}"
if [ ! -x "${APP}" ]; then
  echo "Antigravity executable not found/executable at: ${APP}" >&2
  exit 1
fi

# Dedicated tmp inside allowed /private/tmp
TMPROOT="$(mktemp -d /private/tmp/antigravity-tmp.XXXXXX)"
cleanup() { rm -rf "${TMPROOT}" || true; }
trap cleanup EXIT

# Helpers
backup_if_real_dir() {
  local p="$1"
  if [ -e "$p" ] && [ ! -L "$p" ]; then
    mv "$p" "${p}.sandbox-backup.$(date +%s)" || true
  fi
}

link_dir() {
  local real="$1" inside="$2"
  mkdir -p "$(dirname "$inside")"
  mkdir -p "$real"
  backup_if_real_dir "$inside"
  ln -sfn "$real" "$inside"
}

# If persistence is OFF, ensure no leftover symlinks exist inside SANDBOX_HOME
ensure_not_symlink() {
  local p="$1"
  if [ -L "$p" ]; then
    rm -f "$p"
  fi
  mkdir -p "$p"
}

# ---- Persistence targets (real paths)
REAL_GEMINI_ANTI="${REAL_HOME}/.gemini/antigravity"
REAL_GEMINI_BROWSER="${REAL_HOME}/.gemini/antigravity-browser-profile"
REAL_ANTIGRAVITY_DIR="${REAL_HOME}/.antigravity"
REAL_APP_SUPPORT="${REAL_HOME}/Library/Application Support/Antigravity"

# ---- Where the app will look (inside sandbox HOME)
SB_GEMINI_ANTI="${SANDBOX_HOME}/.gemini/antigravity"
SB_GEMINI_BROWSER="${SANDBOX_HOME}/.gemini/antigravity-browser-profile"
SB_ANTIGRAVITY_DIR="${SANDBOX_HOME}/.antigravity"
SB_APP_SUPPORT="${SANDBOX_HOME}/Library/Application Support/Antigravity"

# Decide what to allow RW in the profile (real or sandbox)
ALLOW_GEMINI_ANTI="${SB_GEMINI_ANTI}"
ALLOW_GEMINI_BROWSER="${SB_GEMINI_BROWSER}"
ALLOW_ANTIGRAVITY_DIR="${SB_ANTIGRAVITY_DIR}"
ALLOW_APP_SUPPORT="${SB_APP_SUPPORT}"

if [ "${PERSIST}" = "1" ] || [ "${PERSIST}" = "true" ]; then
  # Create symlinks inside sandbox HOME pointing to the real state dirs
  link_dir "${REAL_GEMINI_ANTI}" "${SB_GEMINI_ANTI}"
  link_dir "${REAL_GEMINI_BROWSER}" "${SB_GEMINI_BROWSER}"
  link_dir "${REAL_ANTIGRAVITY_DIR}" "${SB_ANTIGRAVITY_DIR}"
  link_dir "${REAL_APP_SUPPORT}" "${SB_APP_SUPPORT}"

  ALLOW_GEMINI_ANTI="${REAL_GEMINI_ANTI}"
  ALLOW_GEMINI_BROWSER="${REAL_GEMINI_BROWSER}"
  ALLOW_ANTIGRAVITY_DIR="${REAL_ANTIGRAVITY_DIR}"
  ALLOW_APP_SUPPORT="${REAL_APP_SUPPORT}"
else
  # Ensure sandbox-local dirs exist AND are not symlinks
  mkdir -p "${SANDBOX_HOME}/.gemini" "${SANDBOX_HOME}/Library/Application Support"
  ensure_not_symlink "${SB_GEMINI_ANTI}"
  ensure_not_symlink "${SB_GEMINI_BROWSER}"
  ensure_not_symlink "${SB_ANTIGRAVITY_DIR}"
  ensure_not_symlink "${SB_APP_SUPPORT}"
fi

# Common dirs
mkdir -p \
  "${SANDBOX_HOME}/Library/Caches" \
  "${SANDBOX_HOME}/Library/Logs" \
  "${SANDBOX_HOME}/Library/Preferences" \
  "${SANDBOX_HOME}/.config" \
  "${SANDBOX_HOME}/.cache" \
  "${SANDBOX_HOME}/.local/share"

# ---- Write a conservative SBPL profile
cat > "${PROFILE}" <<'SBPL'
(version 1)
(debug deny)
(deny default)

(import "/System/Library/Sandbox/Profiles/bsd.sb")

;; Core
(allow process*)
(allow network*)
(allow mach*)
(allow ipc-posix*)
(allow sysctl-read)
(allow iokit-open)

;; Allow the app to manage/terminate its own helper processes (ptyHost/fileWatcher)
(allow signal (target self))
(allow signal (target pgrp))

;; JIT + dyld mappings
(if (defined? `dynamic-code-generation) (allow dynamic-code-generation))

;; Allow mapping executables from system + app + Homebrew (terminal shells often live here)
(if (defined? `file-map-executable)
  (allow file-map-executable
    (subpath "/System")
    (subpath "/usr")
    (subpath "/bin")
    (subpath "/sbin")
    (subpath "/Library")
    (subpath "/Applications")
    (subpath "/usr/local")
    (subpath "/opt/homebrew")
    (subpath (param "APP_BUNDLE"))
  )
)

;; Open URLs in default browser (OAuth)
(if (defined? `lsopen) (allow lsopen))

;; Preferences are commonly queried (UI/display/accessibility)
(if (defined? `user-preference-read) (allow user-preference-read))
(if (defined? `user-preference-write) (allow user-preference-write))

;; Some apps probe HID/accessibility; allow if op exists
(if (defined? `hid-control) (allow hid-control))

;; Read system + app bundle (+ Homebrew)
(allow file-read* file-read-metadata
  (subpath "/System")
  (subpath "/usr")
  (subpath "/bin")
  (subpath "/sbin")
  (subpath "/Library")
  (subpath "/Applications")
  (subpath "/private")
  (subpath "/usr/local")
  (subpath "/opt/homebrew")
  (subpath (param "APP_BUNDLE"))
)

;; IMPORTANT for integrated terminal: allow PTY/device nodes + ioctls
(allow file-read* file-write* file-read-metadata
  (subpath "/dev")
)
(if (defined? `file-ioctl)
  (allow file-ioctl (subpath "/dev"))
)

;; Safety: block raw disk writes (prevents "wipe disk" via /dev/disk* devices)
(deny file-write* (regex #"^/dev/(r?disk[0-9].*)$"))

;; Writable areas
(allow file-read* file-write* file-read-metadata
  (subpath (param "SANDBOX_HOME"))
  (subpath (param "WORKDIR1"))
  (subpath (param "WORKDIR2"))
  (subpath (param "ALLOW_GEMINI_ANTI"))
  (subpath (param "ALLOW_GEMINI_BROWSER"))
  (subpath (param "ALLOW_ANTIGRAVITY_DIR"))
  (subpath (param "ALLOW_APP_SUPPORT"))
  (subpath "/private/tmp")
  (subpath "/private/var/tmp")
  (subpath "/private/var/folders")
)
SBPL

# ---- Environment inside sandbox
export HOME="${SANDBOX_HOME}"
export TMPDIR="${TMPROOT}"
export XDG_CONFIG_HOME="${SANDBOX_HOME}/.config"
export XDG_CACHE_HOME="${SANDBOX_HOME}/.cache"
export XDG_DATA_HOME="${SANDBOX_HOME}/.local/share"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
export SHELL="${SANDBOX_SHELL}"

# Start from an allowed cwd
cd "${SANDBOX_HOME}"

# ---- Electron/Chromium flags (avoid nested sandbox failures)
EXTRA_ARGS=()
if [ "${DISABLE_CHROMIUM_SANDBOX}" = "1" ] || [ "${DISABLE_CHROMIUM_SANDBOX}" = "true" ]; then
  EXTRA_ARGS+=( "--no-sandbox" "--disable-gpu-sandbox" "--disable-features=NetworkServiceSandbox" )
fi
if [ "${DISABLE_GPU}" = "1" ] || [ "${DISABLE_GPU}" = "true" ]; then
  EXTRA_ARGS+=( "--disable-gpu" )
fi

# ---- Run (don’t exec; so we can print useful info if it crashes)
set +e
/usr/bin/sandbox-exec -f "${PROFILE}" \
  -D "SANDBOX_HOME=${SANDBOX_HOME}" \
  -D "WORKDIR1=${WORKDIR1}" \
  -D "WORKDIR2=${WORKDIR2}" \
  -D "APP_BUNDLE=${APP_BUNDLE}" \
  -D "ALLOW_GEMINI_ANTI=${ALLOW_GEMINI_ANTI}" \
  -D "ALLOW_GEMINI_BROWSER=${ALLOW_GEMINI_BROWSER}" \
  -D "ALLOW_ANTIGRAVITY_DIR=${ALLOW_ANTIGRAVITY_DIR}" \
  -D "ALLOW_APP_SUPPORT=${ALLOW_APP_SUPPORT}" \
  "${APP}" "${EXTRA_ARGS[@]}" "$@"
RC=$?
set -e

if [ "${RC}" -ne 0 ]; then
  echo "Antigravity exited non-zero (rc=${RC})."
  echo "Recent crash reports (if any):"
  ls -t "${REAL_HOME}/Library/Logs/DiagnosticReports/"*Electron*.crash 2>/dev/null | head -n 3 || true
  ls -t "${REAL_HOME}/Library/Logs/DiagnosticReports/"*sandbox-exec*.crash 2>/dev/null | head -n 3 || true
fi

exit "${RC}"
