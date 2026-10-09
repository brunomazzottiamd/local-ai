# SPDX-License-Identifier: MIT
# Copyright (c) 2026, Advanced Micro Devices, Inc. All rights reserved.
# shellcheck disable=SC2034 # DEV_GPUS and VLLM_GPUS are written for the caller

# device.sh - GPU device identification and partitioning.
# Not an executable script. Source it from other scripts: `source device.sh`
#
# Sourcing this file has no side effects: no dependency checks and no GPU
# discovery run at source time. Call device_init before using DEV_GPUS and
# VLLM_GPUS (start_vllm.sh and start_dev.sh do this).
#
# Requires: rocm-smi and awk (both are checked by device_init).
#
# Partitioning:
#   DEV_GPUS and VLLM_GPUS (comma-separated device IDs, e.g. "0,1,2,3") may be
#   defined before calling device_init to control the partition:
#     - neither defined -> even split of all detected GPUs: first half to DEV,
#                          second half to VLLM
#     - only DEV_GPUS   -> VLLM_GPUS becomes the remaining GPUs
#     - only VLLM_GPUS  -> DEV_GPUS becomes the remaining GPUs
#     - both defined    -> both are used exactly as given
#   A sanity check runs last: every ID must be a valid device and DEV_GPUS and
#   VLLM_GPUS must not overlap; on failure, device_init dies.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/common.sh"

# --- Dependencies -------------------------------------------------------------

# Check that awk is available.
check_awk() { require_cmd awk; }

# Check that rocm-smi is available.
check_rocm_smi() { require_cmd rocm-smi; }

# --- Identification -----------------------------------------------------------

# Print the ID of every GPU device (one per line, e.g. 0..7), as reported by
# rocm-smi. The IDs are parsed from the structured CSV output of
# `rocm-smi --showid --csv`, whose first column names the devices (card0, card1, ...).
gpu_list_ids() {
    rocm-smi --showid --csv 2>/dev/null |
        awk -F',' '$1 ~ /^card[0-9]+$/ { sub(/^card/, "", $1); print $1 }'
}

# --- Partitioning helpers -----------------------------------------------------

# Print the IDs in a comma-separated string, one per line. Tokens are trimmed
# of surrounding whitespace and empty tokens are dropped.
gpu_split_ids() {
    local input=$1
    local IFS=','
    local -a tokens=()
    read -ra tokens <<< "$input"
    local t
    for t in ${tokens[@]+"${tokens[@]}"}; do
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        [[ -n "$t" ]] && printf '%s\n' "$t"
    done
}

# Populate the associative array named by $1 (id -> 1) with the IDs of the
# comma-separated string $2. The name must reference an existing associative
# array in scope (resolved via bash nameref).
gpu_ids_to_set() {
    local -n set_ref=$1
    local id
    # Through a nameref, a bare subscript is stored as a literal key, so the
    # $ on id is required.
    # shellcheck disable=SC2004
    while IFS= read -r id; do set_ref[$id]=1; done < <(gpu_split_ids "$2")
}

