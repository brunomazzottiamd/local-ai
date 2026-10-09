# SPDX-License-Identifier: MIT
# Copyright (c) 2026, Advanced Micro Devices, Inc. All rights reserved.
# shellcheck disable=SC2034 # unused variables

# dev.sh - default configuration for the development container, used by
# start_dev.sh and stop_dev.sh.
# Not an executable script. Source it from other scripts: `source dev.sh`
#
# Sourcing this file has no side effects. Call dev_configure before using
# the DEFAULT_* variables (all the scripts do this).
#
# Requires: the requirements of docker.sh (docker, awk, cut, getent, grep,
# id, and sed), which this file sources; the scripts run check_docker
# before using Docker.
#
# Defaults (loaded by dev_configure; overridable via the CLI arguments of
# the other scripts, except DEFAULT_DEV_IMAGE, which reads $DEV_IMAGE if
# set):
#   DEFAULT_DEV_NAME            container name (<user>_dev)
#   DEFAULT_DEV_IMAGE           container image (rocm/pytorch:latest)
#   DEFAULT_DEV_STOP_TIMEOUT    seconds to wait for a clean shutdown before
#                               Docker escalates to SIGKILL (10)
#
# The dev container joins the same Docker network as the vLLM container
# (DEFAULT_LLM_NET, see vllm.sh), so the scripts that need it call vllm_init.
#
# Helpers:
#   dev_configure:             load the default variables (see above).

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/docker.sh"

# Load the dev container default variables (see the file header for the
# names and values). No side effects beyond the variable assignments.
dev_configure() {
    local username
    username="$(id --user --name)"
    DEFAULT_DEV_NAME="${username}_dev"
    DEFAULT_DEV_IMAGE="${DEV_IMAGE:-rocm/pytorch:latest}"
    DEFAULT_DEV_STOP_TIMEOUT=10
}
