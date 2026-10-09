#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026, Advanced Micro Devices, Inc. All rights reserved.

# start_dev.sh - start (or restart) the development container as a long-lived
# Docker container on the GPUs vLLM does not use, then sanity-check that the
# container sees the right GPUs and can reach the vLLM API over the shared
# Docker network. Unless --no-opencode is given, also install OpenCode in it
# (see install_opencode.sh).
#
# The container runs as root with --privileged; its main process is
# sleep infinity under --init, so docker stop returns at once. Enter it with:
# docker exec --interactive --tty <name> bash. With --privileged,
# HIP_VISIBLE_DEVICES is a HIP-level mask, not device isolation.
#
# Environment overrides:
#   DEV_GPUS    comma-separated GPU IDs for the dev container (default: the
#               GPUs of the existing dev container, if any, otherwise
#               resolved by device.sh)
#   VLLM_GPUS   comma-separated GPU IDs for vLLM (default: the GPUs of the
#               vLLM container, if it exists, otherwise resolved by device.sh)
#   DEV_IMAGE   container image (default: rocm/pytorch:latest, see dev.sh)
#
# CLI arguments: see the usage() function below (also printed by --help).
#
# Requires: docker and the requirements of device_init (rocm-smi, awk); curl
# and tar in the container, unless --no-opencode is given.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/common.sh"
source "${script_dir}/docker.sh"
source "${script_dir}/device.sh"
source "${script_dir}/vllm.sh"
source "${script_dir}/dev.sh"
source "${script_dir}/install_opencode.sh"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Start (or restart) the development container as a long-lived Docker container
on the GPUs vLLM does not use, then sanity-check that the container sees the
right GPUs and can reach the vLLM API over the shared Docker network.
Unless --no-opencode is given, also install OpenCode in it.

Options:
  -d, --dev-container NAME   dev container name (default: <user>_dev)
  -v, --vllm-container NAME  vLLM container whose GPUs are reserved and
                             whose API is checked (default: <user>_vllm)
  -n, --network NAME         Docker network name (default: <user>_llm_net)
      --no-opencode          do not install OpenCode in the container
  -h, --help                 print this help and exit
EOF
}

# Parse the CLI arguments, setting the globals dev_name, llm_net, and
# vllm_name (empty when not given; main fills them with the defaults) and the
# flag skip_opencode (0/1).
parse_args() {
    dev_name=""
    llm_net=""
    vllm_name=""
    skip_opencode=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dev-container)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                dev_name="$2"
                shift 2
                ;;
            -v|--vllm-container)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                vllm_name="$2"
                shift 2
                ;;
            -n|--network)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                llm_net="$2"
                shift 2
                ;;
            --no-opencode)
                skip_opencode=1
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

# If DEV_GPUS is not set and the given dev container exists, reuse the GPUs
# it was created with, so restarting it does not depend on how the remaining
# GPUs would be split today.
reuse_dev_gpus() {
    local dev_name=$1
    local gpus
    [[ -z "${DEV_GPUS:-}" ]] || return 0
    gpus="$(container_gpus "${dev_name}")"
    if [[ -n "${gpus}" ]]; then
        DEV_GPUS="${gpus}"
        echo "Reusing the GPUs of the existing dev container <${dev_name}>: <${gpus}>."
    fi
}

# If VLLM_GPUS is not set and the vLLM container exists, reserve its GPUs as
# VLLM_GPUS, so device_init gives the dev container only GPUs vLLM does not
# use (and dies if DEV_GPUS overlaps them). A missing vLLM container is not
# an error: no GPUs are reserved.
reserve_vllm_gpus() {
    local vllm_name=$1
    local gpus
    [[ -z "${VLLM_GPUS:-}" ]] || return 0
    if [[ -z "$(container_state "${vllm_name}")" ]]; then
        echo "The vLLM container <${vllm_name}> was not found. No GPUs are reserved for it."
        return 0
    fi
    gpus="$(container_gpus "${vllm_name}")"
    if [[ -n "${gpus}" ]]; then
        VLLM_GPUS="${gpus}"
        echo "Reserving the GPUs of the vLLM container <${vllm_name}>: <${gpus}>."
    else
        echo "WARNING: The vLLM container <${vllm_name}> sees every GPU. The dev container will share GPUs with it." >&2
    fi
}

