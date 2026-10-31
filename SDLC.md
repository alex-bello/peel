# SDLC

Repository contract for the unified SDLC workflow. Machine-readable settings live in
[`.sdlc.yml`](.sdlc.yml); this file explains them. Project behavior and hardware constraints
live in the feature record (issue #1) and, once it lands, `README.md`; they take precedence
for anything about peel itself.

## Provider and tooling

- Provider: Forgejo (`operator/peel` on `git.dageniusal.top`). Default branch: `main`.
- Provider operations go through the `source-control` skill's `sc` wrapper. Do not call
  `tea`, `gh`, `curl`, or provider APIs directly.
- Project commands use PNPM. `package.json` holds repository tooling only; peel has no
  Node runtime dependency and none may be added to the setup or print path.

| Command | Purpose |
| --- | --- |
| `pnpm run validate` | The gate: `lint`, then `test`, then validate `.sdlc.yml` |
| `pnpm run lint` | `bash -n` and `shellcheck -x` on every shell script (`tools/lint.sh`) |
| `pnpm run test` | Run every `tests/test-*.sh` (`tests/run.sh`) |
| `pnpm run sdlc:validate-config -- .sdlc.yml` | Validate the SDLC configuration only |

`scripts/sdlc/validate-config.mjs` is a vendored copy of the validator shipped with the
`sdlc` skill. Refresh it deliberately from the skill; do not edit it in place.

`shellcheck` is required for `lint` and `validate`. It is a developer tool installed with the
OS package manager, not a package dependency. There is no formatter. Tests are plain bash
(`tests/lib.sh`); adding a test framework or any other dependency needs approval first.

## Delivery

- Default flavor: `stepwise`. `thin-slice` and `feature` remain available per feature.
- Branches: `sdlc/{issue-number}-{short-slug}`, created from `main`.
- Each work item is implemented in its own worktree under `../peel-worktrees`.
- Commits must reference their issue. Keep commits small and focused.
- Pull requests are created automatically when a work item passes verification. Merging is
  never automatic.
- Concurrency is 1 (one printer, one author). Raising it requires the isolated worktrees
  already required above.
- Remediation is bounded to exactly two review passes, then the item is marked `blocked`.
- Reviewer: `general`.

## Verification

Every work item needs observable acceptance, relevant tests, scope review, and rollback-aware
verification. For peel specifically:

- A script, doc, or output that has not run on a real Raspberry Pi 3B with a DYMO LabelWriter
  450 Turbo must say so. Never present guessed output as observed. Hardware steps require
  manual evidence in the PR.
- "Tests" means `pnpm run validate` (lint plus `tests/`) plus hand-run hardware steps recorded
  in the PR. Logic that can be tested without hardware needs a test in `tests/`. If real
  hardware contradicts a stated assumption, say so plainly and stop rather than work around it.
- Unrelated changes are rejected in review.

## Labels

| Label | Meaning |
| --- | --- |
| `sdlc` | Managed by this workflow (every managed issue) |
| `sdlc-feature`, `sdlc-work-item` | Issue type (exactly one) |
| `sdlc-requirements`, `sdlc-design` | Feature phase |
| `ready`, `in-progress`, `review`, `complete`, `blocked`, `needs-discovery` | Generic state (at most one) |

Labels are names only; automation also verifies type, state, provenance, and dependencies
from the issue's metadata block.

## Reconciliation and recovery

- Merging a work item's PR closes the child issue. A feature closes only after every child's
  PR is verified merged and `sdlc-reconcile` has recorded completion.
- Dependencies are explicit work-item issue references; cycles and missing dependencies are
  hard stops.
- After any failure, stop before the next mutation and keep the last verified provider state.
  Rerun `sdlc-audit` (read-only) to see where a feature stands, then `sdlc-reconcile`.
