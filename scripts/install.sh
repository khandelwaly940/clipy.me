#!/bin/bash
# ClipyMe installer/updater for macOS 13+. MIT license; see LICENSE.
# Uses only macOS tools plus the verification helpers included in the release.
set -euo pipefail
umask 077
repo='khandelwaly940/clipy.me'
archive=''
checksum_file=''
verify_only=0
source_kind=auto
source_db=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive) archive="$2"; shift 2 ;;
    --checksum) checksum_file="$2"; shift 2 ;;
    --source) source_kind="${2:?Source required}"; shift 2 ;;
    --source-db) source_db="${2:?Database path required}"; shift 2 ;;
    --verify-only) verify_only=1; shift ;;
    --help) echo 'Usage: install.sh [--archive ZIP --checksum SHA256_FILE] [--verify-only] [--source auto|clipy|copyclip|copyclip2|fresh] [--source-db PATH]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
fail() { echo "ClipyMe: $*" >&2; exit 1; }
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'This installer requires macOS.'
major=$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)
[ "$major" -ge 13 ] || fail 'ClipyMe requires macOS 13 or newer.'
work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/clipyme-install.XXXXXXXX")
backup=''
old_app=''
staged_app=''
new_data=0
swapped=0
success=0
original_running=0
custom_running=0
original_id='com.clipy-app.Clipy'
source_running=0
source_process=''
source_app=''
copyclip_import=0
custom_id='local.clipyme.app'
support="$HOME/Library/Application Support/$custom_id"
app_dir='/Applications'
if [ -d "$HOME/Applications/ClipyMe.app" ] || [ ! -w "$app_dir" ]; then app_dir="$HOME/Applications"; fi
app="$app_dir/ClipyMe.app"
original='/Applications/Clipy.app'
[ ! -d "$HOME/Applications/Clipy.app" ] || original="$HOME/Applications/Clipy.app"
cleanup() {
  status=$?
  trap - EXIT
  if [ "$success" -ne 1 ]; then
    if [ "$swapped" -eq 1 ]; then
      /usr/bin/pkill -TERM -x ClipyMe 2>/dev/null || true
      for attempt in 1 2 3 4 5; do
        if ! /usr/bin/pgrep -x ClipyMe >/dev/null; then break; fi
        /bin/sleep 1
      done
      if /usr/bin/pgrep -x ClipyMe >/dev/null; then
        echo "Could not stop the failed new app. Backup retained at: $backup; close it before restoring." >&2
        exit 1
      fi
      if [ "$new_data" -eq 0 ] && [ -d "$backup/Application Support" ]; then
        /bin/mv "$support" "$backup/failed-upgrade-data"
        "$verify" copy-tree "$backup/Application Support" "$support"
        /usr/bin/defaults export "$custom_id" "$backup/failed-upgrade-preferences.plist" || true
        /usr/bin/defaults import "$custom_id" "$backup/preferences.plist"
      fi
      if [ -d "$app" ]; then /bin/mv "$app" "$work/failed-app"; fi
      if [ -n "$old_app" ] && [ -d "$old_app" ]; then /bin/mv "$old_app" "$app"; fi
    fi
    if [ "$new_data" -eq 1 ]; then
      /bin/mv "$support" "$backup/failed-migration-data" 2>/dev/null || true
      /usr/bin/defaults delete "$custom_id" >/dev/null 2>&1 || true
    fi
    if [ "$source_running" -eq 1 ] && [ -d "$source_app" ]; then /usr/bin/open "$source_app" || true; fi
    if [ "$original_running" -eq 1 ]; then /usr/bin/open "$original" || true; fi
    if [ "$custom_running" -eq 1 ] && [ -d "$app" ]; then /usr/bin/open "$app" || true; fi
    if [ -n "$backup" ]; then echo "Backup retained at: $backup" >&2; fi
  fi
  if [ -n "$staged_app" ] && [ -d "$staged_app" ]; then /bin/rm -rf "$staged_app"; fi
  /bin/rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if [ -z "$archive" ]; then
  echo 'Downloading the latest ClipyMe release…'
  archive="$work/ClipyMe-macos-universal.zip"
  checksum_file="$work/ClipyMe-macos-universal.zip.sha256"
  # Resolve once, then pin both files to the same release. This also avoids
  # stale/slow latest-download redirects and mixed-version checksum races.
  latest_url=$(/usr/bin/curl --fail --silent --show-error --head --location --retry 2 --connect-timeout 15 --max-time 60 --proto '=https' --tlsv1.2 -o /dev/null --write-out '%{url_effective}' "https://github.com/$repo/releases/latest")
  tag="${latest_url#https://github.com/$repo/releases/tag/}"
  [[ "$tag" =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]] || fail 'Could not resolve the latest stable release.'
  base="https://github.com/$repo/releases/download/$tag"
  /usr/bin/curl --fail --location --retry 2 --connect-timeout 15 --max-time 300 --speed-time 30 --speed-limit 1024 --proto '=https' --tlsv1.2 "$base/ClipyMe-macos-universal.zip" -o "$archive"
  /usr/bin/curl --fail --location --retry 2 --connect-timeout 15 --max-time 300 --speed-time 30 --speed-limit 1024 --proto '=https' --tlsv1.2 "$base/ClipyMe-macos-universal.zip.sha256" -o "$checksum_file"
fi
[ -f "$archive" ] && [ -f "$checksum_file" ] || fail 'Archive and checksum file are required.'
expected=$(/usr/bin/awk 'NR==1 {print $1}' "$checksum_file")
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || fail 'Invalid release checksum.'
actual=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
[ "$actual" = "$expected" ] || fail 'Download checksum mismatch. No apps or data were changed.'
/usr/bin/ditto -x -k "$archive" "$work/release"
candidate="$work/release/ClipyMe.app"
verify="$work/release/ClipyMeVerify"
login="$work/release/ClipyMeLogin"
[ -x "$verify" ] && [ -x "$login" ] || fail 'Release is missing migration helpers.'
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$candidate/Contents/Info.plist")" = "$custom_id" ] || fail 'Unexpected app identity.'
/usr/bin/codesign --verify --deep --strict "$candidate"
/usr/bin/codesign --verify --strict "$verify"
/usr/bin/codesign --verify --strict "$login"
if [ "$verify_only" -eq 1 ]; then
  echo 'Release checksum, app identity, and signatures verified. Nothing installed.'
  success=1; exit 0
