# AGENTS.md

## Repository identity
- This is a GNU Emacs source tree (`31.0.50`) with IGC/MPS work (`README-IGC`, `mps/`).
- IGC is optional at configure time (`--with-mps={yes|debug|no}`), but this fork includes MPS-specific code and tests.

## Fast path commands (verified here)
- Existing checkout build: `make`
- Full test suite (default selector): `make check`
- Single test file from root: `make -C test <name>-tests` (example from `CONTRIBUTE`: `make && make -C test xt-mouse-tests`)
- Test subsets:
  - `make -C test check-expensive`
  - `make -C test check-all`
  - `make -C test <dirname>` or `make -C test check-<dir-with-dashes>`

## Build/bootstrap workflow
- Fresh repo workflow is `./autogen.sh -> ./configure -> make` (`INSTALL.REPO`).
- If autoload/loaddefs breakage appears, run `make -C lisp autoloads`; if still broken, run `make bootstrap`.
- For build-system changes, also verify an out-of-tree build:
  - `mkdir ../emacs-build && cd ../emacs-build && ../custom-emacs/configure && make`

## Commit and hook gotchas
- `./autogen.sh` installs repo Git hooks from `build-aux/git-hooks/*`.
- Pre-commit hook rejects commits that mix `mps/` and non-`mps/` paths in one commit. Keep those changes split.
- Hook also rejects adding `ChangeLog` files, invalid filenames, and whitespace errors.
- Commit-msg hook enforces formatting (empty second line, line length, no `Signed-off-by:`).

## Directory map (only what changes agent behavior)
- `src/`: C runtime/editor core.
- `lisp/`: main Emacs Lisp functionality.
- `test/`: ERT test harness and selectors (`:expensive-test`, `:unstable`, `:nativecomp`, `:igc`).
- `mps/`: bundled MPS sources/docs/examples; treat as its own change domain because of hook policy.

## Editing rules for generated files
- Root `Makefile` and many subdir makefiles are generated (`Generated from Makefile.in by configure`).
- Prefer editing `Makefile.in`/`configure.ac` sources, then regenerate via configure/autogen flow.
