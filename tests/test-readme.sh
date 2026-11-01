#!/usr/bin/env bash
# README contract: what README.md says about the repo must match the repo. Only facts that can
# be checked without hardware: paths, config keys and defaults, script messages, links. It does
# not (and cannot) check that anything in the README was run on a Pi; the README itself marks
# what was observed and what is unverified.
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$PEEL_ROOT" || exit 1

readme=README.md
assert_true "README.md exists" test -f "$readme"
[[ -f $readme ]] || { finish; exit 1; }

# --- Not the sibling template -----------------------------------------------
assert_false "README no longer describes chute" grep -qi 'chute' "$readme"
assert_false "README has no <forgejo-host> placeholder" grep -qF '<forgejo-host>' "$readme"
assert_true "README names the real clone URL" grep -qF 'git clone https://git.dageniusal.top/operator/peel.git' "$readme"

# --- Documented commands and paths exist ------------------------------------
assert_true "README mentions 'pnpm run validate'" grep -qF 'pnpm run validate' "$readme"
assert_true "package.json defines the validate script" node -e "process.exit(require('./package.json').scripts.validate ? 0 : 1)"

# Repo paths under scripts/, systemd/, tests/ or tools/. A path with * is a glob, not a file.
paths_checked=0
while IFS= read -r p; do
  [[ -n $p ]] || continue
  [[ $p == *'*'* ]] && continue
  p="${p#./}"
  paths_checked=$((paths_checked + 1))
  assert_true "README path exists: $p" test -e "$p"
done < <(grep -oE '(^|[ `(])(\./)?(scripts|systemd|tests|tools)/[A-Za-z0-9_.*-]+' "$readme" | sed -e 's/^[ `(]//' -e 's/[.]*$//' | sort -u)
if [[ $paths_checked -gt 0 ]]; then pass "README references repo paths ($paths_checked checked)"; else fail "README references no repo paths"; fi

# File names written without a directory (setup.sh, discover.sh, config.env.example, AGENTS.md ...).
while IFS= read -r f; do
  [[ -n $f ]] || continue
  found="$(find . -name "$f" -not -path './node_modules/*' -not -path './.git/*' | head -n 1)"
  assert_true "README file name exists in the repo: $f" test -n "$found"
done < <(grep -oE '[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\.(sh|py|md|example)' "$readme" | sort -u)

# --- Config keys ------------------------------------------------------------
# Every key in config.env.example (commented or not) is documented in the README, and every
# ALL-CAPS name the README puts in code or assigns is a real key (or a known non-config name).
example_keys="$(grep -oE '^#? ?[A-Z][A-Z0-9_]+=' config.env.example | sed -e 's/^#* *//' -e 's/=$//' | sort -u)"
assert_true "config.env.example defines keys" test -n "$example_keys"
for k in $example_keys; do
  assert_true "README documents config key $k" grep -qF "\`$k\`" "$readme"
done

# Names that are not config keys: the DRY_RUN switch, the FAIL prefix of script errors, and the
# NAME placeholder in NAME=VALUE.
bt='`'
while IFS= read -r k; do
  [[ -n $k ]] || continue
  if grep -qxF "$k" <<<"$example_keys"; then
    pass "README name is a config key: $k"
  else
    case $k in
      DRY_RUN | FAIL | NAME) pass "README name is a known non-config name: $k" ;;
      *) fail "README uses $k, which is not in config.env.example" "add it to config.env.example, or fix the README" ;;
    esac
  fi
done < <({ grep -oE "${bt}[A-Z][A-Z0-9_]{3,}${bt}" "$readme" | tr -d "$bt"; grep -oE '\b[A-Z][A-Z0-9_]{3,}=' "$readme" | tr -d '='; } | sort -u)

# Defaults in the README's config table match the repo. (TEST_PNG_SIZE's default is in the script.)
for k in PRINTER_HOSTNAME INSTALL_METHOD LISTEN_PORT PRINTER_NAME; do
  v="$(sed -n "s/^$k=\"\\(.*\\)\"\$/\\1/p" config.env.example | head -n 1)"
  assert_true "config.env.example gives a default for $k" test -n "$v"
  assert_true "README table: $k defaults to $v" grep -qF "| \`$k\` | \`$v\` |" "$readme"
