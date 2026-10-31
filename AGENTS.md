# AGENTS.md

Instructions for AI coding agents (and humans) working in this repository.

## What peel is

peel turns a Raspberry Pi 3B with a USB-attached DYMO LabelWriter 450 Turbo into a driverless
network label printer. It runs [LPrint](https://github.com/michaelrsweet/lprint) natively on
Raspberry Pi OS Lite and advertises the printer over IPP Everywhere / AirPrint. It deliberately
uses **no CUPS and no Docker**.

The feature record, issue #1, is the source of truth for scope, requirements, acceptance
criteria and the list of unverified assumptions. `README.md` is the end-user guide.

## Read first

1. [`SDLC.md`](SDLC.md) and [`.sdlc.yml`](.sdlc.yml): the delivery workflow, branch and PR
   rules, labels, and verification policy.
2. Issue #1 (via `sc`, below) before changing behavior.

Provider operations (issues, PRs, labels, comments) go through the `source-control` skill's
`sc` wrapper. Do not call `tea`, `gh`, `curl` or provider APIs directly.

## Commands

Run from the repository root with PNPM. `package.json` holds repository tooling only; peel has
no Node runtime dependency and none may be added to the setup or print path.

| Command | Purpose |
| --- | --- |
| `pnpm run validate` | The gate: lint, then tests, then the SDLC config check. Run before every PR. |
| `pnpm run lint` | `bash -n` and `shellcheck -x` on `setup.sh`, `scripts/*.sh`, `tools/*.sh`, `tests/*.sh` |
| `pnpm run test` | Run every `tests/test-*.sh` |
| `pnpm run sdlc:validate-config -- .sdlc.yml` | Validate the SDLC configuration only |

`shellcheck` is a developer tool, not an npm package. Install it with `brew install shellcheck`
(macOS) or `sudo apt-get install shellcheck` (Debian/Raspberry Pi OS); lint fails loudly without it.

## Layout

| Path | Purpose |
| --- | --- |
| `setup.sh`, `config.env.example`, `systemd/`, `scripts/*.sh`, `scripts/*.py` | The product: idempotent installer and helpers, added by the work items of issue #1 |
| `tools/` | Repository tooling (not shipped to the Pi), e.g. `tools/lint.sh` |
| `tests/` | Tests: `run.sh` runs each `test-*.sh`; `lib.sh` has the assertion helpers |
| `scripts/sdlc/validate-config.mjs` | Vendored from the `sdlc` skill. Refresh it deliberately; never edit it in place |

## Conventions

- Bash (`#!/usr/bin/env bash`) plus the Python standard library only. No other runtime or
  package dependencies; adding one (including a test framework or an apt package) needs approval.
- Scripts must be shellcheck-clean. Fix findings; only disable a check with a one-line reason.
- Setup is idempotent and supports `DRY_RUN=1`, which changes nothing. Every failure says what
  to do next.
- Discover, don't hardcode: driver name, USB URI, media names, port and IPP path are looked up
  at run time.
- `config.env` is gitignored and must never be committed. `config.env.example` holds no secrets.
- New logic that can be exercised without hardware gets a `tests/test-*.sh` (source
  `tests/lib.sh`, end with `finish`). Behavior that needs the Pi or printer is verified by hand.

## Hardware honesty

Many assumptions (LPrint output formats, default port, dedicated-user paths, snap plugs) are
**not yet confirmed on hardware**. Never present guessed output as observed. Anything that has
not run on a real Pi 3B with a DYMO 450 Turbo must say so in docs and PRs, and hardware steps
need manual evidence in the PR. If real hardware contradicts a stated assumption, say so and
stop rather than work around it.

## Workflow rules

- Branch `sdlc/{issue-number}-{short-slug}` from `main`, in a worktree under
  `../peel-worktrees`. Commits reference their issue. Keep changes scoped; unrelated changes are
  rejected in review.
- Open a PR when `pnpm run validate` passes. Never merge automatically.
- Stop before the next mutation on any failure, and keep the last verified provider state.
  Do not fall back to raw provider CLIs or APIs.
