#!/usr/bin/env bash
# README Recovery section contract (work item #8). Structural checks only: the section and its
# subsections exist, the commands in it are marked unverified, the rebuild's stated step count
# matches its numbered list, the hardening guidance is labelled optional and is not wired into
# the setup path, and the claim that config.env holds no secrets matches config.env.example.
# It cannot check that any recovery step works on a Pi; the README says none has been run.
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$PEEL_ROOT" || exit 1

readme=README.md
assert_true "README.md exists" test -f "$readme"
[[ -f $readme ]] || { finish; exit 1; }

# The Recovery section: from "## Recovery" to the next "## " heading (fences are not parsed;
# the section has no "## " line inside a code block).
section="$(awk '/^## Recovery[[:space:]]*$/ { s = 1; next } /^## / { s = 0 } s' "$readme")"
assert_true "README has a '## Recovery' section" test -n "$section"
[[ -n $section ]] || { finish; exit 1; }

# Split the section into "### " subsections, one file each, so each can be inspected alone.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
awk -v dir="$tmp" '
  /^### / { n++; file = sprintf("%s/sub%02d.md", dir, n) }
  file != "" { print > file }
' <<<"$section"

# find_sub PATTERN: path of the first subsection whose heading matches the ERE (case-insensitive).
find_sub() {
  local f
  for f in "$tmp"/sub*.md; do
    [[ -e $f ]] || continue
    if head -n 1 "$f" | grep -qiE "$1"; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

clone_sub="$(find_sub 'clon')"
rebuild_sub="$(find_sub 'rebuild|blank')"
config_sub="$(find_sub 'config\.env')"
overlay_sub="$(find_sub 'overlay|read-only')"
usbboot_sub="$(find_sub 'usb boot')"
for pair in "cloned spare card:$clone_sub" "blank-card rebuild:$rebuild_sub" "config.env copy:$config_sub" \
  "overlay filesystem:$overlay_sub" "USB boot:$usbboot_sub"; do
  assert_true "Recovery has a subsection for ${pair%%:*}" test -n "${pair#*:}"
done
[[ -n $clone_sub && -n $rebuild_sub && -n $config_sub && -n $overlay_sub && -n $usbboot_sub ]] || { finish; exit 1; }

# --- Commands are marked unverified -----------------------------------------------------------------
# The issue's criterion: every command was run, or is marked unverified. Nothing was run. So: in
# every subsection, a fenced command block must come after the word "unverified" (the heading or
# an earlier paragraph); and the subsections that carry the recovery steps say it in their body
# text, not only in the heading.
for f in "$tmp"/sub*.md; do
  heading="$(head -n 1 "$f")"
  unmarked="$(awk 'BEGIN { seen = 0; bad = 0 } tolower($0) ~ /unverified/ { seen = 1 } /^```/ { if (!inblock) { if (!seen) bad++ } inblock = !inblock } END { print bad }' "$f")"
  assert_eq "no fenced command precedes an 'unverified' mark: $heading" "0" "$unmarked"
done
for f in "$clone_sub" "$rebuild_sub" "$config_sub"; do
  assert_true "body text says 'unverified': $(head -n 1 "$f")" grep -qi 'unverified' <(tail -n +2 "$f")
done
# The intro (before the first "### ") says nothing was run.
intro="$(awk '/^### / { exit } { print }' <<<"$section")"
assert_true "Recovery intro says it has not been run" grep -qiE '(nothing|not|no).*\<(run|done)\>' <<<"$intro"
assert_true "Recovery mentions the recovery drill" grep -qi 'drill' <<<"$section"

# --- Cloned spare card -------------------------------------------------------------------------
for tool in diskutil lsblk dd; do
  assert_true "clone path shows $tool" grep -qF "$tool" "$clone_sub"
done
assert_true "clone path covers macOS" grep -qF 'macOS' "$clone_sub"
assert_true "clone path covers Linux" grep -qF 'Linux' "$clone_sub"
assert_true "clone path covers Raspberry Pi Imager" grep -qF 'Imager' "$clone_sub"
# Safety: the device-choice guidance exists in the section and is linked, and source/destination
# and the spare-card size are addressed.
assert_true "Recovery has device-choice guidance" grep -qiE '^### .*device' <<<"$section"
device_sub="$(find_sub 'device')"
assert_true "device-choice subsection exists" test -n "$device_sub"
if [[ -n $device_sub ]]; then
  assert_true "device-choice text names if= and of=" grep -qF 'if=' "$device_sub"
  assert_true "device-choice text says which is source and which is destination" grep -qiE 'source' "$device_sub"
  assert_true "device-choice text mentions the destination" grep -qiE 'destination' "$device_sub"
  assert_true "device-choice text addresses the spare card size" grep -qiE 'same size or larger|smaller' "$device_sub"
fi
assert_true "Recovery says two cards must not be on the network at once" grep -qiE 'two cards' "$clone_sub"
assert_true "two-cards note says why (same hostname)" grep -qi 'hostname' "$clone_sub"

# --- Blank-card rebuild ------------------------------------------------------------------------
assert_true "rebuild uses setup.sh" grep -qF './setup.sh' "$rebuild_sub"
assert_true "rebuild restores config.env" grep -qF 'config.env' "$rebuild_sub"
assert_true "rebuild flashes with Imager" grep -qF 'Imager' "$rebuild_sub"
assert_true "rebuild says to SSH" grep -qi 'ssh' "$rebuild_sub"
# The clone URL used in the rebuild is the one the setup steps use.
outside="$(awk '/^## Recovery[[:space:]]*$/ { s = 1; next } /^## / { s = 0 } !s' "$readme")"
setup_url="$(sed -n 's/.*git clone \(https:[^ `)]*\).*/\1/p' <<<"$outside" | head -n 1)"
rebuild_url="$(sed -n 's/.*git clone \(https:[^ `)]*\).*/\1/p' "$rebuild_sub" | head -n 1)"
assert_true "setup steps give a clone URL" test -n "$setup_url"
assert_eq "rebuild clones the same URL as the setup steps" "$setup_url" "$rebuild_url"

# The stated step count equals the number of numbered steps (top-level "N. " items).
stated="$(grep -oE '[0-9]+ (documented )?manual steps?' "$rebuild_sub" | grep -oE '^[0-9]+' | head -n 1)"
actual="$(grep -cE '^[0-9]+\. ' "$rebuild_sub")"
assert_true "rebuild states a manual step count" test -n "$stated"
assert_true "rebuild has numbered steps" test "$actual" -gt 0
assert_eq "rebuild's stated step count matches its numbered list" "$stated" "$actual"
# The count is described as documented, not measured.
assert_true "rebuild does not claim a measured count" grep -qiE 'not a measured|not measured' "$rebuild_sub"

# --- Linux commands work on older systems and the spare-card write is guarded --------------------
# util-linux before 2.37 has no MOUNTPOINTS column (only MOUNTPOINT), so the plural must not appear.
assert_false "Recovery uses lsblk MOUNTPOINT, not MOUNTPOINTS" grep -qF 'MOUNTPOINTS' <<<"$section"
assert_true "Recovery uses an lsblk column list that includes MOUNTPOINT" grep -qE 'lsblk .*MOUNTPOINT' <<<"$section"
# In the fenced block that writes the image to a Linux device, an umount comes before the dd.
order="$(awk '/^```/ { inb = !inb; if (inb) { umount = 0; lsblk = 0 } next }
  inb && /lsblk/ { lsblk = 1 } inb && /umount/ { umount = 1 }
  inb && /dd if=peel-card\.img of=\/dev\/sd/ { print (umount && lsblk) ? "ok" : "unguarded" }' "$clone_sub")"
assert_eq "Linux spare-card write has lsblk and umount before dd" "ok" "$order"

# --- config.env copy ---------------------------------------------------------------------------
assert_true "config.env is gitignored (the README says so)" grep -qiE 'gitignored' "$config_sub"
assert_true "config.env is in .gitignore" grep -qxF 'config.env' .gitignore
assert_true "config.env guidance says it holds no secrets" grep -qiE 'no secrets' "$config_sub"
assert_true "config.env guidance says where to keep a copy (outside the Pi)" grep -qiE 'outside the pi|computer you control' "$config_sub"
# Back the "no secrets" claim: no assignment in the template looks like a credential.
secret_like="$(grep -E '^[#[:space:]]*[A-Z][A-Z0-9_]*=' config.env.example | grep -iE 'PASS|SECRET|TOKEN|KEY|CRED|AUTH' || true)"
assert_eq "config.env.example defines no secret-like setting" "" "$secret_like"

# --- Hardening is optional, unverified and not enabled by the setup path -------------------------
for pair in "overlay:$overlay_sub" "USB boot:$usbboot_sub"; do
  f="${pair#*:}"
  heading="$(head -n 1 "$f")"
  assert_true "${pair%%:*} heading says optional" grep -qi 'optional' <<<"$heading"
  assert_true "${pair%%:*} heading says unverified" grep -qi 'unverified' <<<"$heading"
  assert_true "${pair%%:*} text mentions setup.sh" grep -qiE 'setup\.sh' "$f"
  assert_true "${pair%%:*} text says it is not enabled" grep -qiE 'not (enabled|enable)' "$f"
done
assert_true "overlay guidance names raspi-config" grep -qF 'raspi-config' "$overlay_sub"
assert_true "USB boot guidance names program_usb_boot_mode" grep -qF 'program_usb_boot_mode' "$usbboot_sub"
assert_true "USB boot guidance warns the OTP change is permanent" grep -qiE 'cannot be undone|permanent' "$usbboot_sub"
# setup.sh and the scripts must not wire either one in: no behavior change.
hits="$(grep -rniE 'overlay|raspi-config|usb_boot|otp_dump' setup.sh scripts systemd config.env.example 2>/dev/null || true)"
assert_eq "setup path does not enable overlayfs or USB boot" "" "$hits"

# --- Links -------------------------------------------------------------------------------------
# In-page links resolving is checked for the whole README by tests/test-readme.sh. Here: the
# Recovery section links to the setup steps it repeats, and the rest of the README points at it.
assert_true "Recovery links to a README step" grep -qE '\]\(#[0-9]-' <<<"$section"
assert_true "Known limitations / setup text links to #recovery" grep -qF '](#recovery)' "$readme"

finish
