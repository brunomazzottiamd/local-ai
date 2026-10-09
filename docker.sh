# SPDX-License-Identifier: MIT
# Copyright (c) 2026, Advanced Micro Devices, Inc. All rights reserved.

# docker.sh - generic Docker container and network helpers, shared by the
# vLLM scripts and the dev container scripts.
# Not an executable script. Source it from other scripts: `source docker.sh`
#
# Sourcing this file has no side effects. The callers run check_docker (see
# common.sh) before using these helpers.
#
# Requires: docker, awk, cut, getent, grep, id, and sed.
#
# Inspection:
#   container_state NAME:  state of the given container (running/exited/...),
#                          or empty if it does not exist.
#   container_host_port NAME: host port published by the given container, if
#                          any, even while it is stopped (empty if none).
#   container_network NAME:  network the given container was created with
#                          (from .HostConfig.NetworkMode; empty if the
#                          container does not exist).
#   container_env NAME VAR:  value of the environment variable VAR in the
#                          configuration of the given container (empty if
#                          the container does not exist or does not set VAR).
#   container_gpus NAME:     GPUs the given container was created with (its
#                          HIP_VISIBLE_DEVICES, e.g. "4,5,6,7"), or empty if
#                          the container does not exist or sees every GPU.
#   container_mount_source NAME DEST: host path mounted at DEST inside the
#                          given container (empty if the container does not
#                          exist or has no mount at DEST).
#   containers_mounting PATH:  names of the containers (any state) that
#                          mount the given host path, one per line.
#
# Predicates (for wait_until, see common.sh):
#   container_running NAME:  the given container is running.
#   container_terminated NAME: the given container no longer exists or has
#                          exited.
#
# Lifecycle:
#   docker_pull_image IMAGE: pull the given image, or die.
#   docker_ensure_image IMAGE: pull the given image unless it is already
#                          present locally.
#   container_stop_by_state NAME STATE TIMEOUT KEEP_CONTAINER:
#                          stop the given container according to its state.
#   container_wait_for_termination NAME STOP_TIMEOUT:
#                          wait for the given container to fully terminate
#                          and report how it exited.
#   container_remove NAME KEEP_CONTAINER:
#                          remove the given container, if it still exists,
#                          unless it is kept.
#   die_with_docker_logs NAME MESSAGE:
#                          like die, but also report that the given
#                          container was kept for inspection and show the
#                          tail of its log.
#
# Networks:
#   network_ensure NET:    create the given isolated Docker network if it
#                          does not exist yet.
#   network_remove NET KEEP_NETWORK:
#                          remove the given Docker network if it exists and
#                          no container (running or stopped) uses it, unless
#                          it is kept.
#
# docker run argument builders:
#   docker_gpu_args OUT [GPUS]: append the options that give a container
#                          access to the AMD GPUs (the KFD and DRI devices,
#                          the video and render groups, host IPC, unlimited
#                          locked memory, a large stack, ptrace, no seccomp,
#                          and HIP_VISIBLE_DEVICES when GPUS is given) to
#                          the array named by OUT.
#   docker_host_user_args OUT: append the options that run the container as
#                          the host user (UID:GID, with HOME=/tmp and
#                          USER/LOGNAME set to the host user name) to the
#                          array named by OUT.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/common.sh"

# --- Inspection -----------------------------------------------------------------

# State of the given container (running/exited/...), or empty if it does not exist.
container_state() {
    local name=$1
    docker inspect --format '{{.State.Status}}' "${name}" 2>/dev/null || true
}

# Host port published by the given container, if any (empty if none): the
# first one in .NetworkSettings.Ports (map keys iterate in sorted order).
# Docker empties .NetworkSettings.Ports when the container stops, so fall
# back to the configured .HostConfig.PortBindings.
container_host_port() {
    local name=$1
    local port
    port="$(docker inspect --format \
        '{{range $p, $b := .NetworkSettings.Ports}}{{if $b}}{{(index $b 0).HostPort}}{{break}}{{end}}{{end}}' \
        "${name}" 2>/dev/null || true)"
    if [[ -z "${port}" ]]; then
        port="$(docker inspect --format \
            '{{range $p, $b := .HostConfig.PortBindings}}{{if $b}}{{(index $b 0).HostPort}}{{break}}{{end}}{{end}}' \
            "${name}" 2>/dev/null || true)"
    fi
    printf '%s' "${port}"
}

# Network the given container was created with, per .HostConfig.NetworkMode:
# the network name for a user-defined network, or a built-in mode (default,
# bridge, host, none, container:..., ns:...). Empty if the container does not
# exist.
container_network() {
    local name=$1
    docker inspect --format '{{.HostConfig.NetworkMode}}' "${name}" 2>/dev/null || true
}