done
size_default="$(sed -n 's/.*TEST_PNG_SIZE:-\([0-9]*x[0-9]*\)}.*/\1/p' scripts/test-print.sh | head -n 1)"
assert_true "scripts/test-print.sh has a default test size" test -n "$size_default"
assert_true "README table: TEST_PNG_SIZE defaults to $size_default" grep -qF "| \`TEST_PNG_SIZE\` | \`$size_default\` |" "$readme"

# --- Statements the README must keep making ----------------------------------
assert_true "README states there is no authentication" grep -qi 'no authentication' "$readme"
assert_true "README says the snap path runs as root" grep -qiE 'snap install: the server runs as root' "$readme"
assert_true "README says the port is pinned" grep -qi 'port is pinned' "$readme"
default_name="$(sed -n 's/^PRINTER_NAME="\(.*\)"$/\1/p' config.env.example | head -n 1)"
assert_true "README names the IPP endpoint path /ipp/print/$default_name" grep -qF "/ipp/print/$default_name" "$readme"
assert_true "README names the IPP endpoint as the integration point" grep -qi 'integration point' "$readme"
assert_true "README points at the discover script for media" grep -qF 'scripts/discover.sh' "$readme"
assert_true "README points at the test print script" grep -qF 'scripts/test-print.sh' "$readme"

# print-scaling is unconfirmed and listen-port was a wrong option name in the drafts.
assert_false "README does not suggest print-scaling" grep -qi 'print-scaling' "$readme"
assert_false "README does not use the wrong listen-port option" grep -qi 'listen-port' "$readme"

# --- Structure ---------------------------------------------------------------
for h in 'macOS' 'iPhone' 'Windows' 'Linux'; do
  line="$(grep -E "^### .*$h" "$readme" | head -n 1)"
  assert_true "README has a client section for $h" test -n "$line"
  # Each client section carries its verification state in the heading, so an unrun matrix cannot
  # read as a verified one. Change it to "(verified ...)" only with evidence.
  case $line in
    *'(unverified)'* | *'(verified'*) pass "client section '$line' states its verification state" ;;
    *) fail "client section '$line' states its verification state" "add (unverified) or (verified ...) to the heading" ;;
  esac
done
for h in 'Printer not discovered by clients' 'Wrong label size' 'USB and permission problems' 'Setup failure messages'; do
  assert_true "README has a troubleshooting section: $h" grep -qE "^### $h" "$readme"
done

# --- Failure messages quoted in the README exist in the scripts --------------
# First column of the "Setup failure messages" table: each fragment must appear verbatim in a
# script, so a reworded message breaks this test instead of silently stranding the README.
msg_count=0
while IFS= read -r frag; do
  [[ -n $frag ]] || continue
  msg_count=$((msg_count + 1))
  if grep -rqF -- "$frag" setup.sh scripts/*.sh; then
    pass "failure message exists in the scripts: $frag"
  else
    fail "README quotes a message that is not in the scripts: $frag" "update the README or the script"
  fi
done < <(awk '/^### Setup failure messages/ { s = 1; next } /^#{1,3} / { s = 0 }
              s && /^\| `/ { n = split($0, c, " \\| "); f = c[1]; sub(/^\| `/, "", f); sub(/`$/, "", f); print f }' "$readme")
if [[ $msg_count -ge 10 ]]; then pass "failure table has $msg_count messages"; else fail "failure table has too few messages ($msg_count)"; fi

# --- In-page links resolve ----------------------------------------------------
anchor_result="$(python3 -I - "$readme" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
slugs = set()
for m in re.finditer(r"^#{1,6} +(.+?) *$", text, re.M):
    s = re.sub(r"[^a-z0-9 _-]", "", m.group(1).lower()).replace(" ", "-")
    slugs.add(s)
bad = [a for a in re.findall(r"\]\(#([^)]+)\)", text) if a not in slugs]
print("\n".join(bad))
PY
)"
assert_eq "every in-page README link points at a heading" "" "$anchor_result"

finish
