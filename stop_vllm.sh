#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026, Advanced Micro Devices, Inc. All rights reserved.

# stop_vllm.sh - gracefully stop the vLLM container created by start_vllm.sh
# (SIGTERM first, SIGKILL only as a last resort), verify from the host that
# the API is no longer reachable, then remove the container, the vLLM cache,
# and the Docker network the container was created with, if no other container
# uses it. Each removal can be skipped with --keep-container, --keep-cache,
# or --keep-network. If the container does not exist, the script prints a
# message and exits successfully: there is nothing to stop or remove.
#
# CLI arguments: see the usage() function below (also printed by --help).
#
# Requires: docker and curl.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/common.sh"
source "${script_dir}/docker.sh"
source "${script_dir}/model.sh"
source "${script_dir}/vllm.sh"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Gracefully stop the vLLM container created by start_vllm.sh, then remove the
container, the vLLM cache, and the Docker network (skip any removal with
--keep-container, --keep-cache, or --keep-network).

Options:
  -v, --vllm-container NAME
                         vLLM container name (default: <user>_vllm)
  -t, --timeout SECONDS  seconds to give the vLLM server to shut down
                         cleanly before Docker escalates to SIGKILL
                         (default: 120)
      --keep-cache       do not remove the vLLM cache directory
      --keep-container   do not remove the vLLM container, just stop it
      --keep-network     do not remove the Docker network
  -h, --help             print this help and exit
EOF
}

# Parse the CLI arguments, setting the globals vllm_name, vllm_stop_timeout
# (empty when -v and -t are not given; main fills them with the defaults),
# and the keep flags keep_container, keep_network, and keep_cache.
parse_args() {
    vllm_name=""
    vllm_stop_timeout=""
    keep_container=0
    keep_network=0
    keep_cache=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--vllm-container)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                vllm_name="$2"
                shift 2
                ;;
            -t|--timeout)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                vllm_stop_timeout="$2"
                shift 2
                ;;
            --keep-cache)
                keep_cache=1
                shift
                ;;
            --keep-container)
                keep_container=1
                shift
                ;;
            --keep-network)
                keep_network=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "error: Invalid option: ${1}." >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

# Locate the given container, the host port to check after the stop, the
# model and vLLM cache directories, and the Docker network the container was
# created with.
# Sets the globals state, stop_port, stop_model, stop_cache, and stop_net
# (state empty if the container does not exist; main then exits without
# doing anything).
locate_container() {
    local name=$1
    state="$(container_state "${name}")"

    if [[ -z "${state}" ]]; then
        echo "The container <${name}> was not found. Nothing to stop."
        return 0
    fi

    echo "The container <${name}> was found (state: ${state})."
    # Port to check from the host: the one the container publishes. A
    # container that was never started never bound a port: nothing to check.
    if [[ "${state}" == "created" ]]; then
        stop_port=""
    else
        stop_port="$(container_host_port "${name}")"
        if [[ -z "${stop_port}" ]]; then
            echo "WARNING: The container <${name}> publishes no host port. Skipping the host reachability check." >&2
        fi
    fi

    # Model directory, cache directory, and network the container was created
    # with. Captured now, while the container still exists (it is removed
    # later). Empty if the container has no such mount.
    stop_model="$(container_mount_source "${name}" /model)"
    stop_cache="$(container_mount_source "${name}" /tmp/.cache/vllm)"
    stop_net="$(container_network "${name}")"
}

# Stop the given container according to its state (set by locate_container).
stop_container() {
    local name=$1 keep_container=$2
    container_stop_by_state "${name}" "${state}" "${vllm_stop_timeout}" "${keep_container}"
}

# Verify from the host that the API is no longer reachable and the port is
# released.
verify_stop() {
    if [[ -n "${stop_port}" ]]; then
        echo "Sanity check [host]: vLLM must no longer be reachable on <127.0.0.1:${stop_port}>."
        if vllm_reachable "${stop_port}"; then
            die "vLLM is still reachable at <http://127.0.0.1:${stop_port}/health> after the stop."
        fi
        echo "  OK: vLLM is not reachable."

        if port_in_use "${stop_port}"; then
            echo "WARNING: Port <${stop_port}> is still in use by something other than vLLM." >&2
        else
            echo "  OK: Port <${stop_port}> is released."
        fi
    fi
}

