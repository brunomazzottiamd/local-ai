#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026, Advanced Micro Devices, Inc. All rights reserved.

# download_model.sh - download ${MODEL_NAME} from the Hugging Face Hub into a
# model directory (default: ${DEFAULT_MODEL_DIR}, see model.sh) using a
# throwaway python:3.12-slim container, then verify the result (config.json
# and .safetensors weights) so a broken download fails fast here instead of
# later in start_vllm.sh.
#
# CLI arguments: see the usage() function below (also printed by --help).
#
# Requires: docker and access to the Hugging Face Hub (set HF_TOKEN to
# authenticate, if needed).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/common.sh"
source "${script_dir}/docker.sh"
source "${script_dir}/model.sh"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Download ${MODEL_NAME} from the Hugging Face Hub into a model directory using
a throwaway python:3.12-slim container, then verify the result so a broken
download fails fast here instead of later in start_vllm.sh.

Options:
  -m, --model-dir DIR    model directory (default: ${DEFAULT_MODEL_DIR})
  -h, --help             print this help and exit
EOF
}

# Parse the CLI arguments, setting the global model_dir.
parse_args() {
    model_dir="${DEFAULT_MODEL_DIR}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--model-dir)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                model_dir="$2"
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

# Pull the helper image and run the Hugging Face download in a throwaway
# container with the model directory mounted.
download_model() {
    local docker_image='python:3.12-slim'
    local -a docker_args=(
        --rm
        --init
        --volume "${model_dir}:/model"
        --env "HOST_UID=$(id --user)"
        --env "HOST_GID=$(id --group)"
        --env "MODEL_NAME=${MODEL_NAME}"
    )

    if [[ -n "${HF_TOKEN:-}" ]]; then
        echo "HF_TOKEN is set. Authenticating with the Hugging Face Hub."
        docker_args+=(--env HF_TOKEN)
    else
        echo "WARNING: HF_TOKEN is not set. Unauthenticated Hugging Face Hub downloads may be rate limited." >&2
    fi

    docker_ensure_image "${docker_image}"
    docker run "${docker_args[@]}" \
        "${docker_image}" \
        bash -c '
            set -euo pipefail
            pip install --root-user-action ignore --quiet --upgrade pip huggingface_hub
            HF_HUB_DISABLE_UPDATE_CHECK=1 hf download "${MODEL_NAME}" --local-dir /model
            chown --recursive "${HOST_UID}:${HOST_GID}" /model
        ' || die "Failed to download the model ${MODEL_NAME} into <${model_dir}>."
}

main() {
    parse_args "$@"
    model_dir="$(abs_path "${model_dir}")"

    check_docker

    echo "Model: ${MODEL_NAME}."
    echo "Target directory: <${model_dir}>."

    mkdir --parents "${model_dir}"

    download_model

    assert_model_dir "${model_dir}" "${MODEL_NAME}"
}

main "$@"
