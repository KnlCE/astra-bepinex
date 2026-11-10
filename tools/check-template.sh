#!/bin/bash
# Generate repositories from templates/astra-integration — with a game name, an exe and a game folder
# that hold every character that breaks a C# or TOML string or an XML file — and check that what
# comes out builds, parses and is what Astra's launcher reads: the Mono one is fetched (tools/fetch.sh:
# network), built with warnings as errors and packed into astra-gi.zip; both runtimes' manifests parse
# as TOML; the release workflow pins every action by commit. An --id or --owner that is not one is
# REFUSED: nothing is written, and dotnet new prints why. The template is installed into a PRIVATE template cache (dotnet new's
# --debug:custom-hive), never into yours.
#
# And what comes out with NO --id and NO --owner — the template as an author gets it — is a release
# Astra's Workshop takes: `gi-probe check --provenance community` (the catalogue's own check, from
# astra-game-launcher's release, pinned below by version and SHA-256) must pass with no finding on
# the Mono zip built here, and on the IL2CPP manifest in a zip of everything it names. (An IL2CPP
# plugin compiles against a game's own interop assemblies, so no machine without the game builds
# it: its zip here is the pinned runner's files under the generated manifest, without the plugin.)
# .github/workflows/template.yml runs this script on every change to the template.
#
# Usage: tools/check-template.sh
#   GI_PROBE                  a gi-probe binary to use instead of downloading the pinned one (it
#                             must still say the pinned version). Without it, on anything but
#                             Linux x64 — the one build gi-probe is released for — the Workshop
#                             check prints SKIP.
#   ASTRA_GAME_LAUNCHER_REPO  astra-game-launcher's checkout, built fresh into a scratch target dir
#                             and never written to (default: ../astra-game-launcher). Its `inspect`
#                             is run against the packed zip below — a real launcher check, not just
#                             "does this TOML parse": a [[files]] rule matching nothing in the zip
#                             (e.g. a chain/** rule the pinned runner release does not ship yet) is
#                             "not in the zip" to the launcher and would get every integration built
#                             from this template refused at install. Missing the repo prints SKIP.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$(pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
HIVE=(--debug:custom-hive "$W/hive")
fail() { echo "check-template: $*" >&2; exit 1; }

# The Workshop's check: bump the three together (the digest is in the release's gi-probe-linux-x64.sha256).
GI_PROBE_VERSION=0.5.1
GI_PROBE_URL=https://github.com/mihailinl/astra-game-launcher/releases/download/v$GI_PROBE_VERSION/gi-probe-linux-x64
GI_PROBE_SHA256=dd5e1a2708042222e52bbcaa477396480853c615aa209d78fd329451381bc4a9

dotnet new install "$REPO/templates/astra-integration" "${HIVE[@]}" >/dev/null
GAME='X "Gate" & <Co>\Back'
new() { # new <dir> <runtime> [more options]: the options a later one names win
  local dir=$1 runtime=$2; shift 2
  dotnet new astra-integration "${HIVE[@]}" -o "$W/$dir" -n AstraHostile --game "$GAME" --runtime "$runtime" \
    --steamAppId 1234560 --owner Some-One --id some-one.x_y-z.1 "$@" > "$W/$dir.out"
}
new mono mono
new il2cpp il2cpp
new gamedir mono --gameDir '/games/A & B "c"'
new exe mono --exe 'bin\Game "x".exe'
# Two more, clean-named and with the template's OWN defaults (no --id, no --owner), for the Workshop
# and launcher checks below: what an author gets must pass as it is. They are separate from the
# hostile ones because the hostile GAME name's `<`/`>` (deliberately picked to stress TOML/C#/XML
# escaping) makes `target.exe` a string no Windows filename could ever hold, which the real launcher
# correctly refuses (astra-game-launcher's check_component: `<>:"|?*\` are illegal there) — a fact
# about Windows paths, not about this template.
for rt in mono il2cpp; do
  dotnet new astra-integration "${HIVE[@]}" -o "$W/community-$rt" -n AstraMyGame --game 'My Game' \
    --runtime "$rt" --steamAppId 1234560 > "$W/community-$rt.out"
done

