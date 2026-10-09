#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026, Advanced Micro Devices, Inc. All rights reserved.

# start_vllm.sh - start (or restart) the vLLM OpenAI-compatible server as a
# long-lived Docker container, then sanity-check the API from the host and
# from the isolated Docker network.
#
# Environment overrides:
#   VLLM_GPUS   comma-separated GPU IDs for vLLM (default: the GPUs of the
#               existing vLLM container, if any, otherwise resolved by
#               device.sh). If the existing container was created with other
#               GPUs, it is recreated.
#   DEV_GPUS    comma-separated GPU IDs for the dev container
#               (default: the GPUs of the dev container, if it exists,
#               otherwise resolved by device.sh)
#   VLLM_IMAGE  container image (default: vllm/vllm-openai-rocm:latest,
#               see vllm.sh)
#
# CLI arguments: see the usage() function below (also printed by --help).
#
# Requires: docker, curl, and jq, plus the requirements of device_init
# (rocm-smi, awk).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/common.sh"
source "${script_dir}/docker.sh"
source "${script_dir}/model.sh"
source "${script_dir}/device.sh"
source "${script_dir}/vllm.sh"
source "${script_dir}/dev.sh"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Start (or restart) the vLLM OpenAI-compatible server as a long-lived Docker
container, then sanity-check the API from the host and from the isolated
Docker network.

Options:
  -m, --model-dir DIR    model directory (default: ${DEFAULT_MODEL_DIR})
  -v, --vllm-container NAME
                         vLLM container name (default: <user>_vllm)
  -d, --dev-container NAME
                         dev container whose GPUs are reserved
                         (default: <user>_dev)
  -n, --network NAME     Docker network name (default: <user>_llm_net)
  -p, --port PORT        port for the vLLM server, on the host and in the
                         container (default: ${DEFAULT_VLLM_PORT})
  -C, --cache-dir DIR    host directory for the vLLM cache (default: ~/vllm_cache)
  -t, --timeout SECONDS  seconds to wait for vLLM to become ready (default: 600)
  -h, --help             print this help and exit
EOF
}

# Parse the CLI arguments, setting the globals model_dir, vllm_port,
# vllm_name, dev_name, llm_net, vllm_cache, and vllm_timeout. All but
# model_dir stay empty when not given; main fills vllm_name and dev_name,
# and resolve_config the others, with the defaults.
parse_args() {
    model_dir="${DEFAULT_MODEL_DIR}"
    vllm_port=""
    vllm_name=""
    dev_name=""
    llm_net=""
    vllm_cache=""
    vllm_timeout=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--model-dir)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                model_dir="$2"
                shift 2
                ;;
            -v|--vllm-container)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                vllm_name="$2"
                shift 2
                ;;
            -d|--dev-container)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                dev_name="$2"
                shift 2
                ;;
            -n|--network)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                llm_net="$2"
                shift 2
                ;;
            -p|--port)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                vllm_port="$2"
                shift 2
                ;;
            -C|--cache-dir)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                vllm_cache="$2"
                shift 2
                ;;
            -t|--timeout)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                vllm_timeout="$2"
                shift 2
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

