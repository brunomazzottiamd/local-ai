#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026, Advanced Micro Devices, Inc. All rights reserved.

# stop_dev.sh - stop the development container created by start_dev.sh. By
# default the container is stopped but kept, because its filesystem holds the
# user's work; --remove deletes it, and the Docker network the container was
# created with, if no other container uses it.
#
# CLI arguments: see the usage() function below (also printed by --help).
#
# Requires: docker.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/common.sh"
source "${script_dir}/docker.sh"
source "${script_dir}/dev.sh"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Stop the development container created by start_dev.sh. By default the
container is stopped but kept, because its filesystem holds the user's work;
--remove deletes it, and the Docker network the container was created with,
if no other container uses it.

Options:
  -d, --dev-container NAME
                         dev container name (default: <user>_dev)
  -t, --timeout SECONDS  seconds to wait for a clean shutdown before Docker
                         escalates to SIGKILL (default: 10)
      --remove           remove the container after stopping it (this
                         deletes everything inside it that is not on a
                         mount), and the Docker network if no other
                         container uses it
      --keep-network     with --remove, do not remove the Docker network
  -h, --help             print this help and exit
EOF
}

# Parse the CLI arguments, setting the globals dev_name and dev_stop_timeout
# (empty when not given; main fills them with the defaults) and the flags
# remove and keep_network (0/1).
parse_args() {
    dev_name=""
    dev_stop_timeout=""
    remove=0
    keep_network=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dev-container)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                dev_name="$2"
                shift 2
                ;;
            -t|--timeout)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                dev_stop_timeout="$2"
                shift 2
                ;;
            --remove)
                remove=1
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

# Print a summary of the stopped dev container: name and state after the
# stop (stopped and kept, or removed), the network, and the restart command.
print_summary() {
    local name=$1 net=$2
    local restart="${script_dir}/start_dev.sh"
    if [[ "${name}" != "${DEFAULT_DEV_NAME}" ]]; then
        restart+=" --dev-container ${name}"
    fi
    echo
    echo "The dev container is stopped:"
    if (( remove )); then
        echo "  container:    <${name}> (removed)."
    else
        echo "  container:    <${name}> (stopped and kept)."
    fi
    echo "  network:      <${net:-none}>."
    echo "Restart it with: ${restart}"
}

main() {
    parse_args "$@"

    check_docker
    dev_configure

    dev_name="${dev_name:-${DEFAULT_DEV_NAME}}"
    dev_stop_timeout="${dev_stop_timeout:-${DEFAULT_DEV_STOP_TIMEOUT}}"
    dev_stop_timeout="$(check_positive_int "stop timeout" "${dev_stop_timeout}")"

    local state net keep_container=1
    local remove_cmd="${script_dir}/stop_dev.sh --remove"
    (( remove )) && keep_container=0
    state="$(container_state "${dev_name}")"
    if [[ -z "${state}" ]]; then
        echo "The container <${dev_name}> was not found. Nothing to stop."
        return 0
    fi
    echo "The container <${dev_name}> was found (state: ${state})."
    net="$(container_network "${dev_name}")"

    container_stop_by_state "${dev_name}" "${state}" "${dev_stop_timeout}" "${keep_container}"
    container_wait_for_termination "${dev_name}" "${dev_stop_timeout}"

    if (( remove )); then
        container_remove "${dev_name}" 0
        network_remove "${net}" "${keep_network}"
    else
        if [[ "${dev_name}" != "${DEFAULT_DEV_NAME}" ]]; then
            remove_cmd+=" --dev-container ${dev_name}"
        fi
        echo "Keeping the container <${dev_name}> and its network <${net}>. The changes inside the container are preserved."
        echo "Remove both later with: ${remove_cmd}"
    fi
    print_summary "${dev_name}" "${net}"
}

main "$@"
