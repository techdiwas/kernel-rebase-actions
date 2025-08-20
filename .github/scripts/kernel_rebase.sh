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

clone_commit_msg() {
    local dest_dir="${1}"
    pushd "${dest_dir}" > /dev/null
    curl -Lo .git/hooks/commit-msg https://android-review.googlesource.com/tools/hooks/commit-msg
    chmod +x .git/hooks/commit-msg
    popd > /dev/null
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

    local -a commit_shas
    mapfile -t commit_shas < <(git -C "${ack_dir}" log --oneline "${ack_branch}" Makefile | grep -i "${oem_version}" | grep -i "merge" | cut -d ' ' -f1)

    if [ "${#commit_shas[@]}" -eq 0 ]; then
        abort "Could not find a corresponding merge commit for version '${oem_version}' in the ACK '${ack_branch}' branch."
    fi
    if [ "${#commit_shas[@]}" -gt 1 ]; then
        abort "Found multiple possible merge commits for version '${oem_version}'. Aborting for safety."
    fi

    local commit_sha="${commit_shas[0]}"
    printf "Found base commit: %s. Resetting ACK repository...\n" "${commit_sha}"
    git -C "${ack_dir}" reset --hard "${commit_sha}"
}

rebase_oem_on_ack() {
    local oem_dir="$1"
    local ack_dir="$2"

    echo "Syncing OEM source into ACK..."
    # Copy OEM kernel source into ACK, skipping .git metadata
    rsync -a --exclude='.git/' "${oem_dir}/" "${ack_dir}/"

    # Helper function:
    # Stages and commits files (if staged changes exist) with a standard commit message.
    commit_if_changes() {
        local prefix="$1"
        if ! git -C "${ack_dir}" diff --cached --quiet; then
        	git -C "${ack_dir}" commit -S --quiet -s -F- <<-EOF
	        ${prefix}: Import from OEM kernel source
        
        	Kernel: Xiaomi kernel changes for Redmi 9C, Redmi POCO C3 and Redmi 9A Android Q
        
        	The kernel config file used is angelica_defconfig, angelicain_defconfig and dandelion_defconfig.
        
	        The original kernel source branch is dandelion-q-oss which can be found here:
        	https://github.com/MiCode/Xiaomi_Kernel_OpenSource
	        EOF
        fi
    }

    echo "Committing root-level files..."
    # Stage only root-level files (no directories) and commit them
    find "${ack_dir}" -maxdepth 1 -type f -exec git -C "${ack_dir}" add {} +
    commit_if_changes "treewide"

    echo "Committing each top-level OEM directory..."
    # For each top-level OEM directory, stage it and commit separately
    while IFS= read -r dir; do
        git -C "${ack_dir}" add "$dir"
        commit_if_changes "$dir"
    done < <(find "${oem_dir}" -mindepth 1 -maxdepth 1 -type d ! -name ".git" -printf "%P\n")

    echo "Checking for remaining changes..."
    # If there are any leftovers (untracked/modified files), stage and commit them
    if [[ -n "$(git -C "${ack_dir}" status --porcelain)" ]]; then
        git -C "${ack_dir}" add .
        commit_if_changes "misc"
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