# Value of the environment variable VAR in the configuration of the given
# container, or empty if the container does not exist or does not set VAR.
container_env() {
    local name=$1 var=$2
    docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${name}" 2>/dev/null \
        | awk -v prefix="${var}=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' \
        || true
}

# GPUs the given container was created with (its HIP_VISIBLE_DEVICES, e.g.
# "4,5,6,7"), or empty if the container does not exist or sees every GPU.
container_gpus() {
    container_env "$1" HIP_VISIBLE_DEVICES
}

# Host path mounted at DEST inside the given container, or empty if the
# container does not exist or has no mount at DEST.
container_mount_source() {
    local name=$1 dest=$2
    docker inspect --format \
        "{{range .Mounts}}{{if eq .Destination \"${dest}\"}}{{.Source}}{{end}}{{end}}" \
        "${name}" 2>/dev/null || true
}

# Names of the containers (any state) that mount the given host path, one per
# line.
containers_mounting() {
    local source=$1
    local name
    while IFS= read -r name; do
        if docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "${name}" 2>/dev/null \
            | grep --quiet --fixed-strings --line-regexp -- "${source}"; then
            printf '%s\n' "${name}"
        fi
    done < <(docker ps --all --format '{{.Names}}')
}

# --- Predicates -----------------------------------------------------------------

# Predicate for wait_until: the given container is running.
container_running() {
    [[ "$(container_state "$1")" == "running" ]]
}

# Predicate for wait_until: the given container no longer exists or has exited.
container_terminated() {
    local name=$1
    local state
    state="$(container_state "${name}")"
    [[ -z "${state}" || "${state}" == "exited" ]]
}

# --- Lifecycle ------------------------------------------------------------------

# Pull the given image, or die.
docker_pull_image() {
    local image=$1
    echo "Pulling the image <${image}>. This can take several minutes the first time ..."
    docker pull --quiet "${image}" || die "Failed to pull the image <${image}>."
}

# Pull the given image unless it is already present locally.
docker_ensure_image() {
    local image=$1
    if docker image inspect "${image}" >/dev/null 2>&1; then
        return 0
    fi
    docker_pull_image "${image}"
}

# Stop the given container according to its state. STATE is the container
# state reported by container_state (empty if the container does not exist);
# TIMEOUT is the number of seconds docker stop is given before escalating to
# SIGKILL; KEEP_CONTAINER is 1 to keep a never-started container.
container_stop_by_state() {
    local name=$1 state=$2 timeout=$3 keep_container=$4
    case "${state}" in
        "")
            # No container: nothing to stop.
            ;;
        running)
            echo "Stopping the container <${name}> (SIGTERM; SIGKILL after ${timeout}s if needed) ..."
            docker stop --timeout "${timeout}" "${name}" >/dev/null
            ;;
        exited)
            echo "The container <${name}> is already stopped."
            ;;
        created)
            if [[ "${keep_container}" == "1" ]]; then
                echo "The container <${name}> was never started. Keeping it. You can remove it later with 'docker rm ${name}'."
            else
                echo "The container <${name}> was never started. Removing it ..."
                docker rm "${name}" >/dev/null
            fi
            ;;
        *)
            echo "The container <${name}> is in the unexpected state <${state}>. Attempting docker stop ..."
            if ! docker stop --timeout "${timeout}" "${name}" >/dev/null 2>&1; then
                echo "Docker stop failed. Removing the container ..."
                docker rm --force "${name}" >/dev/null
            fi
            ;;
    esac
}

# Wait for the given container to fully terminate and report how it exited.
# A container that was never started (state: created) has nothing to wait
# for. STOP_TIMEOUT is the number of seconds the container was given to stop
# cleanly; the wait itself times out STOP_TIMEOUT + 30 seconds later.
container_wait_for_termination() {
    local name=$1 stop_timeout=$2
    local state exit_code

    state="$(container_state "${name}")"
    if [[ -n "${state}" && "${state}" != "created" ]]; then
        echo "Waiting for the container <${name}> to fully terminate ..."
        if wait_until "$(( stop_timeout + 30 ))" 4 container_terminated "${name}"; then
            echo "The container <${name}> terminated (${WAIT_UNTIL_ELAPSED}s)."
        else
            state="$(container_state "${name}")"
            die "The container <${name}> is still in the state <${state}> after ${WAIT_UNTIL_ELAPSED}s. Inspect it with: docker logs ${name}"
        fi

        exit_code="$(docker inspect --format '{{.State.ExitCode}}' "${name}" 2>/dev/null || true)"
        if [[ "${exit_code}" == "137" ]]; then
            echo "WARNING: The container <${name}> did not stop within ${stop_timeout}s and was force-killed (SIGKILL)." >&2
        elif [[ -n "${exit_code}" ]]; then
            echo "The container <${name}> stopped (exit code: ${exit_code})."
        fi
    fi
}

