# Contributor's Guide

Bug fixes and feature additions are welcome. For large changes, open an issue first to discuss the
approach. See [ARCHITECTURE.md](ARCHITECTURE.md) for the project scope and design.

## Repository Layout

Executables, run directly and have a `#!/usr/bin/env bash` shebang:

- `download_model.sh` - download the model from the Hugging Face Hub
- `start_vllm.sh` - start (or restart) the vLLM server container
- `bench_vllm.sh` - run a serving benchmark against the vLLM server
- `stop_vllm.sh` - stop the vLLM container and remove what it created
- `start_dev.sh` - start (or restart) the development container
- `install_opencode.sh` - install OpenCode in the development container (both an executable and a
  library: `start_dev.sh` sources it)
- `stop_dev.sh` - stop the development container

Libraries (sourced only, no shebang, no side effects at source time):

- `common.sh` - external dependency checks, value validation, common utility functions
- `docker.sh` - generic Docker container and network helpers
- `device.sh` - GPU discovery and partitioning (`DEV_GPUS` / `VLLM_GPUS`)
- `model.sh` - model name and options, model-directory checks
- `vllm.sh` - vLLM defaults and vLLM-specific helpers
- `dev.sh` - development container defaults

Documentation: add plain Markdown files as needed.

## Conventions

Follow these conventions when contributing to the project:

- SPDX header (`# SPDX-License-Identifier: MIT` plus the copyright line) at the top of every source
  file, followed by a file header comment: the purpose, the environment overrides (if any),
  "CLI arguments: see usage() (also printed by --help)", and "Requires:".
- Executables use `#!/usr/bin/env bash` and `set -euo pipefail`. Libraries have no shebang and
  no side effects at source time; a library that needs setup exposes an `*_init` /
  `*_configure` entry point.
- CLI parsing follows the `usage()` + `parse_args()` pattern, with `-s, --long` options (short and
  long variants) and a `-h, --help` that prints the usage and exits before any external check.
- `local` for function variables; bash namerefs for output parameters; quote every expansion as
  `"${var}"`.
- Prefer `if` blocks over `[[ ... ]] && cmd` as standalone statements (the latter can trip
  `set -e`).
- Use GNU long options (`mkdir --parents`, `rm --recursive`, `grep --quiet --fixed-strings`, ...)
  in the scripts. They are more readable; short options only save keystrokes, which matters at
  the prompt, not in a script.
- Messages are full sentences ending in a period. Values go in `<...>` (e.g. `the container
  <name>`). Errors go through `die` (they get the `error:` prefix); warnings start with
  `WARNING:` and go to stderr (`>&2`).
- Shell commands suggested in messages must be copy-pasteable: long options, no `<...>` around
  real values, and no trailing period right after the command.
- Do not install anything other than basic command-line tools on the host. If you need Python to do
  something more complex, do it inside a container. You can use the development container or spin
  up a new throwaway container with Python for one-time tasks (see `download_model.sh`).

## Checks Before a PR

- One topic per PR.
- Commit style: short imperative subject lines. Follow the style described in the
  [How to Write a Git Commit Message](https://cbea.ms/git-commit/) blog post.
- `bash -n *.sh` (no output) and `shellcheck *.sh` (the repository's `.shellcheckrc` applies; no
  new warnings).
  - `bash -n` tells Bash to read and parse files without executing them. It's a syntax check, a dry
    run for syntax only.
  - [ShellCheck](https://www.shellcheck.net/) is an open-source static analysis and linting tool for
    shell scripts. It's an amazing project!
- A manual test on a GPU host: start, restart, and stop both containers with the defaults and with
  custom names, ports, and GPU sets.
- A manual test of the feature or bugfix you are working on.
- Please share the results of your tests.

## License

Contributions are under the MIT license in [LICENSE](LICENSE).