# Remove the vLLM cache directory of the stopped container, unless it is
# kept, is /, the home directory, or a parent of it, or is still mounted by
# another container. Sets the global cache_outcome to: unknown (empty
# cache_dir), kept (--keep-cache), kept, protected path (the guard above),
# kept, in use (other containers), removed (after rm), or not found.
remove_cache() {
    local name=$1 cache_dir=$2 keep_cache=$3
    if [[ -z "${cache_dir}" ]]; then
        cache_outcome="unknown"
        echo "The vLLM cache directory is unknown. Nothing to remove."
        return 0
    fi
    if [[ "${keep_cache}" == "1" ]]; then
        cache_outcome="kept"
        echo "Keeping the vLLM cache: <${cache_dir}>. You can remove it later with 'rm --recursive --force -- ${cache_dir}'"
        return 0
    fi
    local cache_real cache_plain home_real home_plain
    cache_real="$(realpath --canonicalize-missing -- "${cache_dir}")"
    cache_plain="$(abs_path "${cache_dir}")"
    home_real="$(realpath --canonicalize-missing -- "${HOME}")"
    home_plain="$(abs_path "${HOME}")"
    if [[ "${cache_real}" == "/" || "${cache_plain}" == "/" \
          || "${home_real}/" == "${cache_real}/"* \
          || "${home_plain}/" == "${cache_plain}/"* ]]; then
        cache_outcome="kept, protected path"
        echo "WARNING: Refusing to remove <${cache_dir}>: it is /, your home directory, or a parent of it." >&2
        return 0
    fi
    local -a users=()
    mapfile -t users < <(containers_mounting "${cache_dir}" | grep --invert-match --fixed-strings --line-regexp -- "${name}" || true)
    if (( ${#users[@]} )); then
        cache_outcome="kept, in use"
        echo "WARNING: Keeping the vLLM cache <${cache_dir}>: other containers still use it (${users[*]})." >&2
        return 0
    fi
    if [[ -d "${cache_dir}" ]]; then
        echo "Removing the vLLM cache: <${cache_dir}>."
        rm --recursive --force -- "${cache_dir}"
        cache_outcome="removed"
    else
        cache_outcome="not found"
        echo "The vLLM cache <${cache_dir}> was not found. Nothing to remove."
    fi
}

print_summary() {
    local name=$1
    local restart="${script_dir}/start_vllm.sh"
    if [[ "${name}" != "${DEFAULT_VLLM_NAME}" ]]; then
        restart+=" --vllm-container ${name}"
    fi
    if [[ -n "${stop_port}" && "${stop_port}" != "${DEFAULT_VLLM_PORT}" ]]; then
        restart+=" --port ${stop_port}"
    fi
    if [[ -n "${stop_net}" && "${stop_net}" != "${DEFAULT_LLM_NET}" ]]; then
        restart+=" --network ${stop_net}"
    fi
    if [[ -n "${stop_model}" && "${stop_model}" != "${DEFAULT_MODEL_DIR}" ]]; then
        restart+=" --model-dir ${stop_model}"
    fi
    if [[ -n "${stop_cache}" && "${stop_cache}" != "${DEFAULT_VLLM_CACHE}" ]]; then
        restart+=" --cache-dir ${stop_cache}"
    fi
    echo
    echo "vLLM is stopped:"
    if (( keep_container )); then
        echo "  container:    <${name}> (stopped and kept)."
    else
        echo "  container:    <${name}> (removed)."
    fi
    echo "  cache:        <${stop_cache:-none}> (${cache_outcome})."
    echo "  network:      <${stop_net:-none}>."
    echo "Restart it with: ${restart}"
}

main() {
    parse_args "$@"

    check_curl
    vllm_init

    vllm_name="${vllm_name:-${DEFAULT_VLLM_NAME}}"
    vllm_stop_timeout="${vllm_stop_timeout:-${DEFAULT_VLLM_STOP_TIMEOUT}}"
    vllm_stop_timeout="$(check_positive_int "stop timeout" "${vllm_stop_timeout}")"

    locate_container "${vllm_name}"
    if [[ -z "${state}" ]]; then
        # The container does not exist, so there is nothing to stop, and the
        # vLLM cache directory and Docker network (derived from the container)
        # are unknown, so there is nothing to remove.
        exit 0
    fi
    stop_container "${vllm_name}" "${keep_container}"
    container_wait_for_termination "${vllm_name}" "${vllm_stop_timeout}"
    verify_stop
    container_remove "${vllm_name}" "${keep_container}"
    remove_cache "${vllm_name}" "${stop_cache}" "${keep_cache}"
    network_remove "${stop_net}" "${keep_network}"
    print_summary "${vllm_name}"
}

main "$@"
