#!/usr/bin/env bash
# Run the FilmCraft unit tests, UI scenario, Photos integration tests and coverage tours on ONE simulator.
#
# Usage: apple/scripts/run-ui-tests.sh <udid|ipad|iphone> [suite...]
#   ipad = iPad Pro 11-inch (M5) 81A653B3-9027-4C16-8335-320CB937C66C, iphone = iPhone 17 FF7E37C5-12E6-483D-8887-D09D18EEB4A4
#   suites (default: all, in this order):
#     unit               FilmCraftTests (swift-testing, hosted in the app)
#     ui                 FilmCraftUITests/FilmCraftUITests (demo launch, dark and light, core actions)
#     photos-authorized  PhotosIntegrationUITests/testAuthorizedBrowseAndInsert  (Photos access granted)
#     photos-denied      PhotosIntegrationUITests/testDeniedState                (access revoked)
#     photos-limited     PhotosIntegrationUITests/testLimitedState               (access reset; the test picks "Select Photos...")
#     photos-export      PhotosIntegrationUITests/testExportToPhotos             (access granted)
#     tools | panels | commands   the coverage tours (ToolTourUITests, PanelTourUITests, CommandTourUITests)
#   or any xcodebuild -only-testing identifier, e.g. FilmCraftUITests/CommandTourUITests/testCommandsPortrait
#
# Needs a built test bundle (this script only runs test-without-building):
#   cd apple && xcodegen generate && xcodebuild build-for-testing -project FilmCraft.xcodeproj -scheme FilmCraft \
#     -destination 'generic/platform=iOS Simulator' ARCHS=arm64 CODE_SIGNING_ALLOWED=NO -derivedDataPath build/dd
#
# Machine-wide simulator lock: waits for /Users/samuelhalle/Code/CraftApps/.sim.lock, boots ONLY the given udid,
# and on exit (trap) shuts it down and releases the lock. It refuses to run when another simulator is booted.
# No screenshots anywhere: results are accessibility assertions, notes, summaries and the app's logs.
# After each suite the *-notes and *-summary attachments are printed, the app log is tailed, and the .xcresult is
# deleted. Tour limits: TEST_RUNNER_TOUR_LIMIT=n, TEST_RUNNER_TOUR_ONLY=id,id (forwarded by xcodebuild).
# Output: apple/build/results/<suite>.log (xcodebuild output), apple/build/results/ids/ (palette/tool/panel id lists).
set -euo pipefail

