# Requirements

The host machine needs the following tools available in `PATH`:

| Tool            | Notes                                                                      |
|-----------------|----------------------------------------------------------------------------|
| `bash`          | Version 4.3 or later (uses associative arrays and namerefs).               |
| `docker`        | Docker daemon must be reachable; used by all scripts.                      |
| `coreutils`     | Standard on Linux distributions (`mkdir`, `rm`, `realpath`...).            |
| `rocm-smi`      | Used by `start_vllm.sh` and `start_dev.sh` to discover and partition GPUs. |
| `awk`           | Any POSIX-compatible implementation; used for text parsing.                |
| `curl`          | Used to health-check the vLLM HTTP API and to download `vllm-bench`.       |
| `ss` (iproute2) | (Optional) Used to check whether a port is in use.                         |
| `jq`            | Used to parse JSON responses from the vLLM API.                            |
| `getent`        | Standard glibc utility. Used to look up the `video` and `render` groups.   |
| `git`           | Only needed to clone this repository.                                      |
