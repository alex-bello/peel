#!/usr/bin/env bash
# Parsers and reconcile decisions for the printer step (scripts/lib.sh, scripts/ipp-attrs.py),
# tested against output CAPTURED ON THE PI (tests/fixtures/, lprint 1.3.1, DYMO LabelWriter 450
# Turbo, 2026-10-31; the printer serial number is replaced by 00000000000000 throughout). No stub
# lprint: nothing here pretends to know what LPrint prints beyond those captures.
#
# Fixtures: lprint-{version,drivers,devices}.txt, lprint-printers.txt (the queue LPrint auto-added,
# display name with spaces), lprint-printers-added.txt (after setup.sh added a queue by name),
# lprint-options.txt (default media oe_address-label_1.125x3.5in), lprint-options-shipping.txt
# (after MEDIA_READY=oe_shipping-label_2.125x4in), and ipp-get-printer-attributes.bin (fetched from a
# Mac over the LAN with scripts/ipp-attrs.py, so its URIs carry the Pi's address 10.10.10.53).
#
# Cases the captures cannot contain (no printer attached, two printers attached) are built by
# editing the captured text, and each says so.
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/lib.sh
source "$PEEL_ROOT/scripts/lib.sh"

FX="$PEEL_ROOT/tests/fixtures"
drivers="$(<"$FX/lprint-drivers.txt")"
devices="$(<"$FX/lprint-devices.txt")"
options="$(<"$FX/lprint-options.txt")"
printers="$(<"$FX/lprint-printers.txt")"
URI='usb://DYMO/LabelWriter%20450%20Turbo?serial=00000000000000'

assert_eq "fixture: lprint --version" "1.3.1" "$(<"$FX/lprint-version.txt")"

# --- lprint drivers ---------------------------------------------------------
assert_eq "attached DYMO device is paired with its driver by LPrint" \
  "dymo_lw-450-turbo $URI" "$(parse_attached_dymo <<<"$drivers")"
names="$(parse_driver_names <<<"$drivers")"
assert_true "driver list has dymo_lw-450-turbo" grep -qFx dymo_lw-450-turbo <<<"$names"
assert_true "driver list keeps the Twin Turbo as a separate driver" grep -qFx dymo_lw-450-twin-turbo <<<"$names"
assert_false "the attached-device line does not leak a bogus driver 'DYMO'" grep -qFx DYMO <<<"$names"
assert_eq "driver names parsed: 83 (84 lines, one is the attached device)" "83" "$(wc -l <<<"$names" | tr -d ' ')"

# --- lprint devices ---------------------------------------------------------
assert_eq "DYMO USB device URI" "$URI" "$(parse_dymo_usb_uris <<<"$devices")"
assert_eq "no DYMO URI in empty output" "" "$(parse_dymo_usb_uris <<<"")"
assert_eq "non-DYMO usb device is ignored" "" "$(parse_dymo_usb_uris <<<'usb://Brother/QL-700?serial=1')"

# --- select_dymo: discovery plus the DRIVER / DEVICE_URI overrides ----------
DRIVER='' DEVICE_URI=''
assert_eq "discovery: one printer gives driver and URI" "dymo_lw-450-turbo $URI" "$(select_dymo "$drivers" "$devices" 2>&1)"

# Zero printers (built by removing the attached-device line and the device from the captures).
drivers_none="$(grep -v ' -> ' <<<"$drivers")"
out="$(select_dymo "$drivers_none" "" 2>&1)"
assert_eq "zero printers: fails" "1" "$?"
for want in "No DYMO USB printer found" "lsusb" "DEVICE_URI"; do
  case $out in *"$want"*) pass "zero printers message has: $want" ;; *) fail "zero printers message has: $want" "got: $out" ;; esac
done

# Two printers (built by duplicating the captured lines with a different serial).
URI2='usb://DYMO/LabelWriter%20450%20Turbo?serial=00000000000001'
drivers_two="$drivers"$'\n'"$(grep ' -> ' <<<"$drivers" | sed 's/00000000000000/00000000000001/g')"
devices_two="$devices"$'\n'"$URI2"
out="$(select_dymo "$drivers_two" "$devices_two" 2>&1)"
assert_eq "two printers: fails" "1" "$?"
for want in "Several DYMO USB printers" "$URI" "$URI2" "Set DEVICE_URI in config.env"; do
  case $out in *"$want"*) pass "two printers message has: $want" ;; *) fail "two printers message has: $want" "got: $out" ;; esac