# Refused: an id or owner that is not one is never rewritten into another; nothing is written.
refused() { # refused <dir> <what the output must name> <options…>
  local dir=$1 says=$2; shift 2
  dotnet new astra-integration "${HIVE[@]}" -o "$W/$dir" -n AstraHostile --game G --steamAppId 1 "$@" > "$W/$dir.out"
  [ -z "$(ls -A "$W/$dir" 2>/dev/null)" ] || fail "$dir: files were written for a refused option: $(ls -A "$W/$dir" | tr '\n' ' ')"
  grep -q 'REFUSED' "$W/$dir.out" && grep -qF -- "$says" "$W/$dir.out" || fail "$dir: dotnet new did not say why: $(cat "$W/$dir.out")"
}
refused bad-id '--id is not an integration id' --id 'some-one.x"y z'
# astra. and minice. are Astra's own prefixes: the Workshop refuses them in anyone else's release
# (reserved-id, in any letter case), so the template does first.
refused reserved-id '--id is not an integration id' --id astra.mygame
refused reserved-id-2 '--id is not an integration id' --id Minice.my-game
refused bad-owner '--owner is not a GitHub' --owner 'Some One!'
refused bad-owner-2 '--owner is not a GitHub' --owner '-dash'
echo "refusals: OK"

# The manifests: TOML that says what the options meant.
python3 - "$W" <<'EOF'
import sys, tomllib
w = sys.argv[1]
for rt in ("mono", "il2cpp"):
    gi = tomllib.load(open(f"{w}/{rt}/astra-gi.toml", "rb"))
    item = tomllib.load(open(f"{w}/{rt}/astra-item.toml", "rb"))
    want = "Astra for X 'Gate' & <Co>Back"
    assert gi["integration"]["name"] == want, gi["integration"]["name"]
    assert item["name"] == want, item["name"]
    assert gi["integration"]["id"] == item["id"] == "some-one.x_y-z.1", gi["integration"]["id"]
    assert gi["integration"]["authors"] == ["Some-One"], gi["integration"]["authors"]
    assert gi["integration"]["repo"] == "https://github.com/Some-One/AstraHostile", gi["integration"]["repo"]
    assert gi["target"]["exe"] == "X 'Gate' & <Co>Back.exe", gi["target"]["exe"]
    assert gi["target"]["steam_appid"] == 1234560
exe = tomllib.load(open(f"{w}/exe/astra-gi.toml", "rb"))["target"]["exe"]
assert exe == "bin/Game 'x'.exe", exe   # a \ is a path separator: it becomes /, never dropped
print("manifests: OK")
EOF

# The projects: XML MSBuild reads, with the values the options meant.
for rt in mono il2cpp; do
  name=$(dotnet msbuild "$W/$rt/AstraHostile.csproj" -getProperty:BepInExPluginName)
  [ "$name" = "Astra for X 'Gate' & <Co>Back" ] || fail "$rt: BepInExPluginName is '$name'"
done
dir=$(dotnet msbuild "$W/gamedir/AstraHostile.csproj" -getProperty:GameDir)
[ "$dir" = '/games/A & B "c"' ] || fail "GameDir is '$dir'"
echo "projects: OK"

# The workflow: every action pinned by a full commit SHA.
wf="$W/mono/.github/workflows/release.yml"
unpinned=$(grep -E '^\s*(- )?uses:' "$wf" | grep -vE '@[0-9a-f]{40}( |$)' || true)
[ -z "$unpinned" ] || fail "actions not pinned by commit: $unpinned"
[ ! -e "$W/il2cpp/.github" ] || fail "the IL2CPP flavour got a workflow (no CI can build it)"
echo "workflow: OK"

# The Mono one end to end: fetch, build as CI does, pack the zip.
(
  cd "$W/mono"
  bash tools/fetch.sh >/dev/null
  dotnet build -c Release -p:TreatWarningsAsErrors=true -v q > build.log 2>&1 || { tail -20 build.log >&2; exit 1; }
  bash tools/make-astra-gi.sh >/dev/null
  unzip -l astra-gi.zip | grep -q 'BepInEx/plugins/AstraHostile/AstraHostile.dll'
) || fail "the Mono project did not build and pack"
echo "build and zip: OK"

