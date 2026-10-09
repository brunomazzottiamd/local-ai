# SPDX-License-Identifier: MIT
# Copyright (c) 2026, Advanced Micro Devices, Inc. All rights reserved.
# shellcheck disable=SC2034 # unused variables

# vllm.sh - shared vLLM configuration and Docker container helpers, used by
# start_vllm.sh, stop_vllm.sh, and bench_vllm.sh.
# Not an executable script. Source it from other scripts: `source vllm.sh`
#
# Sourcing this file has no side effects. Call vllm_init before using the
# DEFAULT_* variables (all the scripts do this).
#
# Requires: docker (checked by vllm_init), curl and jq (checked by the
# callers; jq is only used by assert_vllm_serving), and the requirements
# of docker.sh (awk, cut, getent, grep, id, sed).
#
# Defaults (loaded by vllm_init; overridable via the CLI arguments of the
# other scripts, except DEFAULT_VLLM_IMAGE, which reads $VLLM_IMAGE if set):
#   DEFAULT_LLM_NET              Docker network name (<user>_llm_net)
#   DEFAULT_VLLM_NAME            container name (<user>_vllm)
#   DEFAULT_VLLM_CACHE           host directory for the vLLM cache (~/vllm_cache)
#   DEFAULT_VLLM_IMAGE           container image (vllm/vllm-openai-rocm:latest)
#   DEFAULT_VLLM_STARTUP_TIMEOUT seconds to wait for vLLM to become ready (600)
#   DEFAULT_VLLM_STOP_TIMEOUT    seconds to wait for a clean shutdown before
#                                 Docker escalates to SIGKILL (120)
#
# The generic Docker container and network helpers live in docker.sh, which
# this file sources.
#
# Helpers:
#   vllm_configure:        load the default variables (see above).
#   vllm_init:             check_docker, then vllm_configure.
#   vllm_host_port NAME:   host port published by the given container; die if
#                          the container is missing or publishes no port.
#   port_in_use PORT:      return 0 if something is listening on the given
#                          host port.
#   vllm_reachable PORT:   return 0 if the vLLM API answers /health on
#                          127.0.0.1:PORT.
#   assert_vllm_serving PORT [MODEL]:
#                          die unless the vLLM API on 127.0.0.1:PORT answers
#                          /health and serves a model: the given MODEL if
#                          provided, otherwise any model.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/docker.sh"

# --- Configuration -------------------------------------------------------------

# Load the vLLM default variables (see the file header for the names and
# values). No side effects beyond the variable assignments.
vllm_configure() {
    local username
    username="$(id --user --name)"
    # Keep the defaults quoted in the usage() texts of start_vllm.sh (cache
    # directory, startup timeout) and stop_vllm.sh (stop timeout) in sync with
    # these values.
    DEFAULT_LLM_NET="${username}_llm_net"
    DEFAULT_VLLM_NAME="${username}_vllm"
    DEFAULT_VLLM_CACHE="${HOME}/vllm_cache"
    DEFAULT_VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai-rocm:latest}"
    DEFAULT_VLLM_STARTUP_TIMEOUT=600
    DEFAULT_VLLM_STOP_TIMEOUT=120
}

# Check that docker is available, then load the defaults. Call this before
# using the DEFAULT_* variables.
vllm_init() {
    check_docker
    vllm_configure
}

# --- Helpers --------------------------------------------------------------------

# Host port to reach the vLLM server on: the one the given container publishes.
# Die if the container is missing or publishes no port.
vllm_host_port() {
    local name=$1
    local state port
    port="$(container_host_port "${name}")"
    if [[ -z "${port}" ]]; then
        state="$(container_state "${name}")"
        if [[ -z "${state}" ]]; then
            die "The container <${name}> was not found. Start it first: ${script_dir}/start_vllm.sh"
        fi
        die "The container <${name}> (state: ${state}) does not publish a host port."
    fi
    echo "Using the port published by the container: <${port}>." >&2
    printf '%s\n' "${port}"
}

# Return 0 if something is listening on the given host port.
port_in_use() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -Hltn 2>/dev/null | awk '{ print $4 }' | grep --quiet --extended-regexp "[:.]${port}$"
    else
        ( exec 3<>"/dev/tcp/127.0.0.1/${port}" ) 2>/dev/null
    fi
}

# Return 0 if the vLLM API answers /health on 127.0.0.1:PORT.
vllm_reachable() {
    local port=$1
    curl --fail --silent --show-error --max-time 5 \
        --output /dev/null "http://127.0.0.1:${port}/health" 2>/dev/null
}

# Die unless the vLLM API on 127.0.0.1:PORT answers /health and serves a
# model: MODEL must be listed in /v1/models when given, otherwise any
# served model is accepted.
assert_vllm_serving() {
    local port=$1
    local model="${2:-}"
    local base="http://127.0.0.1:${port}"
    local body

    vllm_reachable "${port}" \
        || die "Cannot reach the vLLM server at <${base}/health>. Start it first: ${script_dir}/start_vllm.sh"
    body="$(curl --fail --silent --show-error --max-time 10 "${base}/v1/models")" \
        || die "GET <${base}/v1/models> failed."
    if [[ -n "${model}" ]]; then
        jq --exit-status --arg model "${model}" 'any(.data[]; .id == $model)' >/dev/null <<<"${body}" \
            || die "The model ${model} is not listed by <${base}/v1/models>. Is the server serving a different model?"
    else
        jq --exit-status '.data | length > 0' >/dev/null <<<"${body}" \
            || die "No model is listed by <${base}/v1/models>."
    fi
}