if [[ $# -lt 1 || "$1" == -h || "$1" == --help ]]; then sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; fi
# Shared devices (never create simulators): "ipad" / "iphone" are shorthands for these UDIDs.
IPAD_UDID=81A653B3-9027-4C16-8335-320CB937C66C     # iPad Pro 11-inch (M5)
IPHONE_UDID=FF7E37C5-12E6-483D-8887-D09D18EEB4A4   # iPhone 17
case "$1" in ipad) UDID="$IPAD_UDID" ;; iphone) UDID="$IPHONE_UDID" ;; *) UDID="$1" ;; esac
shift
SUITES=("$@")
if [[ ${#SUITES[@]} -eq 0 ]]; then
  SUITES=(unit ui photos-authorized photos-denied photos-limited photos-export tools panels commands)
fi
[[ "$UDID" =~ ^[0-9A-Fa-f-]{36}$ ]] || { echo "first argument must be a simulator UDID, ipad or iphone" >&2; exit 2; }

APPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APPLE_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DD=build/dd; OUT=build/results; FIX=build/fixtures
BUNDLE=ca.hologram.filmcraft
RUNNER_BUNDLE=ca.hologram.filmcraft.uitests.xctrunner
LOCK=/Users/samuelhalle/Code/CraftApps/.sim.lock
mkdir -p "$OUT/ids" "$FIX"

# ---- Fixtures (ffmpeg is only a fixture generator) --------------------------------------------------------------
if command -v ffmpeg >/dev/null; then
  [[ -f "$FIX/fc-test.mp4" ]] || ffmpeg -loglevel error -y -f lavfi -i testsrc=size=640x360:rate=24:duration=3 \
    -f lavfi -i sine=frequency=440:duration=3 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$FIX/fc-test.mp4"
  [[ -f "$FIX/fc-test.jpg" ]] || ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=1280x720 -frames:v 1 "$FIX/fc-test.jpg"
else
  echo "warning: ffmpeg not found; Photos fixtures cannot be generated" >&2
fi

# ---- Lock, boot, cleanup ----------------------------------------------------------------------------------------
HAVE_LOCK=0
cleanup() {
  # Leave the shared device clean: remove the app and the UI test runner, then shut down and release the lock.
  xcrun simctl uninstall "$UDID" ca.hologram.filmcraft >/dev/null 2>&1 || true
  xcrun simctl uninstall "$UDID" "$RUNNER_BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  if [[ "$HAVE_LOCK" == 1 ]]; then rm -rf "$LOCK"; HAVE_LOCK=0; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
until mkdir "$LOCK" 2>/dev/null; do sleep 20; done
HAVE_LOCK=1
echo "filmcraft $(date)" > "$LOCK/owner"

OTHERS="$(xcrun simctl list devices booted | grep -E '\(Booted\)' | grep -v "$UDID" || true)"
if [[ -n "$OTHERS" ]]; then
  echo "another simulator is booted; refusing to start a second one:" >&2; echo "$OTHERS" >&2; exit 3
fi
[[ "${FILMCRAFT_QUIT_SIMULATOR:-0}" == 1 ]] && osascript -e 'quit app "Simulator"' >/dev/null 2>&1 || true
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
APP="$DD/Build/Products/Debug-iphonesimulator/FilmCraft.app"
if [[ -d "$APP" ]]; then xcrun simctl install "$UDID" "$APP" || true; fi

# ---- Seed Photos (once per run) ---------------------------------------------------------------------------------
if [[ -f "$FIX/fc-test.mp4" && -f "$FIX/fc-test.jpg" ]]; then
  xcrun simctl addmedia "$UDID" "$FIX/fc-test.jpg" "$FIX/fc-test.mp4"
fi

privacy() { # <grant|revoke|reset>: the app's Photos permission; the UI test runner keeps access (it reads PhotoKit)
  xcrun simctl privacy "$UDID" "$1" photos "$BUNDLE" || true
  xcrun simctl privacy "$UDID" grant photos "$RUNNER_BUNDLE" || true
}

# ---- Printing attachments ---------------------------------------------------------------------------------------
print_attachments() { # <exported dir> <suite>
  python3 -I - "$1" "$2" "$OUT/ids" <<'PY'
import json, os, shutil, sys
d, suite, ids_dir = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    manifest = json.load(open(os.path.join(d, "manifest.json")))
except Exception as e:
    print(f"  (no attachment manifest: {e})"); sys.exit(0)
def walk(o):
    if isinstance(o, dict):
        if "exportedFileName" in o: yield o
        for v in o.values(): yield from walk(v)
    elif isinstance(o, list):
        for v in o: yield from walk(v)
shown = 0
for a in walk(manifest):
    fn = a["exportedFileName"]
    name = a.get("suggestedHumanReadableName") or fn
    path = os.path.join(d, fn)
    if not os.path.isfile(path): continue
    if "-ids" in name:
        shutil.copy(path, os.path.join(ids_dir, f"{suite}-{name.split('_')[0]}.txt")); continue
    if "-notes" in name or "-summary" in name:
        print(f"\n----- {name.split('_')[0]} -----")
        try: print(open(path, encoding="utf-8", errors="replace").read())
        except Exception as e: print(f"(unreadable: {e})")
        shown += 1
if shown == 0: print("  (no notes or summary attachments: the test did not get far enough to write them)")
PY
}

print_result() { # <xcresult>
  xcrun xcresulttool get test-results summary --path "$1" 2>/dev/null | python3 -I -c '
import json, sys
try: s = json.load(sys.stdin)
except Exception: sys.exit(0)
print("  result:", s.get("result"), "| passed", s.get("passedTests"), "failed", s.get("failedTests"), "skipped", s.get("skippedTests"))
for f in s.get("testFailures", []) or []:
    print("  FAILED:", f.get("testName"), "-", f.get("failureText"))
' || true
}

# ---- Suites -----------------------------------------------------------------------------------------------------
STATUS=0
for suite in "${SUITES[@]}"; do
  state=grant; only=""
  case "$suite" in
    unit) only="FilmCraftTests" ;;
    ui) only="FilmCraftUITests/FilmCraftUITests" ;;
    photos-authorized) only="FilmCraftUITests/PhotosIntegrationUITests/testAuthorizedBrowseAndInsert" ;;
    photos-denied) only="FilmCraftUITests/PhotosIntegrationUITests/testDeniedState"; state=revoke ;;
    photos-limited) only="FilmCraftUITests/PhotosIntegrationUITests/testLimitedState"; state=reset ;;
    photos-export) only="FilmCraftUITests/PhotosIntegrationUITests/testExportToPhotos" ;;
    tools) only="FilmCraftUITests/ToolTourUITests" ;;
    panels) only="FilmCraftUITests/PanelTourUITests" ;;
    commands) only="FilmCraftUITests/CommandTourUITests" ;;
    *) only="$suite" ;;
  esac
  name="$(echo "$suite" | tr '/' '-')"
  echo
  echo "==> $suite ($only) on $UDID"
  privacy "$state"
  rm -rf "$OUT/$name.xcresult" "$OUT/$name-attachments"
  started=$(date +%s)
  if ! xcodebuild test-without-building -project FilmCraft.xcodeproj -scheme FilmCraft -destination "id=$UDID" \
      -derivedDataPath "$DD" -resultBundlePath "$OUT/$name.xcresult" -only-testing:"$only" > "$OUT/$name.log" 2>&1; then
    STATUS=1; echo "  FAILED (xcodebuild output: apple/$OUT/$name.log)"; grep -E "error:|failed|Test Case .* failed" "$OUT/$name.log" | head -20 || true
  fi
  if [[ -d "$OUT/$name.xcresult" ]]; then
    print_result "$OUT/$name.xcresult"
    xcrun xcresulttool export attachments --path "$OUT/$name.xcresult" --output-path "$OUT/$name-attachments" >/dev/null 2>&1 || true
    print_attachments "$OUT/$name-attachments" "$name"
    rm -rf "$OUT/$name.xcresult" "$OUT/$name-attachments"
  else
    echo "  (no result bundle produced)"
  fi
  # Host-side mirror of the tours (written even when the app crashed before the summary attachment).
  for f in /tmp/fctour-*-summary.txt; do [[ -f "$f" ]] && { echo "----- $(basename "$f") (host mirror) -----"; cat "$f"; rm -f "$f"; }; done
  rm -f /tmp/fctour-*.log 2>/dev/null || true
  # The app's own log: export results, Photos authorization, command failures.
  elapsed=$(( $(date +%s) - started + 30 ))
  echo "----- app log (ca.hologram.filmcraft, last ${elapsed}s) -----"
  xcrun simctl spawn "$UDID" log show --last "${elapsed}s" --style compact --info --debug \
    --predicate 'subsystem == "ca.hologram.filmcraft"' 2>/dev/null \
    | grep -E "export|authorization|state reset|failed|error|relink" | tail -60 || true
done

echo
echo "==> Done. Read every *-notes and *-summary above: a green run can be hollow. Logs: apple/$OUT/*.log, id lists: apple/$OUT/ids/"
exit $STATUS
