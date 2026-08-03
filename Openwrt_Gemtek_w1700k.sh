#!/bin/bash
# ==================================================================================
# Gemtek_w1700k - OpenWrt Build Script (List-Based Method)
# ==================================================================================
#
# Build system Install Note  - Run on Ubuntu 24.04 or later
#                            - sudo apt update
#                            - sudo apt install dos2unix rsync patch
# Usage:
#
#   ./Openwrt_Gemtek_w1700k.sh
#   ./Openwrt_Gemtek_w1700k.sh -b openwrt-23.05
#
# ==================================================================================

set -euo pipefail

# --- Dependency Check ---
if ! command -v dos2unix &> /dev/null || ! command -v rsync &> /dev/null || ! command -v patch &> /dev/null; then
    echo "ERROR: One or more dependencies (dos2unix, rsync, patch) are not installed." >&2
    echo "Please run 'sudo apt update && sudo apt install dos2unix rsync patch'." >&2
    exit 1
fi


# --- Main Configuration ---

# OpenWrt Source Details
readonly OPENWRT_REPO="https://github.com/openwrt/openwrt.git"
# --- Use this line for local testing (uncomment and set your path) ---
#readonly OPENWRT_REPO="/home/user/openwrt/repos/openwrt"

OPENWRT_BRANCH="master"
readonly OPENWRT_COMMIT="5ecd3173d66fef60c5dfa06bcadb2d68aec87c20"

# --- Directory and File Configuration ---
readonly SOURCE_DEFAULT_CONFIG_DIR="config"
readonly SOURCE_OPENWRT_PATCH_DIR="openwrt-patches"
readonly SOURCE_CUSTOM_FILES_DIR="files"
readonly SOURCE_LUCI_APPS_DIR="luci-apps"
readonly OPENWRT_ADD_LIST="$SOURCE_OPENWRT_PATCH_DIR/openwrt-add-patch"
readonly OPENWRT_REMOVE_LIST="$SOURCE_OPENWRT_PATCH_DIR/openwrt-remove"
readonly LUCI_APPS_ADD_LIST="$SOURCE_LUCI_APPS_DIR/add-apps"

readonly OPENWRT_DIR="openwrt"
readonly SCRIPT_EXECUTABLE_NAME=$(basename "$0")


# --- Functions ---

show_usage() {
    echo "Usage: $SCRIPT_EXECUTABLE_NAME [-b <branch_name>]"
    echo "  -b <branch_name>  Specify the OpenWrt branch to build."
    exit 1
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] - $1" >&2
}

require_command() {
    for cmd in "$@"; do
        if ! command -v "$cmd" &> /dev/null; then
            log "Error: Required command '$cmd' is not installed. Please install it and try again."
            exit 1
        fi
    done
}

get_latest_commit_hash() {
    local repo_url=$1
    local branch=$2
    log "Querying remote repository for the latest commit on branch '$branch'..."
    local commit_hash
    commit_hash=$(git ls-remote "$repo_url" "refs/heads/$branch" | awk '{print $1}')
    if [ -z "$commit_hash" ]; then
        log "Error: Could not retrieve the commit hash for branch '$branch'."
        exit 1
    fi
    echo "$commit_hash"
}

setup_repo() {
    local repo_url=$1
    local branch=$2
    local commit_hash=$3
    local target_dir=$4
    local repo_name=$5

    if [ -d "$target_dir" ]; then
        log "Directory '$target_dir' for $repo_name already exists. Removing it for a fresh clone."
        rm -rf "$target_dir"
    fi

    log "Cloning $repo_name repository from branch '$branch'..."
    git clone --branch "$branch" "$repo_url" "$target_dir"
    log "Clone complete. Checking out specific $repo_name commit: $commit_hash"
    (cd "$target_dir" && git checkout "$commit_hash")
    log "Successfully checked out $repo_name commit."
}

