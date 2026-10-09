# SPDX-License-Identifier: MIT
# Copyright (c) 2026, Advanced Micro Devices, Inc. All rights reserved.

# common.sh - shared helpers: die(), external dependency checks, and value
# validation.
# Not an executable script. Source it from other scripts: `source common.sh`
#
# die MESSAGE: print "error: MESSAGE" to stderr and exit with status 1.
# check_<tool>: exit (via die) if the tool is not available in PATH:
#   check_curl, check_docker, check_jq.
# check_positive_int NAME VALUE: print the canonical decimal value of VALUE,
#   or die if it is not a positive integer.
# abs_path PATH: print the absolute, normalized form of the given path (it
#   need not exist), without resolving symlinks.
# DEFAULT_VLLM_PORT: default vLLM server port (8000).
# resolve_vllm_port [PORT]: resolve (default: DEFAULT_VLLM_PORT) and
#   validate PORT, printing the canonical decimal port number to stdout.
# wait_until TIMEOUT INTERVAL PREDICATE [ARGS...]: poll PREDICATE every
#   INTERVAL seconds until it exits with status 0 or TIMEOUT seconds elapse;
#   set WAIT_UNTIL_ELAPSED to the elapsed seconds, return 1 on timeout.

# Print an error message to stderr and exit with status 1.
die() {
    echo "error: $*" >&2
    exit 1
}

# Internal: die if the given command is not in PATH.
require_cmd() {
    local cmd=$1
    command -v "${cmd}" >/dev/null 2>&1 || die "The command ${cmd} was not found in PATH."
}

# Check that curl is available (used by bench_vllm.sh, start_vllm.sh, and
# stop_vllm.sh).
check_curl() { require_cmd curl; }

# Check that the docker CLI is available and the Docker daemon is reachable
# (used by bench_vllm.sh, download_model.sh, install_opencode.sh,
# start_dev.sh, start_vllm.sh, stop_dev.sh, and stop_vllm.sh).
check_docker() {
    require_cmd docker
    docker info >/dev/null 2>&1 || die "Cannot reach the Docker daemon. Is Docker running?"
}

# Check that jq is available (used by start_vllm.sh and bench_vllm.sh).
check_jq() { require_cmd jq; }

# Print the canonical decimal value of $2, or die if it is not a positive
# integer. $1 is the parameter name, used in error messages.
check_positive_int() {
    local name=$1 value=$2
    if ! [[ "${value}" =~ ^[0-9]+$ ]] || (( ${#value} > 9 )); then
        die "${name} must be a positive integer, got <${value}>."
    fi
    value=$(( 10#${value} ))
    (( value >= 1 )) || die "${name} must be at least 1, got <${value}>."
    printf '%s\n' "${value}"
}

# Print the absolute, normalized form of the given path (it need not exist),
# without resolving symlinks.
abs_path() {
    realpath --canonicalize-missing --no-symlinks -- "$1"
}

# Default vLLM server port, used when no port is given.
DEFAULT_VLLM_PORT=8000

# Resolve the vLLM port (default: DEFAULT_VLLM_PORT) and validate it as a
# port number. Print the canonical decimal port number to stdout; info notes
# go to stderr.
resolve_vllm_port() {
    local port=${1:-}
    if [[ -n "${port}" ]]; then
        echo "Using user-specified port: <${port}>." >&2
    else
        port=${DEFAULT_VLLM_PORT}
        echo "No port specified. Using the default port: <${port}>." >&2
    fi
    if ! [[ "${port}" =~ ^[0-9]+$ ]] || (( ${#port} > 5 )); then
        die "The port must be a number, got <${port}>."
    fi
    port=$(( 10#${port} ))
    if (( port < 1 || port > 65535 )); then
        die "The port must be between 1 and 65535, got <${port}>."
    fi
    printf '%s\n' "${port}"
}

# Poll PREDICATE every INTERVAL seconds until it exits with status 0 or
# TIMEOUT seconds have elapsed. WAIT_UNTIL_ELAPSED holds the elapsed seconds
# when PREDICATE last ran (and when wait_until returns). Return 0 if PREDICATE
# succeeded, 1 if the timeout expired first.
# shellcheck disable=SC2034 # WAIT_UNTIL_ELAPSED is read by the caller
wait_until() {
    local timeout=$1 interval=$2
    shift 2
    SECONDS=0
    while :; do
        WAIT_UNTIL_ELAPSED=${SECONDS}
        if "$@"; then
            return 0
        fi
        if (( SECONDS >= timeout )); then
            return 1
        fi
        sleep "${interval}"
    done
}
