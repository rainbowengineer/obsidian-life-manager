#!/usr/bin/env bash
# vault-sync.sh: sync the shared part of the Obsidian vault into a Claude cloud workspace, safely.
#
# Usage:
#   vault-sync.sh pull  [dir]   download only (pull-only mode). Never changes the remote vault.
#   vault-sync.sh push  [dir]   two-way sync of a pulled copy, after re-checking it.
#   vault-sync.sh audit [dir]   check a local copy contains only what it should.
#   vault-sync.sh clean [dir]   forget the local sync setup, then delete the local copy.
#
# Environment:
#   OBSIDIAN_AUTH_TOKEN      required. Obsidian sign-in token.
#   OBSIDIAN_VAULT_PASSWORD  required for an end-to-end encrypted vault.
#   OBSIDIAN_VAULT           remote vault name (default: RainbowEngineer).
#
# Version 2 (2026-10-11). Written against obsidian-headless 0.0.14, which it installs and requires.
#
# Rules this script enforces:
#   - Sync settings are applied and verified BEFORE the first download.
#   - The folder "Personal" is excluded. Attachment types are limited to "audio", the narrowest
#     setting the client accepts: notes (.md, .canvas, .base) always sync; "unsupported" would let
#     every other file type through; an empty value resets to all media types.
#   - The audit is an allowlist: under Claude/ only .md, .canvas and .base files may exist.
#   - push refuses if any file present at pull time has gone missing (runs never delete notes).
#   - push always switches back to pull-only, even when the sync fails.
#   - A local copy is unlinked first and deleted second; if unlinking fails, nothing is deleted.
#   - clean refuses to delete anything that does not look like a copy made by this script.
#   - Never run `ob logout`: it revokes the token on Obsidian's servers. `ob sync-unlink` is local only.
set -euo pipefail

MODE="${1:-}"
DIR="${2:-$HOME/vault}"
VAULT="${OBSIDIAN_VAULT:-RainbowEngineer}"
SHARED="Claude"
PRIVATE="Personal"
DEVICE="claude-cloud"
CLIENT_VERSION="0.0.14"
FILE_TYPES="audio"

die() { echo "vault-sync: $*" >&2; exit 1; }

# Resolve DIR to an absolute path without requiring it to exist, and refuse dangerous targets.
DIR="$(realpath -m -- "$DIR")"
case "$DIR" in
  /|"$(realpath -m -- "$HOME")"|/root|/home|/tmp|/usr|/etc|/var) die "refusing to use $DIR as the vault copy." ;;
esac
MANIFEST="$DIR.manifest"   # outside the copy, so it is never synced

need_token() {
  [ -n "${OBSIDIAN_AUTH_TOKEN:-}" ] || die "OBSIDIAN_AUTH_TOKEN is not set in this session."
}

ensure_client() {
  if ! command -v ob >/dev/null 2>&1; then
    npm install -g "obsidian-headless@$CLIENT_VERSION" >/dev/null 2>&1 || die "could not install obsidian-headless $CLIENT_VERSION."
  fi
  local v; v="$(ob --version 2>/dev/null || true)"
  [ "$v" = "$CLIENT_VERSION" ] || die "obsidian-headless is $v, expected $CLIENT_VERSION; the safety checks assume that version."
}

# sync-status exits 3 when the folder has no sync configuration, 2 when it is configured but the
# encryption key is missing, 0 when configured. Only 3 means "not configured".
is_configured() {
  local rc=0
  ob sync-status --path "$DIR" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 3 ]
}

# Fail unless the stored settings match what this script expects.
verify_config() {
  local want_mode="$1" json
  json="$(ob sync-config --path "$DIR" --json)" || { echo "vault-sync: could not read sync settings." >&2; return 1; }
  WANT_MODE="$want_mode" PRIVATE="$PRIVATE" FILE_TYPES="$FILE_TYPES" node -e '
    const c = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const errs = [];
    if (c.syncMode !== process.env.WANT_MODE) errs.push(`mode is ${c.syncMode}, expected ${process.env.WANT_MODE}`);
    if (!(c.excludedFolders || []).includes(process.env.PRIVATE)) errs.push(`folder ${process.env.PRIVATE} is not excluded`);
    const ft = c.fileTypes || [];
    if (ft.length !== 1 || ft[0] !== process.env.FILE_TYPES) errs.push(`file types are [${ft.join(", ")}], expected [${process.env.FILE_TYPES}]`);
    if ((c.configs || []).length) errs.push(`config syncing is on: ${c.configs.join(", ")}`);
    if (errs.length) { console.error("vault-sync: settings check failed: " + errs.join("; ")); process.exit(1); }
  ' <<<"$json" || return 1
}

# List synced files (relative paths, sorted), ignoring hidden entries such as .obsidian.
list_files() {
  [ -d "$DIR" ] || return 0
  (cd "$DIR" && find . -path '*/.*' -prune -o -type f -print | sed 's|^\./||' | LC_ALL=C sort)
}

