#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh
destination="$HOME/Applications/TranslateBar.app"
mkdir -p "$HOME/Applications"
staging="$(mktemp -d "$HOME/Applications/.TranslateBar-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto build/TranslateBar.app "$staging/TranslateBar.app"
/usr/bin/codesign --verify --strict "$staging/TranslateBar.app"

# Normal termination waits for the app's cancellation/clipboard cleanup path.
# Never force-kill an operation that might own the clipboard.
if /usr/bin/pgrep -x TranslateBar >/dev/null; then
  # Address the installed path so updates also work when the bundle ID changes.
  /usr/bin/osascript - "$destination" <<'APPLESCRIPT'
on run arguments
  tell application (item 1 of arguments) to quit
end run
APPLESCRIPT
fi
for ((attempt=0; attempt<100; attempt++)); do
  if ! /usr/bin/pgrep -x TranslateBar >/dev/null; then break; fi
  /bin/sleep 0.2
done
if /usr/bin/pgrep -x TranslateBar >/dev/null; then
  printf 'TranslateBar is still cleaning up. Wait for it to quit, then rerun install.sh.\n' >&2
  exit 1
fi
if [[ -e "$destination" ]]; then
  mv "$destination" "$staging/Previous.app"
fi
if ! mv "$staging/TranslateBar.app" "$destination"; then
  if [[ -e "$staging/Previous.app" ]]; then mv "$staging/Previous.app" "$destination"; fi
  exit 1
fi
/usr/bin/codesign --verify --strict "$destination"
/usr/bin/codesign -d -r- "$destination" 2>&1

# LaunchServices attributes permission checks to the installed app. Diagnostics
# print only OS/permission/model metadata and never inspect the clipboard.
/usr/bin/open -n -g -W --stdout "$staging/diagnostics.txt" --stderr "$staging/diagnostics-errors.txt" \
  "$destination" --args --diagnostics
cat "$staging/diagnostics.txt"
cat "$staging/diagnostics-errors.txt" >&2
/usr/bin/open -g "$destination"
printf 'Installed and launched %s\n' "$destination"