done
DEVICE_URI=$URI2
assert_eq "two printers: DEVICE_URI picks one and its driver follows" "dymo_lw-450-turbo $URI2" "$(select_dymo "$drivers_two" "$devices_two" 2>&1)"

# DRIVER override.
DEVICE_URI='' DRIVER=dymo_lw-450-twin-turbo
assert_eq "DRIVER override is used as given" "dymo_lw-450-twin-turbo $URI" "$(select_dymo "$drivers" "$devices" 2>&1)"
DRIVER=not_a_driver
out="$(select_dymo "$drivers" "$devices" 2>&1)"
assert_eq "unknown DRIVER fails" "1" "$?"
case $out in
  *"DRIVER='not_a_driver'"*"dymo_lw-450-turbo"*"config.env"*) pass "unknown DRIVER message lists DYMO drivers and names config.env" ;;
  *) fail "unknown DRIVER message lists DYMO drivers and names config.env" "got: $out" ;;
esac

# DEVICE_URI given for a device LPrint did not pair with a driver: DRIVER must be set.
DRIVER='' DEVICE_URI='usb://DYMO/Unlisted?serial=9'
out="$(select_dymo "$drivers" "$devices" 2>&1)"
assert_eq "unpaired DEVICE_URI without DRIVER fails" "1" "$?"
case $out in *"Set DRIVER in config.env"*) pass "unpaired DEVICE_URI message names DRIVER" ;; *) fail "unpaired DEVICE_URI message names DRIVER" "got: $out" ;; esac
DRIVER='' DEVICE_URI=''

# --- lprint options ---------------------------------------------------------
media="$(parse_media_names <<<"$options")"
assert_eq "media names parsed" "32" "$(wc -l <<<"$media" | tr -d ' ')"
assert_true "media list has the default label" grep -qFx oe_address-label_1.125x3.5in <<<"$media"
assert_true "media list has a shipping label" grep -qFx oe_shipping-label_2.125x4in <<<"$media"
assert_true "media list has the roll_max name" grep -qFx roll_max_2.3125x3600in <<<"$media"
assert_false "media list excludes media-source" grep -q 'main-roll' <<<"$media"
assert_false "media names carry no size suffix" grep -q ' ' <<<"$media"
assert_eq "default media" "oe_address-label_1.125x3.5in" "$(parse_default_media <<<"$options")"

assert_true "valid MEDIA_READY has no problem" bash -c "source '$PEEL_ROOT/scripts/lib.sh'; ! media_ready_problem oe_shipping-label_2.125x4in \"\$1\"" _ "$media"
assert_true "empty MEDIA_READY is a problem" media_ready_problem "" "$media"
assert_true "unknown MEDIA_READY is a problem" media_ready_problem "oe_nope_1x1in" "$media"
assert_true "a prefix of a valid name is a problem" media_ready_problem "oe_shipping-label" "$media"
case $(media_ready_problem "oe_nope_1x1in" "$media") in
  *"oe_nope_1x1in"*"not a media name"*) pass "unknown MEDIA_READY message names the value" ;;
  *) fail "unknown MEDIA_READY message names the value" ;;
esac

assert_eq "default media follows MEDIA_READY (captured after it was applied)" \
  "oe_shipping-label_2.125x4in" "$(parse_default_media <"$FX/lprint-options-shipping.txt")"
# (LPrint lists the default media first, so the order differs; the set does not.)
assert_eq "same media set after the change" "$(sort <<<"$media")" "$(parse_media_names <"$FX/lprint-options-shipping.txt" | sort)"

# --- lprint printers --------------------------------------------------------
assert_eq "printer display name becomes the queue name" "DYMO_LabelWriter_450_Turbo" "$(parse_printer_queue_names <<<"$printers")"
assert_eq "a queue added by name keeps its name" "DYMO_LabelWriter_450_Turbo" "$(parse_printer_queue_names <"$FX/lprint-printers-added.txt")"
assert_eq "no printers gives no queues" "" "$(parse_printer_queue_names <<<"")"