fi
# A per-user signing key makes Accessibility approval survive future updates.
identity='ClipyMe Local Signing'
keychain="$HOME/Library/Keychains/login.keychain-db"
if ! /usr/bin/security find-certificate -c "$identity" -p "$keychain" > "$work/cert.pem" 2>/dev/null; then
  cat > "$work/cert.cnf" <<'CERT'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=ClipyMe Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
CERT
  /usr/bin/openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2> "$work/openssl.log"
  export CLIPYME_CERT_PASSWORD
  CLIPYME_CERT_PASSWORD=$(/usr/bin/openssl rand -hex 32)
  /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/identity.p12" -passout env:CLIPYME_CERT_PASSWORD
  /usr/bin/security import "$work/identity.p12" -k "$keychain" -P "$CLIPYME_CERT_PASSWORD" -T /usr/bin/codesign >/dev/null
  unset CLIPYME_CERT_PASSWORD
fi
/usr/bin/codesign --force --sign "$identity" --timestamp=none "$candidate"
/usr/bin/codesign --verify --deep --strict "$candidate"
if [ -d "$app" ]; then
  installed_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
  release_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$candidate/Contents/Info.plist")
  if /usr/bin/awk -v old="$installed_version" -v new="$release_version" 'BEGIN {split(old,a,"."); split(new,b,"."); for(i=1;i<=4;i++) {if(b[i]+0<a[i]+0) exit 0; if(b[i]+0>a[i]+0) exit 1} exit 1}'; then
    fail "Installed version $installed_version is newer than release $release_version. Downgrade refused."
  fi
fi
case "$source_kind" in auto|clipy|copyclip|copyclip2|fresh) ;; *) fail 'Invalid --source value.' ;; esac
if [ -n "$source_db" ]; then
  case "$source_kind" in copyclip|copyclip2) ;; *) fail '--source-db requires --source copyclip or copyclip2.' ;; esac
fi
source_id="$original_id"
source_app="$original"
if [ -d "$support" ]; then
  [ "$source_kind" = auto ] || fail 'ClipyMe already has data. Run without --source to update; importing over existing history is refused.'
  source_id="$custom_id"; source_app="$app"