prepare_source_directory() {
    local source_dir=$1
    local dir_name=$2
    log "--- Preparing source directory: '$source_dir' ($dir_name) ---"
    if [ ! -d "$source_dir" ]; then return; fi

    find "$source_dir" -type f -name ".gitkeep" -delete

    find "$source_dir" -type f \( -name "*.c" -o -name "*.h" -o -name "*.cpp" -o -name "*.hpp" \
        -o -name "Makefile*" -o -name "*.mk" -o -name "*.sh" -o -name "Config*" \
        -o -name "*.txt" -o -name "*.json" -o -name "*.conf" -o -name "fan" -o -name "luci.*" \) -exec dos2unix {} +

    find "$source_dir" -type d -exec chmod 755 {} +
    find "$source_dir" -type f -exec chmod 644 {} +

    for sub in "etc/uci-defaults" "root/etc/uci-defaults" "etc/init.d" "root/etc/init.d" "usr/libexec/rpcd" "root/usr/libexec/rpcd"; do
        if [ -d "$source_dir/$sub" ]; then
             log "($dir_name) Fixing permissions in $sub..."
             find "$source_dir/$sub" -type f -exec dos2unix {} +
             find "$source_dir/$sub" -type f -exec chmod 755 {} +
        fi
    done
    log "($dir_name) Preparation complete."
}