# --- reconcile decisions ----------------------------------------------------
stamp="$(printer_stamp DYMO_450 "$URI" dymo_lw-450-turbo)"
assert_eq "stamp format" "DYMO_450|$URI|dymo_lw-450-turbo" "$stamp"
assert_eq "no queue: add" "add" "$(reconcile_action 0 '' "$stamp")"
assert_eq "no queue even with a stamp: add" "add" "$(reconcile_action 0 "$stamp" "$stamp")"
assert_eq "queue and matching stamp: nothing to do" "none" "$(reconcile_action 1 "$stamp" "$stamp")"
assert_eq "queue without a stamp (auto-added): re-add once" "readd" "$(reconcile_action 1 '' "$stamp")"
assert_eq "DEVICE_URI changed: re-add" "readd" "$(reconcile_action 1 "$stamp" "$(printer_stamp DYMO_450 "$URI2" dymo_lw-450-turbo)")"
assert_eq "DRIVER changed: re-add" "readd" "$(reconcile_action 1 "$stamp" "$(printer_stamp DYMO_450 "$URI" dymo_lw-450)")"
assert_eq "name changed: re-add" "readd" "$(reconcile_action 1 "$stamp" "$(printer_stamp OTHER "$URI" dymo_lw-450-turbo)")"
text=$'printer=a|b|c\noptions=x=1 y=2'
assert_eq "stamp_value printer" "a|b|c" "$(stamp_value "$text" printer)"
assert_eq "stamp_value options" "x=1 y=2" "$(stamp_value "$text" options)"
assert_eq "stamp_value of a missing key" "" "$(stamp_value "$text" nope)"

assert_eq "no options removed" "" "$(options_removed 'a=1 b=2' 'a=1 b=2')"
assert_eq "a changed value is not a removal" "" "$(options_removed 'a=1 b=2' 'a=9 b=2')"
assert_eq "an added option is not a removal" "" "$(options_removed 'a=1' 'a=1 c=3')"
assert_eq "one removed option" "b" "$(options_removed 'a=1 b=2' 'a=1')"
assert_eq "all options removed" $'a\nb' "$(options_removed 'a=1 b=2' '')"
assert_eq "nothing before, nothing removed" "" "$(options_removed '' 'a=1')"

# --- printer config validation ----------------------------------------------
pcfg() { # pcfg BODY: load a config with BODY; succeeds when it is valid
  local d
  d="$(mktemp -d)"
  printf '%s\n' "$1" >"$d/config.env"
  (DRY_RUN=0 CONFIG_FILE="$d/config.env" load_config >/dev/null 2>&1)
  local rc=$?
  rm -rf "$d"
  return $rc
}
pcfg_val() { # pcfg_val BODY VAR: the value of VAR after loading BODY
  local d
  d="$(mktemp -d)"
  printf '%s\n' "$1" >"$d/config.env"
  (DRY_RUN=0 CONFIG_FILE="$d/config.env" load_config >/dev/null 2>&1 && eval "printf '%s' \"\$$2\"")
  rm -rf "$d"
}
assert_eq "PRINTER_NAME defaults" "$DEFAULT_PRINTER_NAME" "$(pcfg_val '' PRINTER_NAME)"
assert_eq "empty PRINTER_NAME means the default" "$DEFAULT_PRINTER_NAME" "$(pcfg_val 'PRINTER_NAME=""' PRINTER_NAME)"
assert_true "printer keys may all be empty" pcfg $'DRIVER=""\nDEVICE_URI=""\nMEDIA_READY=""\nPRINTER_OPTIONS=""'
assert_false "PRINTER_NAME with a space is rejected" pcfg 'PRINTER_NAME="my printer"'
assert_false "PRINTER_NAME with a slash is rejected" pcfg 'PRINTER_NAME="a/b"'
assert_true "DEVICE_URI usb:// is accepted" pcfg "DEVICE_URI='$URI'"
assert_true "DEVICE_URI socket:// is accepted" pcfg 'DEVICE_URI=socket://192.168.1.50'
assert_false "DEVICE_URI http:// is rejected" pcfg 'DEVICE_URI=http://x'
assert_false "DEVICE_URI with a space is rejected" pcfg 'DEVICE_URI="usb://a b"'
assert_true "DRIVER name is accepted" pcfg 'DRIVER=dymo_lw-450-turbo'
assert_false "DRIVER with a space is rejected" pcfg 'DRIVER="dymo lw"'
assert_true "PRINTER_OPTIONS NAME=VALUE pairs are accepted" pcfg 'PRINTER_OPTIONS="print-darkness=50 print-quality=high"'
assert_false "PRINTER_OPTIONS without = is rejected" pcfg 'PRINTER_OPTIONS="print-darkness"'
assert_false "PRINTER_OPTIONS must not set media" pcfg 'PRINTER_OPTIONS="media=oe_shipping-label_2.125x4in"'
assert_false "PRINTER_OPTIONS must not set media-ready" pcfg 'PRINTER_OPTIONS="media-ready=x"'
assert_false "PRINTER_OPTIONS with shell metacharacters is rejected" pcfg "PRINTER_OPTIONS='a=\$HOME;b'"
assert_true "MEDIA_READY is not validated at load (checked against the printer)" pcfg 'MEDIA_READY="anything at all"'
d="$(mktemp -d)"; echo 'PRINTER_OPTIONS="bad"' >"$d/config.env"
out="$(DRY_RUN=0 CONFIG_FILE="$d/config.env" bash -c "source '$PEEL_ROOT/scripts/lib.sh'; load_config" 2>&1)"
rm -rf "$d"
case $out in *"PRINTER_OPTIONS entry 'bad'"*"config.env"*) pass "bad PRINTER_OPTIONS message names the entry and config.env" ;; *) fail "bad PRINTER_OPTIONS message names the entry and config.env" "got: $out" ;; esac

