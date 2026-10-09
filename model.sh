# SPDX-License-Identifier: MIT
# Copyright (c) 2026, Advanced Micro Devices, Inc. All rights reserved.
# shellcheck disable=SC2034 # unused variables

# model.sh - model specification, model-specific vLLM options, and
# model-directory checks.
# Not an executable script. Source it from other scripts: `source model.sh`
#
# MODEL_NAME: model identifier (Qwen/Qwen3.8-27B): the Hugging Face model
# to download, the vLLM --served-model-name (bench_vllm.sh requests the
# same name), and the OpenCode model name.
#
# MODEL_ARGS: model-specific vLLM CLI options, appended by start_vllm.sh.
#
# DEFAULT_MODEL_DIR: default model directory. download_model.sh and
# start_vllm.sh use it unless -m/--model-dir is given.
#
# Helpers:
#   assert_model_dir DIR MODEL_NAME: die unless DIR contains a usable model: a
#                         config.json plus at least one .safetensors weight file.
#                         Called by download_model.sh after the download (to fail
#                         fast) and by start_vllm.sh before launching the vLLM
#                         container.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/common.sh"

MODEL_NAME="Qwen/Qwen3.8-27B"
DEFAULT_MODEL_DIR="${HOME}/models/${MODEL_NAME}"

# Model-specific vLLM CLI options; start_vllm.sh appends "${MODEL_ARGS[@]}".
MODEL_ARGS=(
    --reasoning-parser qwen3
    --tool-call-parser qwen3_xml
    --language-model-only
    --mamba-cache-mode none
)

# Die unless the given model directory holds a usable model: a config.json
# plus at least one .safetensors weight file.
assert_model_dir() {
    local model_dir=$1 model_name=$2
    local -a weights=()
    local remedy="export HF_TOKEN=<your token> && ${script_dir}/download_model.sh"
    if [[ "${model_dir}" != "${DEFAULT_MODEL_DIR}" ]]; then
        remedy+=" --model-dir ${model_dir}"
    fi

    if [[ ! -d "${model_dir}" || ! -f "${model_dir}/config.json" ]]; then
        die "The model ${model_name} was not found in <${model_dir}> (missing directory or config.json). Download it: ${remedy}"
    fi
    shopt -s nullglob
    weights=("${model_dir}"/*.safetensors)
    shopt -u nullglob
    (( ${#weights[@]} )) \
        || die "The model ${model_name} in <${model_dir}> has no .safetensors weights. Re-download it: ${remedy}"
}
