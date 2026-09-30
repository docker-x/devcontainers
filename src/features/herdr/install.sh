#!/bin/bash
set -e

# Herdr Feature — install script
# Downloads the pre-built Herdr binary from GitHub releases with SHA-256
# verification.  Herdr is a Rust binary; the npm "herdr" package is just a
# name placeholder and is NOT used.

VERSION=${VERSION:-"latest"}

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
REMOTE_USER_HOME="${REMOTE_USER_HOME:-/home/vscode}"
AGENT_DIR="${AGENT_CONFIG_DIR:-/usr/local/share/agent-config}/herdr"
SHARE_CONFIG="${SHARECONFIG:-false}"

echo "herdr: installing Herdr (version: ${VERSION})..."

# --- Install curl and jq if not present (one consolidated apt pass) ---
# jq is the manifest parser — installsAfter only orders features, it does
# not guarantee node is installed, so a parser this script can install
# itself is required.
PKG_MISSING=()
command -v curl >/dev/null 2>&1 || PKG_MISSING+=(curl)
command -v jq   >/dev/null 2>&1 || PKG_MISSING+=(jq)
if ((${#PKG_MISSING[@]})); then
    apt-get update -y && apt-get install -y "${PKG_MISSING[@]}" && rm -rf /var/lib/apt/lists/*
fi

# --- Select architecture-appropriate release asset ---
HERDR_ARCH="$(uname -m)"
case "$HERDR_ARCH" in
    x86_64|amd64)   HERDR_TARGET="linux-x86_64" ;;
    aarch64|arm64)  HERDR_TARGET="linux-aarch64" ;;
    *)              echo "herdr: unsupported architecture $HERDR_ARCH for pre-built binary" >&2; exit 1 ;;
esac

# --- Resolve version, asset URL and SHA-256 from ONE manifest fetch ---
# latest.json carries every published release under releases.<v>
# (assets + sha256) — a second endpoint is not needed and the legacy
# releases.json fallback only ever served the site's HTML anyway.
# jq replaces awk field math that breaks on minified JSON or reordered
# keys. --proto/--proto-redir '=https' block HTTP redirect hijacking
# (CWE-494) — --proto alone would not cover redirect targets.
MANIFEST="$(curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 \
    --connect-timeout 10 --max-time 20 https://herdr.dev/latest.json)" \
    || { echo "Error: failed to fetch Herdr release manifest" >&2; exit 1; }

# The manifest supplies version + checksum only — the download URL is
# constructed from the pinned GitHub release origin below so an altered
# manifest cannot redirect the fetch to an arbitrary host.
RESOLVED="$(jq -r --arg v "$VERSION" --arg t "$HERDR_TARGET" '
    ($v | sub("^v"; "")) as $want
    | (if $want == "latest" or $want == "" then .version else $want end) as $ver
    | .releases[$ver] as $rel
    | if ($rel and $rel.sha256[$t])
      then [$ver, $rel.sha256[$t]] | join("\t")
      else error("release \($ver) has no \($t) checksum in the manifest")
      end' <<< "$MANIFEST")" \
    || { echo "Error: could not resolve Herdr ${VERSION} for ${HERDR_TARGET}" >&2; exit 1; }
IFS=$'\t' read -r VERSION HERDR_SHA256 <<< "$RESOLVED"

# Fail closed: a missing or malformed checksum means no install at all —
# an unverified binary is never acceptable (CWE-494).
if [[ -z "$VERSION" || -z "$HERDR_SHA256" || ${#HERDR_SHA256} -ne 64 ]]; then
    echo "Error: could not resolve SHA-256 for Herdr ${VERSION} (${HERDR_TARGET}) — refusing to install unverified" >&2
    exit 1
fi
RELEASE_TAG="v${VERSION}"
HERDR_URL="https://github.com/herdrdev/herdr/releases/download/${RELEASE_TAG}/herdr-${HERDR_TARGET}"
echo "herdr: resolved ${RELEASE_TAG} for ${HERDR_TARGET}"

# --- Download to a mktemp directory (CWE-377) ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "herdr: downloading ${RELEASE_TAG} for ${HERDR_TARGET}..."
if ! curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 10 --max-time 120 "$HERDR_URL" -o "${TMPDIR}/herdr"; then
    echo "Error: failed to download Herdr binary from ${HERDR_URL}" >&2
    exit 1
fi

# --- Verify SHA-256 (CWE-494) — mandatory, never skipped ---
if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_SHA256="$(sha256sum < "${TMPDIR}/herdr" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL_SHA256="$(shasum -a 256 < "${TMPDIR}/herdr" | awk '{ print $1 }')"
elif command -v openssl >/dev/null 2>&1; then
    ACTUAL_SHA256="$(openssl dgst -sha256 < "${TMPDIR}/herdr" | awk '{ print $NF }')"
else
    echo "Error: no SHA-256 tool available — cannot verify the download" >&2
    exit 1
fi
if [[ "$ACTUAL_SHA256" != "$HERDR_SHA256" ]]; then
    echo "Error: Herdr checksum mismatch (expected ${HERDR_SHA256}, got ${ACTUAL_SHA256})" >&2
    exit 1
fi
echo "herdr: SHA-256 verified"

# --- Install the binary to /usr/local/bin and user home ---
install -m 755 "${TMPDIR}/herdr" /usr/local/bin/herdr
echo "herdr: installed to /usr/local/bin/herdr"

# Also install to user's .local/bin (may be PVC-backed)
mkdir -p "$REMOTE_USER_HOME/.local/bin"
install -m 755 "${TMPDIR}/herdr" "$REMOTE_USER_HOME/.local/bin/herdr"
# And to /etc/skel/.local/bin for first-boot population
mkdir -p /etc/skel/.local/bin
install -m 755 "${TMPDIR}/herdr" /etc/skel/.local/bin/herdr

# Group permissions for home directory data dirs
chgrp -R 0 "$REMOTE_USER_HOME/.local" 2>/dev/null || true
find "$REMOTE_USER_HOME/.local" -type d -exec chmod g+rwX {} + 2>/dev/null || true

echo "herdr: also installed to $REMOTE_USER_HOME/.local/bin/herdr and /etc/skel/.local/bin/herdr"

# --- Shared agent config ---
if [[ "$SHARE_CONFIG" == "true" ]]; then
    mkdir -p "$AGENT_DIR"
    if id -u "$REMOTE_USER" >/dev/null 2>&1; then
        chown -R "$REMOTE_USER:" "$AGENT_DIR"
    fi

    if [[ -d "$REMOTE_USER_HOME" ]]; then
        for target in "$REMOTE_USER_HOME/.herdr" "$REMOTE_USER_HOME/.config/herdr"; do
            if [[ -e "$target" ]] && [[ ! -L "$target" ]]; then
                mv "$target" "$AGENT_DIR/$(basename "$target")-legacy"
            fi
            parent=$(dirname "$target")
            mkdir -p "$parent"
            rm -f "$target"
            if id -u "$REMOTE_USER" >/dev/null 2>&1; then
                chown "$REMOTE_USER:" "$parent" 2>/dev/null || true
                su -s /bin/bash - "$REMOTE_USER" -c "ln -sfn '$AGENT_DIR' '$target'"
            else
                ln -sfn "$AGENT_DIR" "$target"
            fi
        done
    fi
fi

# Clean up old symlinks from previous always-on shareConfig behavior
if [[ "$SHARE_CONFIG" != "true" ]]; then
    for old_target in "$REMOTE_USER_HOME/.herdr" "$REMOTE_USER_HOME/.config/herdr"; do
        if [[ -L "$old_target" ]]; then
            link_dest=$(readlink "$old_target" 2>/dev/null || true)
            if [[ "$link_dest" == "$AGENT_DIR" ]]; then
                rm -f "$old_target"
            fi
        fi
    done
fi

# --- Verify installation (don't let version-check failures abort the build) ---
set +e
if command -v herdr >/dev/null 2>&1; then
    OUT=$(herdr --version 2>&1)
    RC=$?
    if [[ $RC -eq 0 ]]; then
        echo "herdr: version ${OUT}"
    else
        echo "herdr: version check skipped (exit ${RC})"
    fi
else
    echo "herdr: binary not on PATH; skipping version check"
fi
set -e

echo "herdr: installed successfully!"
