#!/usr/bin/env bash

#
# Author: <techdiwas> Diwas Neupane
#
# This script rebases a custom OEM kernel source onto a specified
# branch of the Android Common Kernel (ACK), creating separate commits
# for each top-level OEM directory/file.
#

set -euo pipefail

# --- Constants ---
if tput setaf 1 > /dev/null 2>&1; then
    readonly RED=$(tput setaf 1)
    readonly GREEN=$(tput setaf 2)
    readonly NORMAL=$(tput sgr0)
else
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly NORMAL='\033[0m'
fi

readonly SCRIPT_NAME="$(basename "${0}")"
readonly PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly ACK_REPO_URL="https://android.googlesource.com/kernel/common.git"

# --- Functions ---
abort() {
    printf "${RED}Error: %s${NORMAL}\n" "${1}" >&2
    exit 1
}

usage() {
    printf "Usage: %s \"<oem-kernel-git-url>\" \"<oem-branch>\" \"<ack-branch>\"\n" "${SCRIPT_NAME}"
    printf "Example:\n"
    printf "  %s \"https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git\" \"dandelion-q-oss\" \"android-4.9-q\"\n" "${SCRIPT_NAME}"
}

clone_repo_oem() {
    local repo_url="${1}"
    local branch="${2}"
    local dest_dir="${3}"

    printf "Cloning branch '%s' from '%s'...\n" "${branch}" "${repo_url}"
    git clone --depth=1 --single-branch --branch "${branch}" "${repo_url}" "${dest_dir}"
}

clone_repo_ack() {
    local repo_url="${1}"
    local branch="${2}"
    local dest_dir="${3}"

    printf "Cloning branch '%s' from '%s'...\n" "${branch}" "${repo_url}"
    git clone --single-branch --branch "${branch}" "${repo_url}" "${dest_dir}"
}

clone_commig_msg() {
    local dest_dir="${1}"
    cd "${dest_dir}"
    curl -Lo .git/hooks/commit-msg http://review.googlesource.com/tools/hooks/commit-msg
    chmod u+x .git/hooks/commit-msg
    cd -
}

get_kernel_version() {
    local kernel_src_dir="${1}"
    (cd "${kernel_src_dir}" && make kernelversion) || abort "Failed to determine kernel version in '${kernel_src_dir}'."
}

reset_ack_to_oem_version() {
    local ack_dir="${1}"
    local oem_version="${2}"
    local ack_branch="${3}"

    printf "Searching for ACK merge commit for kernel version '%s'...\n" "${oem_version}"

    local commit_sha
    commit_sha=$(git -C "${ack_dir}" log --oneline "${ack_branch}" Makefile | grep -i "${oem_version}" | grep -i "merge" | cut -d ' ' -f1)

    if [ -z "${commit_sha}" ]; then
        abort "Could not find a corresponding merge commit for version '${oem_version}' in the ACK '${ack_branch}' branch."
    fi
    if [ "$(echo "${commit_sha}" | wc -l)" -ne 1 ]; then
        abort "Found multiple possible merge commits for version '${oem_version}'. Aborting for safety."
    fi

    printf "Found base commit: %s. Resetting ACK repository...\n" "${commit_sha}"
    git -C "${ack_dir}" reset --hard "${commit_sha}"
}

rebase_oem_on_ack() {
    local oem_dir="${1}"
    local ack_dir="${2}"

    printf "Replacing ACK directories with OEM source...\n"

    # Get list of top-level directories/files (excluding .git)
    local oem_items
    oem_items=$(cd "${oem_dir}" && find . -mindepth 1 -maxdepth 1 ! -name ".git" -printf "%P\n")

    printf "Copying all OEM files to ACK directory...\n"
    rsync -a --exclude='.git/' "${oem_dir}/" "${ack_dir}/"

    printf "Creating separate commits for each top-level OEM directory/file...\n"
    for item in ${oem_items}; do
        git -C "${ack_dir}" add "${item}"
        if ! git -C "${ack_dir}" diff --cached --quiet; then
            git -C "${ack_dir}" commit -S --quiet -s -m "${item}: Import from OEM source"
        fi
    done

    # Final commit for any remaining changes
    git -C "${ack_dir}" add .
    if ! git -C "${ack_dir}" diff-index --quiet HEAD; then
        git -C "${ack_dir}" commit -S --quiet -s -m "Import remaining OEM changes"
    fi
}

main() {
    if [ "$#" -ne 3 ]; then
        usage
        abort "Invalid number of arguments."
    fi

    local oem_kernel_url="${1}"
    local oem_branch="${2}"
    local ack_branch="${3}"

    local oem_dir="${PROJECT_DIR}/oem"
    local ack_dir="${PROJECT_DIR}/kernel"

    # Clean previous runs
    rm -rf "${oem_dir}" "${ack_dir}"

    # Clone repos
    clone_repo_oem "${oem_kernel_url}" "${oem_branch}" "${oem_dir}"
    clone_repo_ack "${ACK_REPO_URL}" "${ack_branch}" "${ack_dir}"
    # Clone commit-msg-hook for Change-Id
    clone_commit_msg "${ack_dir}"

    # Get OEM kernel version
    local oem_kernel_version
    oem_kernel_version=$(get_kernel_version "${oem_dir}")
    printf "OEM Kernel Version: %s\n" "${oem_kernel_version}"

    # Reset ACK to base commit
    reset_ack_to_oem_version "${ack_dir}" "${oem_kernel_version}" "${ack_branch}"

    # Rebase OEM changes (with multiple commits)
    rebase_oem_on_ack "${oem_dir}" "${ack_dir}"

    printf "\n${GREEN}Success! Your kernel has been rebased to ACK with multiple commits.${NORMAL}\n"
    printf "The rebased kernel is located in: %s\n" "${ack_dir}"
}

main "$@"