# Remove the given container, if it still exists, unless it is kept.
container_remove() {
    local name=$1 keep_container=$2
    if [[ -z "$(container_state "${name}")" ]]; then
        return 0
    fi
    if [[ "${keep_container}" == "1" ]]; then
        echo "Keeping the container <${name}>. You can remove it later with 'docker rm ${name}'."
    else
        echo "Removing the container <${name}>."
        docker rm "${name}" >/dev/null
    fi
}

# Like die, but also report that the given container was kept for inspection
# and show the tail of its log. The user can inspect it (docker logs, docker
# exec, ...) or remove it (docker rm) and re-run the script.
die_with_docker_logs() {
    local name=$1
    shift
    {
        echo "error: $*" >&2
        echo "error: The container <${name}> was kept for inspection." >&2
        echo "--- Last lines of the command: docker logs <${name}>" >&2
        docker logs --tail 40 "${name}" 2>&1 | sed 's/^/    /' >&2 || true
        echo "---" >&2
    }
    exit 1
}

# --- Networks -------------------------------------------------------------------

# Create the given isolated Docker network if it does not exist yet.
network_ensure() {
    local net=$1
    if docker network inspect "${net}" >/dev/null 2>&1; then
        echo "Found the existing Docker network: <${net}>."
    else
        docker network create "${net}" >/dev/null
        echo "Created the Docker network: <${net}>."
    fi
}

# Remove the given Docker network, if it exists and no container (running or
# stopped) uses it, unless it is kept.
network_remove() {
    local net=$1 keep_network=$2

    if [[ -z "${net}" ]]; then
        echo "No Docker network is associated with the container. Nothing to remove."
        return 0
    fi
    case "${net}" in
        default|bridge|host|none|container:*|ns:*)
            # Built-in Docker network modes, not removable user-defined networks.
            echo "The container uses the built-in network mode <${net}>. Nothing to remove."
            return 0
            ;;
    esac
    if [[ "${keep_network}" == "1" ]]; then
        echo "Keeping the Docker network: <${net}>. You can remove it later with 'docker network rm ${net}'."
        return 0
    fi
    if ! docker network inspect "${net}" >/dev/null 2>&1; then
        echo "The Docker network <${net}> was not found. Nothing to remove."
    else
        local -a users=()
        mapfile -t users < <(docker ps --all --filter "network=${net}" --format '{{.Names}}')
        if (( ${#users[@]} == 0 )); then
            docker network rm "${net}" >/dev/null
            echo "Removed the Docker network: <${net}> (no containers use it)."
        else
            echo "WARNING: ${#users[@]} container(s) still use <${net}> (${users[*]}). The network cannot be removed." >&2
        fi
    fi
}

# --- docker run argument builders ------------------------------------------------

# Append to the array named by $1 the docker run options that give a
# container access to the AMD GPUs: the KFD and DRI devices, the video and
# render groups (when they exist on the host), host IPC, unlimited locked
# memory, a large stack, ptrace, and no seccomp. When GPUS (comma-separated
# IDs) is given, also restrict HIP to those GPUs with HIP_VISIBLE_DEVICES.
docker_gpu_args() {
    local -n _gpu_args_out=$1
    local gpus=${2:-}
    local g gid
    _gpu_args_out+=(--device /dev/kfd --device /dev/dri)
    for g in video render; do
        if gid="$(getent group "${g}" 2>/dev/null | cut --delimiter=: --fields=3)" && [[ -n "${gid}" ]]; then
            _gpu_args_out+=(--group-add "${gid}")
        fi
    done
    _gpu_args_out+=(
        --ipc host
        --ulimit memlock=-1
        --ulimit stack=67108864
        --cap-add SYS_PTRACE
        --security-opt seccomp=unconfined
    )
    if [[ -n "${gpus}" ]]; then
        _gpu_args_out+=(--env "HIP_VISIBLE_DEVICES=${gpus}")
    fi
}

# Append to the array named by $1 the docker run options that run the
# container as the host user (UID:GID), with HOME=/tmp and USER/LOGNAME set
# to the host user name.
docker_host_user_args() {
    local -n _user_args_out=$1
    local username
    username="$(id --user --name)"
    _user_args_out+=(
        --user "$(id --user):$(id --group)"
        --env "HOME=/tmp"
        --env "USER=${username}"
        --env "LOGNAME=${username}"
    )
}