else
  if /usr/bin/defaults read "$custom_id" >/dev/null 2>&1; then
    fail 'ClipyMe preferences already exist without its data folder. Resolve the incomplete installation before migrating.'
  fi
  if [ "$source_kind" = auto ]; then
    sources=()
    if [ -d "$HOME/Library/Application Support/$original_id" ]; then sources+=(clipy); fi
    for pair in 'copyclip:com.fiplab.clipboard' 'copyclip2:com.fiplab.copyclip2'; do
      kind="${pair%%:*}"; bundle="${pair#*:}"
      if [ -d "$HOME/Library/Containers/$bundle" ] || [ -d "$HOME/Library/Application Support/$bundle" ] ||
         { [ "$kind" = copyclip2 ] && [ -d "$HOME/Library/Application Support/CopyClip 2" ]; } ||
         { [ "$kind" = copyclip ] && [ -d "$HOME/Library/Application Support/CopyClip" ]; }; then
        sources+=("$kind")
      fi
    done
    case "${#sources[@]}" in
      0) source_kind=fresh ;;
      1) source_kind="${sources[0]}" ;;
      *) fail 'Multiple clipboard histories found. Choose --source clipy, copyclip, or copyclip2. Nothing was replaced.' ;;
    esac
  fi
  case "$source_kind" in
    copyclip|copyclip2)
      copyclip_import=1
      [ "$(/usr/libexec/PlistBuddy -c 'Print ClipyMeCopyClipImportVersion' "$candidate/Contents/Info.plist" 2>/dev/null || true)" = 1 ] || fail 'This release does not support CopyClip import. Retry after ClipyMe 1.3.3 or newer is available.'
      if [ "$source_kind" = copyclip ]; then source_id='com.fiplab.clipboard'; source_process=CopyClip
      else source_id='com.fiplab.copyclip2'; source_process='CopyClip 2'; fi
      source_app="/Applications/$source_process.app"
      [ ! -d "$HOME/Applications/$source_process.app" ] || source_app="$HOME/Applications/$source_process.app"
      if [ -z "$source_db" ]; then
        candidates=()
        for root in "$HOME/Library/Containers/$source_id/Data/Library/Application Support" \
                    "$HOME/Library/Application Support/$source_id" "$HOME/Library/Application Support/$source_process"; do
          if [ -d "$root" ]; then
            while IFS= read -r database; do [ -z "$database" ] || candidates+=("$database"); done < <("$verify" locate-copyclip "$root")
          fi
        done
        [ "${#candidates[@]}" -eq 1 ] || fail 'Could not identify one readable CopyClip database. Use --source-db PATH; macOS may require access to its app container.'
        source_db="${candidates[0]}"
      fi
      [ -f "$source_db" ] && [ ! -L "$source_db" ] || fail 'CopyClip database must be a regular file, not a symbolic link.'
      source_support="$(cd "$(/usr/bin/dirname "$source_db")" && /bin/pwd -P)"
      ;;
    fresh) source_id='local.clipyme.fresh'; source_app=''; source_support="$work/empty-source" ;;
    clipy)
      [ -d "$HOME/Library/Application Support/$original_id" ] || fail 'No Clipy data found.'
      ;;
  esac
fi
if [ "$copyclip_import" -eq 0 ] && [ "$source_kind" != fresh ]; then
  source_support="$HOME/Library/Application Support/$source_id"
fi
if [ "$source_id" = "$original_id" ] && [ -d "$original" ]; then
  version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$original/Contents/Info.plist")
  case "$version" in 1.2.*|1.3.0) ;; *) fail "Clipy $version is not yet supported for migration. Original installation was not changed." ;; esac
fi
if /usr/bin/pgrep -x Clipy >/dev/null; then original_running=1; fi
if /usr/bin/pgrep -x ClipyMe >/dev/null; then custom_running=1; fi
quit_app() {
  local bundle="$1" process="$2" pid count=0
  if ! /usr/bin/pgrep -x "$process" >/dev/null; then return; fi
  /usr/bin/osascript -e "tell application id \"$bundle\" to quit" >/dev/null 2>&1 &
  pid=$!
  while /usr/bin/pgrep -x "$process" >/dev/null && [ "$count" -lt 10 ]; do /bin/sleep 1; count=$((count+1)); done
  if /usr/bin/pgrep -x "$process" >/dev/null; then
    kill "$pid" 2>/dev/null || true
    fail "Please close $process (including open dialogs) and run the installer again."
  fi
  wait "$pid" || true
}
if [ "$copyclip_import" -eq 1 ]; then
  if /usr/bin/pgrep -x "$source_process" >/dev/null; then source_running=1; fi
  quit_app "$source_id" "$source_process"
fi
quit_app "$original_id" Clipy
quit_app "$custom_id" ClipyMe
backup_root="$HOME/Library/Application Support/ClipyMe Backups"
/bin/mkdir -p "$backup_root"
backup="$backup_root/install-$(/bin/date -u +%Y%m%d-%H%M%S)-$$"
/bin/mkdir -m 700 "$backup"
if [ -d "$source_support" ]; then "$verify" copy-tree "$source_support" "$backup/Application Support"; fi
for name in Caches 'Saved Application State'; do
  source="$HOME/Library/$name/$source_id"
  if [ "$name" = 'Saved Application State' ]; then source="$source.savedState"; fi
  if [ -d "$source" ]; then "$verify" copy-tree "$source" "$backup/$name"; fi
