#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026, Advanced Micro Devices, Inc. All rights reserved.

# install_opencode.sh - install the OpenCode agent harness in the running
# development container, configure it to use the model served by the vLLM
# container over the shared Docker network, and, if vLLM is up, sanity-check
# it with a one-shot opencode run inside the dev container.
#
# OpenCode is installed under ~/.opencode/bin of the container user, which is
# added to PATH in ~/.bashrc. The config is written to
# ~/.config/opencode/opencode.json; a different existing config is backed up
# to opencode.json.bak first. The vLLM port is the one published by the vLLM
# container (DEFAULT_VLLM_PORT if the container is missing).
#
# Both an executable script and a library: start_dev.sh sources it and calls
# opencode_install directly. Sourcing it also defines usage, parse_args, and
# main, which the sourcing script overrides with its own.
#
# CLI arguments: see the usage() function below (also printed by --help).
#
# Requires: docker on the host; curl and tar in the dev container.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/common.sh"
source "${script_dir}/docker.sh"
source "${script_dir}/model.sh"
source "${script_dir}/vllm.sh"
source "${script_dir}/dev.sh"

# OpenCode release installed in the dev container.
OPENCODE_VERSION="1.18.30"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Install the OpenCode agent harness in the running development container,
configure it to use the model served by the vLLM container, and, if vLLM is
up, sanity-check it with a one-shot opencode run inside the dev container.

Options:
  -d, --dev-container NAME   dev container name (default: <user>_dev)
  -v, --vllm-container NAME  vLLM container whose port is used and whose
                             API is checked (default: <user>_vllm)
  -h, --help                 print this help and exit
EOF
}