audit() {
  [ -d "$DIR" ] || { echo "vault-sync: no local copy at $DIR." >&2; return 1; }
  local bad=0 extra tmp
  tmp="$(mktemp)"
  extra="$(find "$DIR" -mindepth 1 -maxdepth 1 ! -name "$SHARED" ! -name '.*' -printf '%f\n')"
  if [ -n "$extra" ]; then echo "vault-sync: unexpected top-level entries: $extra" >&2; bad=1; fi
  if [ -e "$DIR/$PRIVATE" ]; then echo "vault-sync: $PRIVATE is present locally" >&2; bad=1; fi
  # Allowlist: anything outside hidden folders that is not a note fails.
  list_files | grep -v -E '\.(md|canvas|base)$' >"$tmp" || true
  if [ -s "$tmp" ]; then
    echo "vault-sync: files other than notes present ($(wc -l <"$tmp") in total):" >&2
    sed -n '1,20p' "$tmp" >&2
    bad=1
  fi
  rm -f "$tmp"
  [ "$bad" -eq 0 ] || return 1
  local n; n="$(list_files | grep -c -E '\.(md|canvas|base)$' || true)"
  echo "vault-sync: audit passed. $n notes under $SHARED/."
  if [ "$n" -eq 0 ]; then echo "vault-sync: note: $SHARED/ is empty or missing." >&2; fi
}

# Refuse to push if anything recorded at pull time has disappeared.
check_no_deletions() {
  [ -f "$MANIFEST" ] || { echo "vault-sync: no record of the pulled files ($MANIFEST); pull again." >&2; return 1; }
  local missing
  missing="$(LC_ALL=C comm -23 "$MANIFEST" <(list_files))"
  if [ -n "$missing" ]; then
    echo "vault-sync: $(printf '%s\n' "$missing" | wc -l) file(s) from the pull are missing; refusing to push:" >&2
    printf '%s\n' "$missing" | sed -n '1,20p' >&2
    return 1
  fi
}

# Only delete something that is a sync folder or holds nothing but Claude/ and hidden entries.
looks_like_copy() {
  [ -d "$DIR" ] || return 0
  is_configured && return 0
  [ -z "$(find "$DIR" -mindepth 1 -maxdepth 1 ! -name "$SHARED" ! -name '.*' -print -quit)" ]
}

clean() {
  looks_like_copy || die "$DIR does not look like a vault copy made by this script; not deleting it."
  if is_configured; then
    ob sync-unlink --path "$DIR" >/dev/null || die "unlink failed; not deleting $DIR."
    is_configured && die "still linked after unlink; not deleting $DIR."
  fi
  rm -rf -- "$DIR"
  rm -f -- "$MANIFEST"
}

restore_pull_only() {
  ob sync-config --path "$DIR" --mode pull-only >/dev/null 2>&1 \
    || echo "vault-sync: WARNING: could not switch back to pull-only; this copy is still two-way. Run 'clean'." >&2
}

case "$MODE" in
  pull)
    need_token; ensure_client
    if is_configured; then die "$DIR is already set up; run 'clean' first for a fresh pull."; fi
    if [ -e "$DIR" ] && [ -n "$(ls -A "$DIR")" ]; then die "$DIR exists and is not empty."; fi
    mkdir -p "$DIR"
    setup_args=(--vault "$VAULT" --path "$DIR" --device-name "$DEVICE" --json)
    # The client has no environment variable or file option for the password; it is passed as an argument.
    if [ -n "${OBSIDIAN_VAULT_PASSWORD:-}" ]; then setup_args+=(--password "$OBSIDIAN_VAULT_PASSWORD"); fi
    ob sync-setup "${setup_args[@]}" >/dev/null || { clean; die "setup failed (wrong vault name, token or password?)."; }
    ob sync-config --path "$DIR" --mode pull-only --excluded-folders "$PRIVATE" \
      --file-types "$FILE_TYPES" --configs "" >/dev/null || { clean; die "could not apply settings."; }
    if ! verify_config pull-only; then clean; exit 1; fi
    ob sync --path "$DIR" || { clean; die "download failed; the local copy was unlinked and deleted."; }
    if ! audit; then clean; die "audit failed; the local copy was unlinked and deleted."; fi
    list_files >"$MANIFEST"
    ;;
  push)
    need_token; ensure_client
    is_configured || die "$DIR is not set up; pull first."
    audit || die "audit failed; refusing to push."
    check_no_deletions || exit 1
    trap restore_pull_only EXIT
    ob sync-config --path "$DIR" --mode bidirectional >/dev/null || die "could not switch to two-way mode."
    verify_config bidirectional || exit 1
    ob sync --path "$DIR" || die "sync failed."
    restore_pull_only
    trap - EXIT
    verify_config pull-only || die "push finished but the copy is not back in pull-only mode. Run 'clean'."
    audit || die "push finished, but files that should not be here arrived during it. Do not push again; run 'clean'."
    list_files >"$MANIFEST"
    echo "vault-sync: push finished."
    ;;
  audit) audit ;;
  clean) clean; echo "vault-sync: local copy removed." ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