remove_files_from_list() {
    local list_file=$1
    local target_dir=$2
    local name=$3
    log "--- Checking for $name files to remove from list '$list_file' ---"
    if [ ! -f "$list_file" ]; then
        log "Remove list '$list_file' not found. Skipping."
        return
    fi
    local lines_processed=0
    while IFS= read -r relative_path; do
        relative_path=$(echo "$relative_path" | tr -d '\r' | sed 's|^/||')
        if [ -z "$relative_path" ]; then continue; fi
        
        local target_pattern="$target_dir/$relative_path"
        lines_processed=$((lines_processed + 1))

        if [[ "$relative_path" == *'*'* ]]; then
            log "($name) Removing files matching pattern: $relative_path"
            
            shopt -s nullglob
            local files_to_delete=($target_pattern)
            shopt -u nullglob

            if [ ${#files_to_delete[@]} -gt 0 ]; then
                rm -f "${files_to_delete[@]}"
                log "($name) Removed ${#files_to_delete[@]} file(s)."
            else
                log "($name) No files found matching the pattern."
            fi
        else
            if [ -f "$target_pattern" ]; then
                log "($name) Removing: $relative_path"
                rm -f "$target_pattern"
            else
                log "($name) Warning: File to remove not found at '$target_pattern'. Skipping."
            fi
        fi
    done < <(grep -v -E '^\s*#|^\s*$' "$list_file")

    if [ "$lines_processed" -eq 0 ]; then
        log "No files listed for removal in '$list_file'."
    fi
}

apply_files_from_list() {
    local list_file=$1
    local source_dir=$2
    local target_dir=$3
    local name=$4

    log "--- Applying $name files and patches from list '$list_file' ---"
    if [ ! -f "$list_file" ]; then
        log "Add list '$list_file' not found. Skipping."
        return
    fi

    local lines_processed=0
    while IFS= read -r line; do
        [[ "$line" =~ ^\s*# ]] || [ -z "$line" ] && continue
        
        lines_processed=$((lines_processed + 1))

        local source_filename
        local dest_relative_path

        if [[ "$line" == *":"* ]]; then
            source_filename=$(echo "$line" | cut -d':' -f1 | tr -d '[:space:]')
            dest_relative_path=$(echo "$line" | cut -d':' -f2- | tr -d '[:space:]' | sed 's|^/||')
        else
            dest_relative_path=$(echo "$line" | tr -d '[:space:]' | sed 's|^/||')
            source_filename=$(basename "$dest_relative_path")
        fi

        if [ -z "$source_filename" ] || [ -z "$dest_relative_path" ]; then
            log "($name) Warning: Malformed line found in '$list_file': '$line'. Skipping."
            continue
        fi

        local source_file="$source_dir/$source_filename"
        local dest_file="$target_dir/$dest_relative_path"

        if [ ! -f "$source_file" ]; then
            log "($name) ERROR: Source file '$source_filename' not found in '$source_dir'. Skipping."
            continue
        fi

        log "($name) Copying '$source_filename' to '$dest_relative_path'..."
        
        local dest_dir
        dest_dir=$(dirname "$dest_file")
        mkdir -p "$dest_dir"

        cp "$source_file" "$dest_file"

    done < <(grep -v -E '^\s*#|^\s*$' "$list_file")

    if [ "$lines_processed" -eq 0 ]; then
        log "No files listed for application in '$list_file'."
    fi
}


install_luci_apps_from_list() {
    local list_file=$1
    local source_dir=$2
    local target_dir=$3

    log "--- Installing LuCI apps from list '$list_file' ---"
    if [ ! -f "$list_file" ]; then
        log "LuCI apps list '$list_file' not found. Skipping."
        return
    fi

    local lines_processed=0
    while IFS= read -r line; do
        lines_processed=$((lines_processed + 1))

        local source_name
        local dest_relative_path

        if [[ "$line" == *":"* ]]; then
            source_name=$(echo "$line" | cut -d':' -f1 | tr -d '[:space:]')
            dest_relative_path=$(echo "$line" | cut -d':' -f2- | tr -d '[:space:]' | sed 's|^/||')
        else
            dest_relative_path=$(echo "$line" | tr -d '[:space:]' | sed 's|^/||')
            source_name=$(basename "$dest_relative_path")
        fi

        if [ -z "$source_name" ] || [ -z "$dest_relative_path" ]; then
            log "(LuCI Apps) Warning: Malformed line in '$list_file': '$line'. Skipping."
            continue
        fi

        local source_app="$source_dir/$source_name"
        local dest_app="$target_dir/$dest_relative_path"

        if [ ! -d "$source_app" ]; then
            log "(LuCI Apps) ERROR: Source app directory '$source_name' not found in '$source_dir'. Skipping."
            continue
        fi

        log "(LuCI Apps) Copying '$source_name' to '$dest_relative_path'..."
        mkdir -p "$(dirname "$dest_app")"
        cp -r "$source_app" "$dest_app"

    done < <(grep -v -E '^\s*#|^\s*$' "$list_file")

    if [ "$lines_processed" -eq 0 ]; then
        log "No apps listed in '$list_file'."
    fi
}

copy_custom_files() {
    local source_dir="$SOURCE_CUSTOM_FILES_DIR"
    local target_dir="$OPENWRT_DIR/files"
    log "--- Copying custom runtime files from '$source_dir' ---"
    if [ ! -d "$source_dir" ]; then
        log "Source directory '$source_dir' not found. Skipping."
        return
    fi
    mkdir -p "$target_dir"
    rsync -a "$source_dir/" "$target_dir/"
	find "$target_dir" -type f \( -name '*.sh' -o -path '*/etc/init.d/*' -o -path '*/usr/libexec/rpcd/*' \) -exec chmod +x {} +
    log "Custom files have been copied successfully."
}

prompt_for_custom_build() {
    log "--- Optional: Custom Image Creation ---"
    echo "The base image has been built successfully."
    echo "Would you like to create a custom image?"
    echo "You have 10 seconds to answer. The default is 'no'."
    local custom_choice=""
    read -t 10 -p "Enter (yes/no): " custom_choice || true

    case "${custom_choice,,}" in
        y|yes)
            log "User chose 'yes'. Preparing for custom build..."
            
            log "Launching 'make menuconfig' for customization..."
            (cd "$OPENWRT_DIR" && make menuconfig)
            log "Configuration saved."

            log "--- Build Confirmation for Custom Image ---"
            echo "Would you like to build the custom image with the new configuration?"
            echo "You have 10 seconds to answer. The default is 'no'."
            local build_choice=""
            read -t 10 -p "Enter (yes/no): " build_choice || true

            case "${build_choice,,}" in
                y|yes)
                    log "Removing old images from the output directory..."
                    local image_dir="$OPENWRT_DIR/bin/targets/mediatek/filogic"
                    if [ -d "$image_dir" ]; then
                        rm -f "$image_dir"/*
                        log "Old images removed."
                    fi

                    log "Starting the custom build with 'make -j\$(nproc)'..."
                    (cd "$OPENWRT_DIR" && make -j"$(nproc)" TESTING_KERNEL=1 V=s)
                    log "--- Custom build process finished successfully! ---"
                    log "--- You can find the custom images in '$OPENWRT_DIR/bin/targets/mediatek/filogic/' ---"
                    ;;
                *)
                    log "User chose 'no' or timed out. Custom build skipped."
                    log "Your custom configuration has been saved in '$OPENWRT_DIR/.config'."
                    ;;
            esac
            ;;
        *)
            log "User chose 'no' or timed out. Skipping custom image creation."
            ;;
    esac
}


main() {
    while getopts ":b:" opt; do
        case ${opt} in
            b) OPENWRT_BRANCH=$OPTARG ;;
            \?|:) show_usage ;;
        esac
    done
    shift "$((OPTIND -1))"

    log "--- Starting Full Build Setup ---"
    require_command "git" "awk" "make" "dos2unix" "rsync" "patch"

    local openwrt_commit
    if [ -n "$OPENWRT_COMMIT" ]; then
        openwrt_commit="$OPENWRT_COMMIT"
        log "Using specified OpenWrt commit hash: $openwrt_commit"
    else
        openwrt_commit=$(get_latest_commit_hash "$OPENWRT_REPO" "$OPENWRT_BRANCH")
        log "Latest commit for OpenWrt '$OPENWRT_BRANCH' is: $openwrt_commit"
    fi
    setup_repo "$OPENWRT_REPO" "$OPENWRT_BRANCH" "$openwrt_commit" "$OPENWRT_DIR" "OpenWrt"

    (
        cd "$OPENWRT_DIR"
		
        log "Updating and installing feeds to prepare the source tree..."
        ./scripts/feeds update -a
        install_luci_apps_from_list "../$LUCI_APPS_ADD_LIST" "../$SOURCE_LUCI_APPS_DIR" "."
        ./scripts/feeds update luci
        ./scripts/feeds install -a
    )

    prepare_source_directory "$SOURCE_OPENWRT_PATCH_DIR" "OpenWrt Patches"
    prepare_source_directory "$SOURCE_LUCI_APPS_DIR" "LuCI Apps"
    prepare_source_directory "$SOURCE_CUSTOM_FILES_DIR" "Custom Files"

    remove_files_from_list "$OPENWRT_REMOVE_LIST" "$OPENWRT_DIR" "OpenWrt"
    apply_files_from_list "$OPENWRT_ADD_LIST" "$SOURCE_OPENWRT_PATCH_DIR" "$OPENWRT_DIR" "OpenWrt"

    copy_custom_files

    (
        cd "$OPENWRT_DIR"
        log "Applying custom build configuration..."
        if [ -f "../$SOURCE_DEFAULT_CONFIG_DIR/config.diff" ]; then
            cp "../$SOURCE_DEFAULT_CONFIG_DIR/config.diff" .config
        else
            log "Warning: No 'defconfig' found."
        fi
        log "Validating and expanding final .config..."
        make defconfig
    )

    log "--- Starting the main build... ---"
    (
        cd "$OPENWRT_DIR"
        make -j"$(nproc)" TESTING_KERNEL=1
    )
    log "--- Main build process finished successfully! ---"
    log "--- You can find the images in '$OPENWRT_DIR/bin/targets/mediatek/filogic/' ---"

    prompt_for_custom_build
    
    log "--- Script finished. ---"
}

main "$@"

exit 0