# Create the dev container from scratch on the given network.
create_dev_container() {
    local name=$1 net=$2
    local -a docker_args=(
        # Container
        --detach
        --init
        --name "${name}"
        # Networking
        --network "${net}"
        # Security and user
        --privileged
        --user root
        # Storage
        --workdir /workspace
        --volume "${HOME}:/workspace/host_home"
    )
    # Devices, resources, and security
    docker_gpu_args docker_args "${DEV_GPUS}"
    docker run "${docker_args[@]}" "${DEFAULT_DEV_IMAGE}" sleep infinity >/dev/null
    ensure_group "${name}" video
    ensure_group "${name}" render
}

# docker_gpu_args adds the host's video and render GIDs to the container with
# --group-add, but the image may not have a group for them, which makes tools
# like groups print "cannot find name for group ID <gid>". Create the group
# with the given name in the given container, using the GID it has on the
# host, in a single docker exec, only when the container has neither a group
# with that GID nor a group with that name. Does nothing when the host has no
# such group. Warn only; never die (the group is cosmetic for a root
# container).
ensure_group() {
    local name=$1 group=$2
    local gid
    gid="$(getent group "${group}" 2>/dev/null | cut --delimiter=: --fields=3)" || true
    [[ -n "${gid}" ]] || return 0
    docker exec "${name}" bash -c '
        getent group "$1" >/dev/null || getent group "$2" >/dev/null \
            || groupadd --gid "$1" "$2"
    ' _ "${gid}" "${group}" \
        || echo "WARNING: Cannot add the group <${group}> (GID ${gid}) to <${name}>." >&2
}

# Bring the dev container to the running state: create it if it does not
# exist, start it if it is stopped, and skip if it is already running. The
# GPUs are fixed when the container is created, so a mismatch is reported
# (or dies) instead of recreating the container.
start_dev_container() {
    local name=$1 net=$2
    local state gpus existing_net message remove_cmd="${script_dir}/stop_dev.sh --remove"

    state="$(container_state "${name}")"

    if [[ -z "${state}" ]]; then
        echo "The container <${name}> was not found. Pulling <${DEFAULT_DEV_IMAGE}> and creating it ..."
        docker_pull_image "${DEFAULT_DEV_IMAGE}"
        create_dev_container "${name}" "${net}"
    else
        gpus="$(container_gpus "${name}")"
        if ! gpu_sets_equal "${gpus}" "${DEV_GPUS}"; then
            if [[ "${name}" != "${DEFAULT_DEV_NAME}" ]]; then
                remove_cmd+=" --dev-container ${name}"
            fi
            message="The container <${name}> was created with the GPUs <${gpus:-all}>, but the resolved dev GPUs are <${DEV_GPUS}>."
            if [[ -n "${gpus}" ]]; then
                message+=" Re-run with DEV_GPUS=${gpus}, or remove the container to recreate it: ${remove_cmd}"
            else
                message+=" Remove the container to recreate it: ${remove_cmd}"
            fi
            if [[ "${state}" == "running" ]]; then
                echo "WARNING: ${message}" >&2
            else
                die "${message}"
            fi
        fi
        existing_net="$(container_network "${name}")"
        if [[ "${existing_net}" != "${net}" ]]; then
            echo "WARNING: The container <${name}> uses the network <${existing_net}>, not <${net}>. vLLM may be unreachable from it." >&2
        fi
        if [[ "${state}" == "running" ]]; then
            echo "The container <${name}> is already running. Skipping startup."
            return 0
        fi
        echo "The container <${name}> is stopped (state: ${state}). Starting it ..."
        docker start "${name}" >/dev/null
    fi

    wait_until 30 2 container_running "${name}" \
        || die_with_docker_logs "${name}" "The container <${name}> is not running after 30s."
    echo "The container <${name}> is running."
}

