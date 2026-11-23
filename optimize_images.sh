#!/usr/bin/env bash
# Recursively optimize JPEG/PNG files larger than the specified threshold.
# Preview by default. Requires an external backup directory for --apply.
set -uo pipefail

usage() {
  cat <<'HELP'
Usage:
  optimize_images.sh DIRECTORY [--min-kb 1024]
  optimize_images.sh DIRECTORY --apply --backup-dir /path/outside/DIRECTORY [--min-kb 1024] [--quality 85]

Default: preview only; no changes.
JPG/JPEG: jpegoptim (lossy, quality cap, preserve metadata).
PNG: optipng (lossless).
HELP
}

if (( $# < 1 )); then usage >&2; exit 2; fi
ROOT=$1; shift
APPLY=0
MIN_KB=1024
QUALITY=85
BACKUP=''
while (( $# )); do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --backup-dir) (( $# >= 2 )) || { echo 'Missing --backup-dir argument' >&2; exit 2; }; BACKUP=$2; shift 2 ;;
    --min-kb) (( $# >= 2 )) || exit 2; MIN_KB=$2; shift 2 ;;
    --quality) (( $# >= 2 )) || exit 2; QUALITY=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -d "$ROOT" && -r "$ROOT" ]] || { echo "Cannot read directory: $ROOT" >&2; exit 1; }
[[ $MIN_KB =~ ^[0-9]+$ && $QUALITY =~ ^[0-9]+$ ]] || { echo 'Expected numeric min-kb / quality' >&2; exit 2; }
(( QUALITY >= 1 && QUALITY <= 100 && MIN_KB > 0 && MIN_KB <= 1000000000 )) || { echo 'Invalid range' >&2; exit 2; }
ROOT=$(cd -- "$ROOT" && pwd -P) || exit 1
if (( APPLY )); then
  [[ -n "$BACKUP" ]] || { echo 'For --apply, --backup-dir is required' >&2; exit 2; }
  command -v jpegoptim >/dev/null || { echo 'Install jpegoptim first' >&2; exit 1; }
  command -v optipng >/dev/null || { echo 'Install optipng first' >&2; exit 1; }
  mkdir -p -- "$BACKUP" || exit 1
  BACKUP=$(cd -- "$BACKUP" && pwd -P) || exit 1
  case "$BACKUP/" in "$ROOT/"*) echo 'Backup directory must be outside source' >&2; exit 2;; esac
  [[ "$BACKUP" != "$ROOT" ]] || { echo 'Backup directory must differ from source' >&2; exit 2; }
fi

count=0; changed=0; skipped=0; failed=0; saved=0
while IFS= read -r -d '' file; do
  ((count+=1))
  before=$(stat -c %s -- "$file") || { ((failed+=1)); continue; }
  if (( ! APPLY )); then
    printf '[PREVIEW] %s (%.2f MiB)\n' "$file" "$(awk -v n="$before" 'BEGIN{print n/1048576}')"
    continue
  fi
  relative=${file#"$ROOT"/}
  target="$BACKUP/$relative"
  if [[ -e "$target" || -L "$target" ]]; then
    printf '[SKIP backup exists] %s\n' "$file" >&2
    ((skipped+=1)); continue
  fi
  # Temporary file in same directory for atomic replacement.
  ext=${file##*.}
  tmp=$(mktemp "${file}.optimize.XXXXXXXX.${ext}") || { ((failed+=1)); continue; }
  if ! cp -- "$file" "$tmp"; then rm -f -- "$tmp"; ((failed+=1)); continue; fi
  case "${ext,,}" in
    jpg|jpeg) jpegoptim --max="$QUALITY" --strip-none --quiet -- "$tmp" >/dev/null 2>&1; status=$? ;;
    png) optipng -o2 -quiet -- "$tmp" >/dev/null 2>&1; status=$? ;;
  esac
  if (( status != 0 )); then
    printf '[ERROR optimizer] %s\n' "$file" >&2
    rm -f -- "$tmp"; ((failed+=1)); continue
  fi
  after=$(stat -c %s -- "$tmp") || { rm -f -- "$tmp"; ((failed+=1)); continue; }
  if (( after >= before )); then
    printf '[UNCHANGED] %s\n' "$file"
    rm -f -- "$tmp"; ((skipped+=1)); continue
  fi
  if ! mkdir -p -- "$(dirname -- "$target")" || ! cp -p -- "$file" "$target"; then
    printf '[ERROR backup] %s\n' "$file" >&2
    rm -f -- "$tmp"; ((failed+=1)); continue
  fi
  chmod --reference="$file" -- "$tmp" || { rm -f -- "$tmp"; ((failed+=1)); continue; }
  if [[ $(id -u) == 0 ]]; then
    chown --reference="$file" -- "$tmp" || { rm -f -- "$tmp"; ((failed+=1)); continue; }
  fi
  touch -r "$file" "$tmp" || { rm -f -- "$tmp"; ((failed+=1)); continue; }
  if mv -f -- "$tmp" "$file"; then
    ((changed+=1)); ((saved+=before-after))
    printf '[OK] saved %d bytes: %s\n' "$((before-after))" "$file"
  else
    rm -f -- "$tmp"; ((failed+=1))
  fi
done < <(find "$ROOT" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) -size +"$((MIN_KB*1024))"c -print0)

printf '\nScanned: %d | Optimized: %d | Skipped: %d | Errors: %d | Saved: %.2f MiB\n' \
  "$count" "$changed" "$skipped" "$failed" "$(awk -v n="$saved" 'BEGIN{print n/1048576}')"
(( failed == 0 ))