# Resolve the runtime configuration: fill the unset CLI values (llm_net,
# vllm_cache, vllm_timeout) with the defaults from vllm.sh, create the cache
# directory, resolve and validate the port and the startup timeout, and
# derive the tensor parallelism from the GPU partition. Sets the globals
# vllm_port and vllm_tp.
resolve_config() {
    local -a vllm_gpu_list=()

    llm_net="${llm_net:-${DEFAULT_LLM_NET}}"
    vllm_cache="${vllm_cache:-${DEFAULT_VLLM_CACHE}}"
    vllm_cache="$(abs_path "${vllm_cache}")"
    vllm_timeout="${vllm_timeout:-${DEFAULT_VLLM_STARTUP_TIMEOUT}}"

    mkdir --parents "${vllm_cache}"

    vllm_port="$(resolve_vllm_port "${vllm_port}")"

    vllm_timeout="$(check_positive_int "startup timeout" "${vllm_timeout}")"

    [[ -n "${VLLM_GPUS}" ]] \
        || die "No GPUs are left for vLLM (dev GPUs: <${DEV_GPUS}>). Set VLLM_GPUS, or give the dev container fewer GPUs."
    IFS=',' read -r -a vllm_gpu_list <<< "${VLLM_GPUS}"
    vllm_tp=${#vllm_gpu_list[@]}
    echo "vLLM GPUs: <${VLLM_GPUS}> (tensor parallelism: ${vllm_tp})."

    # Power-of-2 test: n & (n - 1) clears the lowest set bit of n, so the
    # result is 0 iff n has exactly one bit set (n > 0 is required, as
    # 0 & -1 is also 0).
    (( vllm_tp > 0 && (vllm_tp & (vllm_tp - 1)) == 0 )) \
        || die "Tensor parallelism ${vllm_tp} (vLLM GPUs: <${VLLM_GPUS}>) is not supported. It must be a power of 2. Set VLLM_GPUS to 1, 2, 4, or 8 GPU IDs."
}

# If VLLM_GPUS is not set and the given vLLM container exists, reuse the GPUs
# it was created with, so restarting it does not depend on how the remaining
# GPUs would be split today.
reuse_vllm_gpus() {
    local vllm_name=$1
    local gpus
    [[ -z "${VLLM_GPUS:-}" ]] || return 0
    gpus="$(container_gpus "${vllm_name}")"
    if [[ -n "${gpus}" ]]; then
        VLLM_GPUS="${gpus}"
        echo "Reusing the GPUs of the existing vLLM container <${vllm_name}>: <${gpus}>."
    fi
}

# If DEV_GPUS is not set and the dev container exists, reserve its GPUs as
# DEV_GPUS, so device_init gives vLLM only GPUs the dev container does not
# use (and dies if VLLM_GPUS overlaps them). A missing dev container is not
# an error: no GPUs are reserved.
reserve_dev_gpus() {
    local dev_name=$1
    local gpus
    [[ -z "${DEV_GPUS:-}" ]] || return 0
    if [[ -z "$(container_state "${dev_name}")" ]]; then
        echo "The dev container <${dev_name}> was not found. No GPUs are reserved for it."
        return 0
    fi
    gpus="$(container_gpus "${dev_name}")"
    if [[ -n "${gpus}" ]]; then
        DEV_GPUS="${gpus}"
        echo "Reserving the GPUs of the dev container <${dev_name}>: <${gpus}>."
    else
        echo "WARNING: The dev container <${dev_name}> sees every GPU. vLLM will share GPUs with it." >&2
    fi
}

# Create the vLLM container from scratch on the given network, mounting the
# given cache directory.
create_container() {
    local name=$1 net=$2 cache_dir=$3
    local -a docker_args=(
        # Container
        --detach
        --name "${name}"
        # Networking
        --network "${net}"
        --network-alias vllm
        --publish "127.0.0.1:${vllm_port}:${vllm_port}"
    )
    # Devices, resources, and security
    docker_gpu_args docker_args "${VLLM_GPUS}"
    # User
    docker_host_user_args docker_args
    docker_args+=(
        # Environment
        --env "VLLM_ROCM_USE_AITER=1"
        --env "SAFETENSORS_FAST_GPU=1"
        # Storage
        --volume "${model_dir}:/model:ro"
        --volume "${cache_dir}:/tmp/.cache/vllm"
    )

    docker run "${docker_args[@]}" \
        "${DEFAULT_VLLM_IMAGE}" \
        --port "${vllm_port}" \
        --model /model \
        --served-model-name "${MODEL_NAME}" \
        --tensor-parallel-size "${vllm_tp}" \
        --max-model-len auto \
        --gpu-memory-utilization 0.95 \
        --enable-auto-tool-choice \
        --enable-prefix-caching \
        "${MODEL_ARGS[@]}"
}

# Startup predicate for wait_until: the container must still be running and
# the API must answer. Prints a progress note every 60 seconds.
vllm_startup_check() {
    local name=$1 port=$2
    local state
    state="$(container_state "${name}")"
    [[ "${state}" == "running" ]] \
        || die_with_docker_logs "${name}" "The container <${name}> stopped during startup (state: ${state:-missing})."
    if vllm_reachable "${port}"; then
        return 0
    fi
    if (( WAIT_UNTIL_ELAPSED >= vllm_next_note )); then
        echo "  Still waiting: ${WAIT_UNTIL_ELAPSED}s elapsed. The first start loads weights and compiles kernels, which is normal."
        vllm_next_note=$(( vllm_next_note + 60 ))
    fi
    return 1
}

# Print how the existing given container differs from the requested
# configuration (port, GPUs, network, model directory, cache directory), or
# nothing if it matches.
vllm_config_mismatch() {
    local name=$1 net=$2 cache_dir=$3
    local value
    value="$(container_host_port "${name}")"
    if [[ "${value}" != "${vllm_port}" ]]; then
        echo "the host port <${value:-none}> instead of <${vllm_port}>"
        return 0
    fi
    value="$(container_gpus "${name}")"
    if ! gpu_sets_equal "${value}" "${VLLM_GPUS}"; then
        echo "the GPUs <${value:-all}> instead of <${VLLM_GPUS}>"
        return 0
    fi
    value="$(container_network "${name}")"
    if [[ "${value}" != "${net}" ]]; then
        echo "the network <${value}> instead of <${net}>"
        return 0
    fi
    value="$(container_mount_source "${name}" /model)"
    if [[ "${value}" != "${model_dir}" ]]; then
        echo "the model directory <${value:-none}> instead of <${model_dir}>"
        return 0
    fi
    value="$(container_mount_source "${name}" /tmp/.cache/vllm)"
    if [[ "${value}" != "${cache_dir}" ]]; then
        echo "the cache directory <${value:-none}> instead of <${cache_dir}>"
        return 0
    fi
}

# Bring the vLLM container to the running state: skip startup if it is
# already running and matches the requested port, GPUs, network, model
# directory, and cache directory; die if it is running with a different
# configuration; start it if it is stopped and matches; recreate it if it is
# stopped with a different configuration. Wait for readiness.
start_container() {
    local name=$1 net=$2 cache_dir=$3 timeout=$4
    local state mismatch=""

    state="$(container_state "${name}")"
    if [[ -n "${state}" ]]; then
        mismatch="$(vllm_config_mismatch "${name}" "${net}" "${cache_dir}")"
    fi

    if [[ "${state}" == "running" ]]; then
        [[ -z "${mismatch}" ]] \
            || die "The container <${name}> is already running with ${mismatch}. Stop it first (docker stop ${name}), or re-run with options that match it."
        echo "The container <${name}> is already running. Skipping startup."
        return 0
    fi

    if port_in_use "${vllm_port}"; then
        die "The port <${vllm_port}> is already in use on the host. Pick a free port with --port PORT."
    fi

    if [[ -z "${state}" ]]; then
        echo "The container <${name}> was not found. Pulling <${DEFAULT_VLLM_IMAGE}> and creating it ..."
        docker_pull_image "${DEFAULT_VLLM_IMAGE}"
        create_container "${name}" "${net}" "${cache_dir}"
    elif [[ -n "${mismatch}" ]]; then
        echo "The container <${name}> was created with ${mismatch}. Removing and recreating it ..."
        docker rm "${name}" >/dev/null
        docker_pull_image "${DEFAULT_VLLM_IMAGE}"
        create_container "${name}" "${net}" "${cache_dir}"
    else
        echo "The container <${name}> is stopped. Starting it ..."
        docker start "${name}" >/dev/null
    fi

    wait_for_ready "${name}" "${timeout}"
}

# Wait for vLLM to become ready. The first start is slow: it loads the model
# weights and compiles GPU kernels.
wait_for_ready() {
    local name=$1 timeout=$2
    # Elapsed second of the next progress note (a global; the predicate runs
    # in this shell).
    vllm_next_note=60
    echo "Waiting up to ${timeout}s for vLLM to become ready on <127.0.0.1:${vllm_port}> ..."
    if wait_until "${timeout}" 4 vllm_startup_check "${name}" "${vllm_port}"; then
        echo "vLLM is ready (${WAIT_UNTIL_ELAPSED}s)."
    else
        die_with_docker_logs "${name}" "vLLM was not ready after ${timeout}s. Increase the startup timeout (--timeout) if startup genuinely takes longer."
    fi
}

# Sanity check the API from the host: health, model listing, and a chat
# completion.
sanity_check_host() {
    local port=$1 model=$2
    local base="http://127.0.0.1:${port}"
    local body

    echo "Sanity check [host]: GET <${base}/health> and <${base}/v1/models>."
    assert_vllm_serving "${port}" "${model}"
    echo "  OK: ${model} is served."

    echo "Sanity check [host]: POST <${base}/v1/chat/completions>."
    body="$(curl --fail --silent --show-error --max-time 300 --request POST \
        "${base}/v1/chat/completions" \
        --header 'Content-Type: application/json' \
        --data "$(jq --null-input --arg model "${model}" '{model: $model, messages: [{role: "user", content: "Reply with exactly one word: pong."}], max_tokens: 16, temperature: 0}')")" \
        || die "The chat completion request failed."
    jq --exit-status '.choices | length > 0' >/dev/null <<<"${body}" \
        || die "The chat completion response contains no choices: ${body}."
    echo "  OK: The chat completion returned a response."
}

# Sanity check the API from a temporary container on the isolated network.
sanity_check_network() {
    local net=$1 port=$2 model=$3
    echo "Sanity check [${net}]: Chat completion from a temporary container via <http://vllm:${port}>."
    docker_ensure_image python:3.12-slim
    docker run --rm --interactive \
        --network "${net}" \
        --env "MODEL_NAME=${model}" \
        --env "VLLM_PORT=${port}" \
        python:3.12-slim \
        python - <<'PY' || die "The chat completion from a container on <${net}> failed (see the Python error above)."
import json
import os
import urllib.request

body = {
    "model": os.environ["MODEL_NAME"],
    "messages": [{"role": "user", "content": "Reply with exactly one word: pong."}],
    "max_tokens": 256,
    "temperature": 0,
}
req = urllib.request.Request(
    f"http://vllm:{os.environ['VLLM_PORT']}/v1/chat/completions",
    data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=300) as resp:
    result = json.load(resp)
msg = result["choices"][0]["message"]
content = msg.get("content")
if content is None:
    # Reasoning parser: the budget was spent on thinking, so content is null.
    content = msg.get("reasoning_content") or msg.get("reasoning") or ""
print("  OK: The in-network chat completion returned", repr(content.strip()), "(expected answer: 'pong').")
PY
}

print_summary() {
    local name=$1 net=$2
    echo
    echo "vLLM is up:"
    echo "  container:    <${name}>."
    echo "  host URL:     <http://127.0.0.1:${vllm_port}/v1>."
    echo "  network URL:  <http://vllm:${vllm_port}/v1> (for containers on <${net}>)."
    echo "  model:        ${MODEL_NAME}."
}

main() {
    parse_args "$@"
    model_dir="$(abs_path "${model_dir}")"

    check_curl
    check_jq
    vllm_init
    dev_configure

    vllm_name="${vllm_name:-${DEFAULT_VLLM_NAME}}"
    dev_name="${dev_name:-${DEFAULT_DEV_NAME}}"

    reuse_vllm_gpus "${vllm_name}"
    reserve_dev_gpus "${dev_name}"
    device_init

    assert_model_dir "${model_dir}" "${MODEL_NAME}"
    echo "Model: ${MODEL_NAME} from <${model_dir}>."

    resolve_config
    network_ensure "${llm_net}"
    start_container "${vllm_name}" "${llm_net}" "${vllm_cache}" "${vllm_timeout}"
    sanity_check_host "${vllm_port}" "${MODEL_NAME}"
    sanity_check_network "${llm_net}" "${vllm_port}" "${MODEL_NAME}"
    print_summary "${vllm_name}" "${llm_net}"
}

main "$@"