# Print the non-empty IDs given as arguments, comma-separated.
gpu_join_ids() {
    local -a ids=()
    local id
    for id in "$@"; do
        [[ -n "$id" ]] && ids+=("$id")
    done
    (( ${#ids[@]} )) || return 0
    local IFS=','
    printf '%s\n' "${ids[*]}"
}

# Canonical form of a comma-separated GPU ID list: unique, numerically
# sorted, comma-joined (e.g. "7, 2" -> "2,7"). Empty in, empty out.
gpu_canonical() {
    local id
    local -a ids=()
    while IFS= read -r id; do
        ids+=("${id}")
    done < <(gpu_split_ids "${1:-}" | sort --unique --numeric-sort)
    local IFS=','
    printf '%s' "${ids[*]}"
}

# Whether the two comma-separated GPU ID strings name the same set of GPUs:
# order, whitespace, and duplicates are ignored, and two empty strings match.
gpu_sets_equal() {
    [[ "$(gpu_canonical "${1:-}")" == "$(gpu_canonical "${2:-}")" ]]
}

# Populate the associative array named by $2 (id -> 1) from the indexed array
# named by $1.
# Through a nameref, a bare subscript is stored as a literal key, so the $ on
# id is required.
# shellcheck disable=SC2004
gpu_build_universe() {
    local -n _gbu_ids=$1
    local -n _gbu_universe=$2
    local id
    for id in ${_gbu_ids[@]+"${_gbu_ids[@]}"}; do
        _gbu_universe[$id]=1
    done
}

# Resolve DEV_GPUS and VLLM_GPUS, honoring values defined before device_init
# was called (see the file header for the exact rules). $1: indexed array name
# for GPU IDs. $2: GPU count. $3: split index. $4: universe associative array
# name. $5: dev partition associative array name (output). $6: vllm partition
# associative array name (output). Updates DEV_GPUS and VLLM_GPUS globally.
# Through a nameref, a bare subscript is stored as a literal key, so the $ on
# id is required.
# shellcheck disable=SC2004
gpu_resolve_partitions() {
    local -n _grp_ids=$1
    local _grp_count=$2
    local _grp_split=$3
    local -n _grp_universe=$4
    local -n _grp_dev=$5
    local -n _grp_vllm=$6

    local dev_set=${DEV_GPUS:-} vllm_set=${VLLM_GPUS:-}
    local dev_defined=0 vllm_defined=0
    [[ -n "$dev_set" ]] && dev_defined=1
    [[ -n "$vllm_set" ]] && vllm_defined=1

    local id idx

    if (( dev_defined && vllm_defined )); then
        gpu_ids_to_set "$5" "$dev_set"
        gpu_ids_to_set "$6" "$vllm_set"
    elif (( dev_defined )); then
        gpu_ids_to_set "$5" "$dev_set"
        for id in "${!_grp_universe[@]}"; do [[ -v _grp_dev[$id] ]] || _grp_vllm[$id]=1; done
    elif (( vllm_defined )); then
        gpu_ids_to_set "$6" "$vllm_set"
        for id in "${!_grp_universe[@]}"; do [[ -v _grp_vllm[$id] ]] || _grp_dev[$id]=1; done
    else
        # Split by position in the GPU IDs array (the order rocm-smi reports
        # the cards), not by bare integers: the IDs may be non-contiguous
        # (e.g. 2,3,6,7).
        for (( idx = 0; idx < _grp_count; idx++ )); do
            id=${_grp_ids[$idx]}
            if (( idx < _grp_split )); then
                _grp_dev[$id]=1
            else
                _grp_vllm[$id]=1
            fi
        done
    fi

    local -a dev_keys vllm_keys
    mapfile -t dev_keys < <(printf '%s\n' "${!_grp_dev[@]}" | sort --numeric-sort)
    mapfile -t vllm_keys < <(printf '%s\n' "${!_grp_vllm[@]}" | sort --numeric-sort)
    DEV_GPUS="$(gpu_join_ids "${dev_keys[@]}")"
    VLLM_GPUS="$(gpu_join_ids "${vllm_keys[@]}")"
}

# Validate the partitions resolved by gpu_resolve_partitions. $1: indexed
# array name (GPU IDs, for error messages). $2: universe associative array
# name. $3: dev partition associative array name. $4: vllm partition
# associative array name. Returns 0 on success, 1 on failure, printing a
# message to stderr for each problem found.
gpu_sanity_check() {
    local -n _gsc_ids=$1
    local -n _gsc_universe=$2
    local -n _gsc_dev=$3
    local -n _gsc_vllm=$4
    local rc=0
    local id

    for id in "${!_gsc_dev[@]}"; do
        if [[ -z "${_gsc_universe[$id]:-}" ]]; then
            echo "error: DEV_GPUS contains the invalid GPU ID <${id}> (valid: ${_gsc_ids[*]})." >&2
            rc=1
        fi
    done

    for id in "${!_gsc_vllm[@]}"; do
        if [[ -z "${_gsc_universe[$id]:-}" ]]; then
            echo "error: VLLM_GPUS contains the invalid GPU ID <${id}> (valid: ${_gsc_ids[*]})." >&2
            rc=1
        fi
    done

    for id in "${!_gsc_dev[@]}"; do
        if [[ -n "${_gsc_vllm[$id]:-}" ]]; then
            echo "error: GPU <${id}> is assigned to both DEV_GPUS and VLLM_GPUS." >&2
            rc=1
        fi
    done

    return "$rc"
}

# --- Initialize -----------------------------------------------------------------

# Run GPU discovery, resolve the DEV_GPUS/VLLM_GPUS partitions (see the file
# header for the rules), and validate the result. Aborts the calling script
# (via die) if awk/rocm-smi are missing, no GPU device is detected, or the
# sanity check fails.
device_init() {
    check_awk
    check_rocm_smi

    # IDs of all GPU devices, as a bash array, e.g. (0 1 2 3 4 5 6 7).
    local -a gpu_ids=()
    mapfile -t gpu_ids < <(gpu_list_ids)

    # Number of GPU devices detected.
    local gpu_count=${#gpu_ids[@]}
    (( gpu_count )) \
        || die "No GPU devices detected (rocm-smi reports none). At least one GPU is required."

    # Index that divides the GPUs into two even halves (e.g. 4 for 8 GPUs).
    local gpu_split=$(( gpu_count / 2 ))

    local -A gpu_universe=()
    gpu_build_universe gpu_ids gpu_universe

    local -A gpu_dev=() gpu_vllm=()
    gpu_resolve_partitions gpu_ids gpu_count gpu_split gpu_universe gpu_dev gpu_vllm

    gpu_sanity_check gpu_ids gpu_universe gpu_dev gpu_vllm \
        || die "The GPU partition failed the sanity check. Aborting."
}