# Parse the CLI arguments into the variables named by $1 (dev container name)
# and $2 (vLLM container name), left empty when not given; main fills them
# with the defaults.
parse_args() {
    local -n _dev_name_out=$1 _vllm_name_out=$2
    shift 2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dev-container)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                _dev_name_out="$2"
                shift 2
                ;;
            -v|--vllm-container)
                [[ $# -ge 2 ]] || die "The option ${1} requires a value."
                _vllm_name_out="$2"
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

# Die unless the given dev container is running. It is never started here,
# because start_dev.sh also resolves its GPUs and network.
opencode_assert_dev_running() {
    local name=$1
    local state start="${script_dir}/start_dev.sh"
    if [[ "${name}" != "${DEFAULT_DEV_NAME}" ]]; then
        start+=" --dev-container ${name}"
    fi
    state="$(container_state "${name}")"
    [[ -n "${state}" ]] \
        || die "The dev container <${name}> was not found. Create it first: ${start}"
    [[ "${state}" == "running" ]] \
        || die "The dev container <${name}> is not running (state: ${state}). Start it first: ${start}"
}

# Port the vLLM server listens on in the Docker network: the host port
# published by the given vLLM container, even while it is stopped
# (start_vllm.sh publishes the same port on the host and in the container).
# Fall back to DEFAULT_VLLM_PORT if the container is missing or publishes no
# port. Print the port to stdout; info notes go to stderr.
opencode_vllm_port() {
    local vllm_name=$1
    local port
    port="$(container_host_port "${vllm_name}")"
    if [[ -n "${port}" ]]; then
        echo "Using the port of the vLLM container <${vllm_name}>: <${port}>." >&2
    else
        port=${DEFAULT_VLLM_PORT}
        echo "The vLLM container <${vllm_name}> was not found or publishes no port. Using the default port: <${port}>." >&2
    fi
    printf '%s\n' "${port}"
}

# Install the given OpenCode version in the given container, under
# ~/.opencode/bin of the container user, skipping the download when that
# version is already there, and add that directory to PATH in ~/.bashrc
# (once). Die if the container lacks curl or tar, or if the installation
# fails.
opencode_install_binary() {
    local name=$1 version=$2
    docker exec "${name}" bash -c '
        set -euo pipefail
        version=$1
        bin_dir="${HOME}/.opencode/bin"
        path_line="export PATH=${bin_dir}:\$PATH"
        for cmd in curl tar; do
            if ! command -v "${cmd}" >/dev/null 2>&1; then
                echo "error: The command ${cmd} was not found in the container." >&2
                exit 1
            fi
        done
        if [[ "$("${bin_dir}/opencode" --version 2>/dev/null || true)" == "${version}" ]]; then
            echo "OpenCode ${version} is already installed in <${bin_dir}>. Skipping the download."
        else
            echo "Installing OpenCode ${version} in <${bin_dir}> ..."
            if ! log="$(curl --fail --silent --show-error --location https://opencode.ai/install \
                    | bash -s -- --version "${version}" --no-modify-path 2>&1)"; then
                printf "%s\n" "${log}" >&2
                exit 1
            fi
            installed="$("${bin_dir}/opencode" --version 2>/dev/null || true)"
            if [[ "${installed}" != "${version}" ]]; then
                echo "error: The installed OpenCode reports the version <${installed}>, not <${version}>." >&2
                exit 1
            fi
        fi
        touch "${HOME}/.bashrc"
        if ! grep --quiet --fixed-strings --line-regexp "${path_line}" "${HOME}/.bashrc"; then
            printf "\n# opencode\n%s\n" "${path_line}" >> "${HOME}/.bashrc"
            echo "Added <${bin_dir}> to PATH in <${HOME}/.bashrc>."
        fi
    ' _ "${version}" \
        || die "Failed to install OpenCode ${version} in the container <${name}>."
}

# Print the OpenCode config that uses the given model, served by vLLM on the
# given port of the Docker network.
opencode_config() {
    local model=$1 port=$2
    cat <<EOF
{
    "\$schema": "https://opencode.ai/config.json",
    "model": "vllm/${model}",
    "provider": {
        "vllm": {
            "npm": "@ai-sdk/openai-compatible",
            "name": "Local vLLM",
            "options": {
                "baseURL": "http://vllm:${port}/v1"
            },
            "models": {
                "${model}": {
                    "name": "${model}",
                    "tool_call": true
                }
            }
        }
    }
}
EOF
}

# Write the OpenCode config for the given model and vLLM port to
# ~/.config/opencode/opencode.json in the given container. An existing,
# different config is backed up to opencode.json.bak first.
opencode_write_config() {
    local name=$1 model=$2 port=$3
    opencode_config "${model}" "${port}" | docker exec --interactive "${name}" bash -c '
        set -euo pipefail
        dir="${HOME}/.config/opencode"
        config="${dir}/opencode.json"
        new="$(cat)"
        mkdir --parents "${dir}"
        if [[ -f "${config}" ]]; then
            if [[ "$(cat "${config}")" == "${new}" ]]; then
                echo "The OpenCode config <${config}> is up to date."
                exit 0
            fi
            cp "${config}" "${config}.bak"
            echo "WARNING: Replacing the OpenCode config <${config}>. The previous one was saved to <${config}.bak>." >&2
        fi
        printf "%s\n" "${new}" > "${config}"
        echo "Wrote the OpenCode config <${config}>."
    ' || die "Failed to write the OpenCode config in the container <${name}>."
}

# Sanity check that OpenCode inside the given dev container gets an answer
# from the model served on the given vLLM port. Skipped (with a note) when the
# vLLM container is not running or not reachable from the dev container; dies
# if opencode run fails.
opencode_sanity_check() {
    local name=$1 vllm_name=$2 port=$3
    local base="http://vllm:${port}"
    local prompt="Reply with exactly one word: pong."
    local output

    if [[ "$(container_state "${vllm_name}")" != "running" ]]; then
        echo "The vLLM container <${vllm_name}> is not running. Skipping the OpenCode check. Start it with: ${script_dir}/start_vllm.sh"
        return 0
    fi
    if ! docker exec "${name}" curl --fail --silent --max-time 5 --output /dev/null "${base}/health"; then
        echo "WARNING: vLLM is not reachable from <${name}> at <${base}/health> (still starting, or on another network). Skipping the OpenCode check." >&2
        return 0
    fi

    echo "Sanity check [${name}]: opencode run via <${base}/v1>."
    output="$(docker exec "${name}" bash -c '
        timeout 300 "${HOME}/.opencode/bin/opencode" run "$1" </dev/null
    ' _ "${prompt}" 2>&1)" \
        || die "The command opencode run failed inside <${name}>. Its output: ${output}"
    if grep --quiet --ignore-case pong <<<"${output}"; then
        echo "  OK: OpenCode got an answer from the model."
    else
        echo "WARNING: opencode run succeeded inside <${name}>, but the answer does not contain 'pong': ${output}" >&2
    fi
}

# Print a summary of the OpenCode installation in the given dev container.
opencode_print_summary() {
    local name=$1 version=$2 model=$3 port=$4
    echo
    echo "OpenCode is installed:"
    echo "  container:    <${name}>."
    echo "  version:      ${version}."
    echo "  model:        vllm/${model}."
    echo "  vLLM URL:     <http://vllm:${port}/v1>."
    echo "Run it with: docker exec --interactive --tty ${name} bash, then: opencode"
}

# Install and configure OpenCode in the given running dev container, using the
# port of the given vLLM container, then sanity-check it. Library entry point
# (used by start_dev.sh); expects vllm_init and dev_configure to have run.
opencode_install() {
    local dev_name=$1 vllm_name=$2
    local port

    opencode_assert_dev_running "${dev_name}"
    port="$(opencode_vllm_port "${vllm_name}")"
    opencode_install_binary "${dev_name}" "${OPENCODE_VERSION}"
    opencode_write_config "${dev_name}" "${MODEL_NAME}" "${port}"
    opencode_sanity_check "${dev_name}" "${vllm_name}" "${port}"
    opencode_print_summary "${dev_name}" "${OPENCODE_VERSION}" "${MODEL_NAME}" "${port}"
}

main() {
    local dev_name="" vllm_name=""
    parse_args dev_name vllm_name "$@"

    vllm_init
    dev_configure

    dev_name="${dev_name:-${DEFAULT_DEV_NAME}}"
    vllm_name="${vllm_name:-${DEFAULT_VLLM_NAME}}"

    opencode_install "${dev_name}" "${vllm_name}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