# The template as an author gets it, built and packed: the Mono one as its own release workflow
# does; the IL2CPP one as the pinned runner's files under the generated manifest (see the header).
(
  cd "$W/community-mono"
  bash tools/fetch.sh >/dev/null
  dotnet build -c Release -p:TreatWarningsAsErrors=true -v q > build.log 2>&1 || { tail -20 build.log >&2; exit 1; }
  bash tools/make-astra-gi.sh >/dev/null
) || fail "the default Mono project did not build and pack"
(
  cd "$W/community-il2cpp"
  bash tools/fetch.sh >/dev/null
  cp astra-gi.toml foundation/unpacked/astra-gi.toml
  ( cd foundation/unpacked && zip -qr - . ) > astra-gi.zip
) || fail "the default IL2CPP manifest did not pack over its runner's files"

# The Workshop's own check on both. A finding of any kind fails: the template is what a community
# author copies, so it may not carry a line the catalogue refuses (2026-11: it shipped without
# [integration.loader] and [integration.capabilities], and with an astra.* default id).
PROBE=${GI_PROBE:-}
if [ -z "$PROBE" ] && [ "$(uname -sm)" = "Linux x86_64" ]; then
  PROBE="$W/gi-probe"
  curl -fsSL -o "$PROBE" "$GI_PROBE_URL" || fail "gi-probe $GI_PROBE_VERSION did not download ($GI_PROBE_URL)"
  echo "$GI_PROBE_SHA256  $PROBE" | sha256sum -c --quiet >/dev/null 2>&1 \
    || fail "$GI_PROBE_URL is not the gi-probe this script pins (sha256 $GI_PROBE_SHA256)"
  chmod +x "$PROBE"
fi
if [ -n "$PROBE" ]; then
  said=$("$PROBE" --version) || fail "gi-probe ($PROBE) did not run"
  case "$said" in "gi-probe $GI_PROBE_VERSION"|"gi-probe $GI_PROBE_VERSION "*) ;; *) fail "gi-probe is '$said', this script pins $GI_PROBE_VERSION";; esac
  for rt in mono il2cpp; do
    "$PROBE" check "$W/community-$rt/astra-gi.zip" --provenance community > "$W/probe-$rt.json" || true
    python3 - "$W/probe-$rt.json" "$rt" <<'EOF' || fail "gi-probe $GI_PROBE_VERSION refuses the $rt template as a community release"
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except ValueError:
    sys.exit("gi-probe printed no report: " + open(sys.argv[1]).read()[:400])
for f in r["findings"]:
    print(f"  {f['code']}: {f['detail']}", file=sys.stderr)
ok = r["verdict"] == "pass" and not r["findings"] and r["input"]["provenance"] == "community" and r["input"]["kind"] == "zip"
sys.exit(0 if ok else f"verdict {r['verdict']}, {len(r['findings'])} finding(s)")
EOF
  done
  echo "gi-probe $GI_PROBE_VERSION check (community): OK"
else
  echo "SKIP: gi-probe check (no gi-probe build for $(uname -sm); set GI_PROBE)"
fi

# The launcher itself, not just a TOML parse: a [[files]] rule matching nothing in the zip is
# refused outright (astra-game-launcher's package.rs, "not in the zip") — the exact mistake that
# shipped [integration.mods] + chain/** pinned to a runner release with no chain/ in its zip.
LAUNCHER_REPO=${ASTRA_GAME_LAUNCHER_REPO:-"$REPO/../astra-game-launcher"}
if [ -d "$LAUNCHER_REPO" ]; then
  ( cd "$LAUNCHER_REPO" && CARGO_TARGET_DIR="$W/launcher-build" cargo build --release -q ) \
    || fail "astra-game-launcher ($LAUNCHER_REPO) did not build"
  LAUNCHER_BIN="$W/launcher-build/release/astra-game-launcher"
  ZIP="$W/community-mono/astra-gi.zip"
  SHA=$(sha256sum "$ZIP" | cut -d' ' -f1)
  OUT=$("$LAUNCHER_BIN" inspect "$ZIP" --sha256 "$SHA" --json 2>&1) \
    || fail "astra-game-launcher refused the packed template zip: $OUT"
  echo "launcher inspect: OK"
else
  echo "SKIP: launcher inspect ($LAUNCHER_REPO not found; set ASTRA_GAME_LAUNCHER_REPO)"
fi
echo "check-template: OK"
