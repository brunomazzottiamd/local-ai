#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026, Advanced Micro Devices, Inc. All rights reserved.

# bench_vllm.sh - run a serving benchmark against the local vLLM server with
# vllm-bench (https://github.com/vllm-project/vllm-bench).
#
# The server must be the container created by start_vllm.sh: the port is
# read from that container.
#
# The vllm-bench binary is downloaded on demand into the script directory.
#
# CLI arguments: see the usage() function below (also printed by --help).
#
# Requires: docker, curl, and jq, and a running vLLM server (see start_vllm.sh).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/common.sh"
source "${script_dir}/docker.sh"
source "${script_dir}/model.sh"
source "${script_dir}/vllm.sh"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Run a serving benchmark against the local vLLM server with vllm-bench. The
server must be the container created by start_vllm.sh: the port is read from
that container.

Options:
  -i, --input-len N       random input length, in tokens (default: 1024)
  -o, --output-len N      random output length, in tokens (default: 1024)
  -N, --num-prompts N     number of prompts to send (default: 40)
  -M, --max-concurrency N maximum concurrent requests (default: 4)
  -v, --vllm-container NAME
                          vLLM container name (default: <user>_vllm)
  -h, --help              print this help and exit
EOF
}

# Parse the CLI arguments, setting the globals input_len, output_len,
# num_prompts, max_concurrency, and vllm_name (empty when -v is not given;
# main fills it with the default).
parse_args() {
    input_len=1024
    output_len=1024
    num_prompts=40
    max_concurrency=4
    vllm_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--input-len)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                input_len="$2"
                shift 2
                ;;
            -o|--output-len)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                output_len="$2"
                shift 2
                ;;
            -N|--num-prompts)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                num_prompts="$2"
                shift 2
                ;;
            -M|--max-concurrency)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                max_concurrency="$2"
                shift 2
                ;;
            -v|--vllm-container)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                vllm_name="$2"
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

# Validate and canonicalize the benchmark parameters (global variables).
validate_params() {
    num_prompts="$(check_positive_int num_prompts "${num_prompts}")"
    max_concurrency="$(check_positive_int max_concurrency "${max_concurrency}")"
    input_len="$(check_positive_int input_len "${input_len}")"
    output_len="$(check_positive_int output_len "${output_len}")"
}

# Return 0 if $1 is a non-empty file whose first four bytes are the ELF magic.
is_elf() {
    [[ -s "$1" ]] && [[ "$(head --bytes=4 -- "$1" 2>/dev/null)" == $'\x7fELF' ]]
}

# Make sure the vllm-bench binary is available, downloading it on demand.
# Sets the global vllm_bench_bin.
ensure_vllm_bench() {
    local arch url tmp vllm_bench_version vllm_bench_url_base
    vllm_bench_bin="${script_dir}/vllm-bench"
    vllm_bench_url_base="https://github.com/vllm-project/vllm-bench/releases/latest/download"

    if [[ -x "${vllm_bench_bin}" ]]; then
        echo "The vllm-bench binary is already available: <${vllm_bench_bin}>."
        return 0
    fi

    arch="$(uname --machine)"
    case "${arch}" in
        x86_64|aarch64) ;;
        *) die "The architecture ${arch} is not supported. No vllm-bench release exists for it." ;;
    esac
    url="${vllm_bench_url_base}/vllm-bench-${arch}-linux-musl"
    echo "Downloading vllm-bench from <${url}> ..."
    tmp="${vllm_bench_bin}.tmp.$$"
    trap 'rm --force -- "${tmp}"' EXIT
    if ! curl --fail --silent --show-error --location \
        --retry 3 \
        --output "${tmp}" \
        "${url}"; then
        die "Failed to download vllm-bench from <${url}>."
    fi
    if ! is_elf "${tmp}"; then
        die "The downloaded file is not an ELF executable. The download is incomplete or corrupt."
    fi
    chmod +x -- "${tmp}"
    if ! vllm_bench_version="$( "${tmp}" --version 2>/dev/null )"; then
        die "The downloaded file fails the --version sanity check. The download is incomplete or corrupt."
    fi
    mv -- "${tmp}" "${vllm_bench_bin}"
    trap - EXIT
    echo "Downloaded vllm-bench <${vllm_bench_bin}> (version ${vllm_bench_version})."
}

# Die unless the vLLM server at the given port is up and serving MODEL_NAME.
check_server() {
    local port=$1
    local base_url="http://127.0.0.1:${port}"
    echo "Checking the vLLM server at <${base_url}> ..."
    assert_vllm_serving "${port}" "${MODEL_NAME}"
    echo "The server is up and serving ${MODEL_NAME}."
}

# Run the vllm-bench client against the server at the given port.
run_bench() {
    local port=$1
    local base_url="http://127.0.0.1:${port}"

    echo
    echo "Running the vLLM serving benchmark:"
    echo "  base URL:        <${base_url}>."
    echo "  model:           ${MODEL_NAME}."
    echo "  dataset:         random (<${input_len}> input / <${output_len}> output tokens)."
    echo "  prompts:         <${num_prompts}>."
    echo "  max concurrency: <${max_concurrency}>."
    echo

    "${vllm_bench_bin}" \
        --backend vllm \
        --base-url "${base_url}" \
        --model "${MODEL_NAME}" \
        --dataset-name random \
        --random-input-len "${input_len}" \
        --random-output-len "${output_len}" \
        --num-prompts "${num_prompts}" \
        --max-concurrency "${max_concurrency}"
}

main() {
    parse_args "$@"
    validate_params

    check_curl
    check_jq
    vllm_init

    vllm_name="${vllm_name:-${DEFAULT_VLLM_NAME}}"

    local vllm_port
    vllm_port="$(vllm_host_port "${vllm_name}")"

    ensure_vllm_bench
    check_server "${vllm_port}"
    run_bench "${vllm_port}"
}

main "$@"