# Sanity check that PyTorch inside the given container sees exactly the
# resolved dev GPUs. Warn only; never die (the image may not have PyTorch).
sanity_check_gpus() {
    local name=$1
    local -a dev_gpu_list=()
    local seen
    IFS=',' read -r -a dev_gpu_list <<< "${DEV_GPUS}"
    if ! seen="$(docker exec "${name}" python3 -c 'import torch; print(torch.cuda.device_count())' 2>/dev/null)"; then
        echo "WARNING: Cannot run PyTorch inside <${name}>. Skipping the GPU check." >&2
        return 0
    fi
    if [[ "${seen}" == "${#dev_gpu_list[@]}" ]]; then
        echo "  OK: PyTorch sees ${seen} GPU(s)."
    else
        echo "WARNING: PyTorch sees ${seen} GPU(s) inside <${name}>, but the resolved dev GPUs are <${DEV_GPUS}> (expected ${#dev_gpu_list[@]})." >&2
    fi
}

# Sanity check that the vLLM API is reachable from the given dev container
# over the shared Docker network. Warn only; never die.
sanity_check_vllm() {
    local name=$1 vllm_name=$2
    local port
    if [[ "$(container_state "${vllm_name}")" != "running" ]]; then
        echo "The vLLM container <${vllm_name}> is not running. Start it with: ${script_dir}/start_vllm.sh"
        return 0
    fi
    port="$(container_host_port "${vllm_name}")"
    if [[ -z "${port}" ]]; then
        echo "WARNING: The vLLM container <${vllm_name}> does not publish a host port. Skipping the vLLM check." >&2
        return 0
    fi
    if docker exec "${name}" python3 -c 'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=5)' "http://vllm:${port}/health" >/dev/null 2>&1; then
        echo "  OK: vLLM is reachable from <${name}> at <http://vllm:${port}/v1>."
    else
        echo "WARNING: vLLM is not reachable from <${name}> at <http://vllm:${port}/health> (still starting, or on another network)." >&2
    fi
}

# Print a summary of the running dev container: name, network, GPUs, image,
# and the commands to enter it and stop it.
print_summary() {
    local name=$1 net=$2
    local stop="${script_dir}/stop_dev.sh"
    if [[ "${name}" != "${DEFAULT_DEV_NAME}" ]]; then
        stop+=" --dev-container ${name}"
    fi
    echo
    echo "The dev container is up:"
    echo "  container:    <${name}>."
    echo "  network:      <${net}>."
    echo "  GPUs:         <${DEV_GPUS}>."
    echo "  image:        ${DEFAULT_DEV_IMAGE}."
    echo "  host home:    <${HOME}> (mounted at /workspace/host_home)."
    echo "Enter it with: docker exec --interactive --tty ${name} bash"
    echo "Stop it with: ${stop}"
}

main() {
    parse_args "$@"

    vllm_init
    dev_configure

    dev_name="${dev_name:-${DEFAULT_DEV_NAME}}"
    llm_net="${llm_net:-${DEFAULT_LLM_NET}}"
    vllm_name="${vllm_name:-${DEFAULT_VLLM_NAME}}"

    reuse_dev_gpus "${dev_name}"
    reserve_vllm_gpus "${vllm_name}"
    device_init
    [[ -n "${DEV_GPUS}" ]] \
        || die "No GPUs are left for the dev container (vLLM GPUs: <${VLLM_GPUS}>). Set DEV_GPUS, or give vLLM fewer GPUs."
    echo "Dev GPUs: <${DEV_GPUS}>."

    network_ensure "${llm_net}"
    start_dev_container "${dev_name}" "${llm_net}"
    sanity_check_gpus "${dev_name}"
    sanity_check_vllm "${dev_name}" "${vllm_name}"
    if (( skip_opencode )); then
        echo "Skipping the OpenCode installation (--no-opencode)."
    else
        opencode_install "${dev_name}" "${vllm_name}"
    fi
    print_summary "${dev_name}" "${llm_net}"
}

main "$@"