# --- add_failed_message: what the user is told when `lprint add` fails after a delete ---------
msg="$(add_failed_message DYMO_X lprint.service '')"
case $msg in
  *"Nothing was deleted in this run"*) pass "add failure with no delete says the printer is as it was" ;;
  *) fail "add failure with no delete says the printer is as it was" "got: $msg" ;;
esac
msg="$(add_failed_message DYMO_X lprint.service 'DYMO_X')"
for want in "AFTER this run deleted DYMO_X" "'DYMO_X' is now GONE" "NOT been re-added" "re-run ./setup.sh" "lsusb" "scripts/discover.sh" "journalctl -u lprint.service -b"; do
  case $msg in *"$want"*) pass "add failure after a delete says: $want" ;; *) fail "add failure after a delete says: $want" "got: $msg" ;; esac
done
assert_false "no 'old queue' sentence when only the same queue was deleted" grep -q 'old queue' <<<"$msg"
msg="$(add_failed_message DYMO_NEW lprint.service 'DYMO_OLD')"
case $msg in
  *"deleted the old queue 'DYMO_OLD'"*"'DYMO_NEW' has NOT been added yet"*"re-run ./setup.sh"*) pass "pure rename: says the old queue was deleted and the new name was not added yet" ;;
  *) fail "pure rename: says the old queue was deleted and the new name was not added yet" "got: $msg" ;;
esac
assert_false "pure rename does not claim the new name is GONE" grep -q 'GONE' <<<"$msg"
msg="$(add_failed_message DYMO_NEW lprint.service 'DYMO_NEW DYMO_OLD')"
case $msg in
  *"deleted DYMO_NEW DYMO_OLD"*"The old queue 'DYMO_OLD' was removed too"*) pass "rename plus re-add: lists both deleted queues" ;;
  *) fail "rename plus re-add: lists both deleted queues" "got: $msg" ;;
esac
for text in "$msg" "$(select_dymo "$drivers_none" '' 2>&1)"; do
  assert_false "no pointer to a README section that does not exist" grep -qi 'README' <<<"$text"
done

# --- leading character of names (a leading '-' would be read as an lprint option) ---------
assert_false "PRINTER_NAME starting with '-' is rejected" pcfg 'PRINTER_NAME="-x"'
assert_false "PRINTER_NAME starting with '_' is rejected" pcfg 'PRINTER_NAME="_x"'
assert_true "the default PRINTER_NAME is accepted" pcfg "PRINTER_NAME=$DEFAULT_PRINTER_NAME"
assert_false "DRIVER starting with '-' is rejected" pcfg 'DRIVER="-m"'
assert_false "DRIVER starting with '.' is rejected" pcfg 'DRIVER=".x"'
assert_true "the captured driver name is accepted" pcfg 'DRIVER=dymo_lw-450-turbo'
assert_false "PRINTER_OPTIONS key starting with '-' is rejected" pcfg 'PRINTER_OPTIONS="-d=x"'
assert_true "PRINTER_OPTIONS key starting with a letter is accepted" pcfg 'PRINTER_OPTIONS="print-quality=high"'
for kv in 'PRINTER_NAME=-x' 'DRIVER=-m' 'PRINTER_OPTIONS=-d=x'; do
  d="$(mktemp -d)"
  printf '%s="%s"\n' "${kv%%=*}" "${kv#*=}" >"$d/config.env"
  out="$(DRY_RUN=0 CONFIG_FILE="$d/config.env" bash -c "source '$PEEL_ROOT/scripts/lib.sh'; load_config" 2>&1)"
  rm -rf "$d"
  case $out in
    *"${kv%%=*}"*"letter or digit"*) pass "leading '-' error names ${kv%%=*}" ;;
    *) fail "leading '-' error names ${kv%%=*}" "got: $out" ;;
  esac