done
if [ -d "$HOME/Library/Application Support/Clipy" ]; then "$verify" copy-tree "$HOME/Library/Application Support/Clipy" "$backup/Legacy Support"; fi
if [ -d "$source_app" ]; then /usr/bin/ditto "$source_app" "$backup/Previous.app"; fi
container_prefs="$HOME/Library/Containers/$source_id/Data/Library/Preferences/$source_id.plist"
if [ "$copyclip_import" -eq 1 ] && [ -f "$container_prefs" ]; then
  /bin/cp "$container_prefs" "$backup/preferences.plist"
elif ! /usr/bin/defaults export "$source_id" "$backup/preferences.plist" >/dev/null 2>&1; then
  /usr/bin/plutil -create xml1 "$backup/preferences.plist"
fi
if [ "$copyclip_import" -eq 0 ] && [ -f "$backup/Application Support/sqlite.db" ]; then
  "$verify" compare-db "$source_support/sqlite.db" "$backup/Application Support/sqlite.db"
fi
if [ "$copyclip_import" -eq 1 ]; then
  "$verify" compare-copyclip-db "$source_db" "$backup/Application Support/$(/usr/bin/basename "$source_db")"
fi
"$verify" manifest "$backup"
"$verify" verify-manifest "$backup"
if [ ! -d "$support" ]; then
  stage="$work/staged-support"
  install_prefs="$backup/preferences.plist"
  if [ "$copyclip_import" -eq 1 ]; then
    "$candidate/Contents/MacOS/ClipyMe" --clipyme-import-copyclip \
      "$backup/Application Support/$(/usr/bin/basename "$source_db")" "$stage" "$backup/preferences.plist"
    install_prefs="$stage/imported-preferences.plist"
    /bin/cp "$install_prefs" "$work/imported-preferences.plist"
    install_prefs="$work/imported-preferences.plist"
    /bin/rm "$stage/imported-preferences.plist"
    "$verify" compare-db "$stage/sqlite.db" "$stage/sqlite.db"
  elif [ -d "$backup/Application Support" ]; then
    "$verify" copy-tree "$backup/Application Support" "$stage"
  else /bin/mkdir "$stage"; fi
  if [ "$copyclip_import" -eq 0 ] && [ -f "$stage/sqlite.db" ]; then "$verify" compare-db "$backup/Application Support/sqlite.db" "$stage/sqlite.db"; fi
  /bin/mkdir -p "$(/usr/bin/dirname "$support")"
  /bin/mv "$stage" "$support"
  new_data=1
  /usr/bin/defaults import "$custom_id" "$install_prefs"
  /usr/bin/defaults export "$custom_id" "$work/preferences.plist"
  "$verify" compare-plists "$install_prefs" "$work/preferences.plist"
fi
/bin/mkdir -p "$app_dir"
# Stage on the destination volume before swapping bundles.
staged_app="$app_dir/.ClipyMe-install-$$.app"
/usr/bin/ditto "$candidate" "$staged_app"
if [ -d "$app" ]; then old_app="$app_dir/.ClipyMe-previous-$$.app"; /bin/mv "$app" "$old_app"; fi
swapped=1
/bin/mv "$staged_app" "$app"
/usr/bin/open "$app"
healthy=0
for count in $(/usr/bin/jot 90); do
  if /usr/bin/pgrep -x ClipyMe >/dev/null && [ -f "$support/sqlite.db" ]; then
    if [ "$(/usr/bin/sqlite3 -readonly "$support/sqlite.db" "SELECT count(*) FROM grdb_migrations WHERE identifier='ClipyMe full text and favorites';" 2>/dev/null || true)" = 1 ]; then healthy=1; break; fi
  fi
  /bin/sleep 1
done
[ "$healthy" -eq 1 ] || fail 'App launch/migration did not complete. Restoring the previous installation.'
enabled=$(/usr/bin/defaults read "$custom_id" loginItem 2>/dev/null || echo 0)
login_source="${source_app:-$original}"
[ "$source_id" != "$custom_id" ] || login_source="$original"
"$login" --switch "$login_source" "$app" "$enabled"
success=1
if [ -n "$old_app" ] && [ -d "$old_app" ]; then /bin/rm -rf "$old_app"; fi
printf '\nInstalled ClipyMe %s\nBackup: %s\n' "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" "$backup"
echo 'On first installation, enable this ClipyMe app in System Settings → Privacy & Security → Accessibility to paste automatically.'
if [ "$copyclip_import" -eq 1 ]; then
  echo 'CopyClip data remains untouched. Its shortcuts, themes and unsupported settings are retained in the backup, not applied to ClipyMe.'
  echo 'If CopyClip uses a separate login helper, turn off Start at Login in CopyClip before restarting your Mac.'
fi
echo 'Run the same installer to update. Original apps and their data remain available; run only one clipboard monitor at a time.'