done

# --- scripts/ipp-attrs.py on a captured response -----------------------------
# The response was captured from the Pi's server (Get-Printer-Attributes, 2026-10-31) from the
# Mac over the LAN, so the host in its URIs is the Pi's address, 10.10.10.53.
tmp_ipp="$(mktemp -d)"
trap 'rm -rf "$tmp_ipp"' EXIT
decoded="$(python3 -I "$PEEL_ROOT/scripts/ipp-attrs.py" --decode "$FX/ipp-get-printer-attributes.bin" 2>&1)"
assert_eq "IPP decode: exit status" "0" "$?"
assert_eq "IPP decode: media-ready" "oe_address-label_1.125x3.5in" "$(ipp_attr media-ready <<<"$decoded")"
assert_eq "IPP decode: media-default" "oe_address-label_1.125x3.5in" "$(ipp_attr media-default <<<"$decoded")"
assert_eq "IPP decode: printer-name" "DYMO LabelWriter 450 Turbo" "$(ipp_attr printer-name <<<"$decoded")"
assert_eq "IPP decode: printer-state (3 = idle)" "3" "$(ipp_attr printer-state <<<"$decoded")"
assert_eq "IPP decode: both printer-uri-supported values" \
  $'ipp://10.10.10.53:8631/ipp/print/DYMO_LabelWriter_450_Turbo\nipps://10.10.10.53:8631/ipp/print/DYMO_LabelWriter_450_Turbo' \
  "$(ipp_attr printer-uri-supported <<<"$decoded")"
err="$(python3 -I "$PEEL_ROOT/scripts/ipp-attrs.py" --decode "$FX/lprint-version.txt" 2>&1 >/dev/null)"
assert_eq "IPP: a non-IPP file is rejected (exit 1)" "1" "$?"
assert_eq "IPP: a non-IPP file gives one stderr line" "1" "$(wc -l <<<"$err" | tr -d ' ')"
case $err in
  "ipp-attrs.py: not a valid IPP response"*) pass "IPP: the line says what is wrong" ;;
  *) fail "IPP: the line says what is wrong" "got: $err" ;;
esac
assert_false "IPP: no traceback for a non-IPP file" grep -q Traceback <<<"$err"
# A truncated copy of the real response must also fail cleanly, not with a traceback.
head -c 60 "$FX/ipp-get-printer-attributes.bin" >"$tmp_ipp/truncated.bin"
err="$(python3 -I "$PEEL_ROOT/scripts/ipp-attrs.py" --decode "$tmp_ipp/truncated.bin" 2>&1 >/dev/null)"
assert_false "IPP: a truncated response gives no traceback" grep -q Traceback <<<"$err"

# SYNTHETIC input (hand-built here, NOT captured from the Pi): an attribute with two collection
# values, the second unnamed as IPP encodes additional values. Each must decode on its own.
python3 -I -c '
import struct, sys
def attr(tag, name, value=b""):
    n = name.encode()
    return struct.pack(">BH", tag, len(n)) + n + struct.pack(">H", len(value)) + value
def collection(name, source):
    return attr(0x34, name) + attr(0x4A, "", b"media-source") + attr(0x44, "", source.encode()) + attr(0x37, "")
buf = struct.pack(">BBHI", 1, 1, 0, 1) + b"\x01" + b"\x04"
buf += collection("media-col-ready", "main-roll") + collection("", "auto") + b"\x03"
open(sys.argv[1], "wb").write(buf)
' "$tmp_ipp/two-collections.bin"
assert_eq "IPP synthetic: two collection values decode separately" \
  $'media-col-ready={media-source=main-roll}\nmedia-col-ready={media-source=auto}' \
  "$(python3 -I "$PEEL_ROOT/scripts/ipp-attrs.py" --decode "$tmp_ipp/two-collections.bin" 2>&1)"
assert_false "IPP: a non-http URI is rejected" python3 -I "$PEEL_ROOT/scripts/ipp-attrs.py" ftp://x/

finish
