#!/bin/bash

set -e

# -------- COLORS --------
GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

log()   { echo -e "${GREEN}[+] $1${NC}"; }
error() { echo -e "${RED}[!] $1${NC}"; exit 1; }


# -------- LOAD CONFIG --------
dos2unix configs/*.conf

BUILD_TARGETS="all"
CONF_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)
            BUILD_TARGETS="$2"
            shift 2
            ;;
        *)
            CONF_FILE="$1"
            shift
            ;;
    esac
done

if [ -z "$CONF_FILE" ] || [ ! -f "$CONF_FILE" ]; then
    error "Usage: $0 [--build <targets>] <config.conf>"
fi

# helper
should_build() {
    if [[ "$BUILD_TARGETS" == "all" ]]; then
        return 0
    fi

    IFS=',' read -ra TARGETS <<< "$BUILD_TARGETS"
    for t in "${TARGETS[@]}"; do
        [[ "$t" == "$1" ]] && return 0
    done
    return 1
}

source "$CONF_FILE"

# -------- SYSTEM DEPS --------
log "Checking system dependencies"

DEPS_MARKER="$TOP_FOLDER/.deps_installed"

if [ -f "$DEPS_MARKER" ]; then
    log "Dependencies already installed, skipping"
else
    log "Installing dependencies"

    sudo apt-get update
    sudo apt-get install --no-install-recommends -y \
    git cmake ninja-build gperf ccache dfu-util device-tree-compiler \
    wget python3-dev python3-pip python3-setuptools python3-tk python3-wheel python3-venv \
    xz-utils file libpython3-dev make gcc gcc-multilib g++-multilib \
    libsdl2-dev libmagic1 libguestfs-tools libssl-dev \
    bison flex python3.12 python3.12-venv python3.12-dev

    sudo touch "$DEPS_MARKER"
fi

# -------- WORKSPACE --------

if [ -d "$WORKDIR" ]; then
    log "Using existing workspace: $WORKDIR"
else
    log "Creating workspace: $WORKDIR"
    mkdir "$WORKDIR"
fi

cd "$WORKDIR"
export TOP_FOLDER=$(pwd)

# -------- UBOOT --------

UBOOT_NAME=$(basename -s .git "$UBOOT_REPO_URL")
UBOOT_DIR="$TOP_FOLDER/$UBOOT_NAME"
log "Setting up U-Boot: $UBOOT_NAME"

if [ -d "$UBOOT_DIR/.git" ]; then
    log "U-Boot repo exists, syncing"
    cd "$UBOOT_DIR"
    git fetch origin --tags

    # checkout branch/tag/commit
    if git show-ref --verify --quiet "refs/remotes/origin/$UBOOT_REF"; then
        git checkout "$UBOOT_REF"
        git reset --hard "origin/$UBOOT_REF"
    else
        git checkout "$UBOOT_REF" -f
    fi
else
    log "Cloning U-Boot"
    git clone "$UBOOT_REPO_URL" "$UBOOT_DIR"
    cd "$UBOOT_DIR"
    git fetch origin --tags
    if git show-ref --verify --quiet "refs/remotes/origin/$UBOOT_REF"; then
        git checkout "$UBOOT_REF"
    else
        git checkout "$UBOOT_REF"
    fi
    cd "$TOP_FOLDER"
fi

# -------- ARM TRUSTED FIRMWARE --------
if should_build atf; then

    ATF_DIR="$TOP_FOLDER/arm-trusted-firmware-sdcard"
    ATF_MARKER="$ATF_DIR/.atf_config"

    log "Setting up ATF"

    # -------- CLONE / SYNC --------

    if [ -d "$ATF_DIR/.git" ]; then
        cd "$ATF_DIR"

        CURRENT_URL=$(git config --get remote.origin.url)

        if [ "$CURRENT_URL" != "$ATF_REPO_URL" ]; then
            log "ATF remote URL changed, recloning"
            cd "$TOP_FOLDER"
            rm -rf "$ATF_DIR"
            git clone -b "$ATF_BRANCH" "$ATF_REPO_URL" "$ATF_DIR"
            cd "$ATF_DIR"
        else
            log "Fetching latest ATF"
            git fetch origin

            # Handle branch vs tag vs commit
            if git show-ref --verify --quiet "refs/heads/$ATF_BRANCH"; then
                git checkout "$ATF_BRANCH"
                git reset --hard "origin/$ATF_BRANCH"
            else
                git fetch --tags
                git checkout "$ATF_BRANCH" -f
            fi
        fi
    else
        log "Cloning ATF"
        git clone -b "$ATF_BRANCH" "$ATF_REPO_URL" "$ATF_DIR"
        cd "$ATF_DIR"
    fi

    # -------- BUILD CHECK --------
    BUILD_ARTIFACT="build/$ATF_PLAT/release/bl31.bin"

    NEED_BUILD=false

    if [ ! -f "$BUILD_ARTIFACT" ]; then
        NEED_BUILD=true
    fi

    # Check config drift
    if [ -f "$ATF_MARKER" ]; then
        if ! grep -q "$ATF_REPO_URL" "$ATF_MARKER" || \
        ! grep -q "$ATF_BRANCH" "$ATF_MARKER"; then
            log "ATF config changed, forcing rebuild"
            NEED_BUILD=true
        fi
    else
        NEED_BUILD=true
    fi

    # -------- BUILD --------
    if [ "$NEED_BUILD" = true ]; then
        log "Building ATF"
        make realclean

        ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- \
        make PLAT="$ATF_PLAT" SOCFPGA_BOOT_SOURCE_SDMMC=1 \
        bl2 bl31 PRELOADED_BL33_BASE=0x80100000 -j$(nproc)

        # Save config state
        echo "URL=$ATF_REPO_URL" > "$ATF_MARKER"
        echo "BRANCH=$ATF_BRANCH" >> "$ATF_MARKER"
    else
        log "ATF already up to date, skipping build"
    fi

    # -------- FIPTOOL --------

    FIPTOOL_BIN="$TOP_FOLDER/fiptool"

    if [ -f "$FIPTOOL_BIN" ]; then
        log "fiptool already exists, skipping"
    else
        log "Building fiptool"
        make fiptool
        cp tools/fiptool/fiptool "$FIPTOOL_BIN"
    fi

fi

# -------- PYTHON ENV --------
if should_build zephyr; then

    log "Setting up Python venv"

    if [ ! -d "$HOME/.zephyrproject/.venv" ]; then
        python3.12 -m venv "$HOME/.zephyrproject/.venv"
    fi

    source "$HOME/.zephyrproject/.venv/bin/activate"

    pip install --upgrade pip wheel west

# -------- ZEPHYR WORKSPACE SETUP --------
#TODO: Fix for multiple zephyr repos, should traverse by gitname in zephyrproject, if found alter that. Otherwise clone new.
    cd "$TOP_FOLDER"

    ZEPHYR_REPO_NAME=$(basename -s .git "$ZEPHYR_REPO_URL")
    WEST_DIR="$TOP_FOLDER/zephyrproject"
    ZEPHYR_PATH="$WEST_DIR/$ZEPHYR_REPO_NAME"

    log "Setting up Zephyr workspace"

    # -------- WORKSPACE INIT --------
    if [ ! -d "$WEST_DIR/.west" ]; then
        log "Initializing west workspace"

        if [ "$ZEPHYR_REPO_NAME" = "zephyr" ]; then
            log "Using west-managed Zephyr"

            west init -m "$ZEPHYR_REPO_URL" --mr "$ZEPHYR_BRANCH" zephyrproject

        else
            log "Using custom Zephyr repo: $ZEPHYR_REPO_NAME"

            mkdir -p "$WEST_DIR"
            cd "$WEST_DIR"

            git clone -b "$ZEPHYR_BRANCH" "$ZEPHYR_REPO_URL" "$ZEPHYR_REPO_NAME"

            west init -l "$ZEPHYR_REPO_NAME"
        fi
    fi

    cd "$WEST_DIR"

    cd "$WEST_DIR/$ZEPHYR_REPO_NAME" || exit 1

    # Detect local changes (tracked + untracked)
    if [ -n "$(git status --porcelain)" ]; then
        log "Local changes detected in Zephyr repo — skipping update"
        SKIP_ZEPHYR_UPDATE=true
    else
        SKIP_ZEPHYR_UPDATE=false
    fi

    # -------- ENSURE ZEPHYR REPO STATE -------

    if [ "$SKIP_ZEPHYR_UPDATE" = false ]; then
        log "Updating Zephyr"

        git fetch origin

        if git show-ref --verify --quiet "refs/heads/$ZEPHYR_BRANCH"; then
            git checkout "$ZEPHYR_BRANCH"
            git reset --hard "origin/$ZEPHYR_BRANCH"
        else
            git fetch --tags
            git checkout "$ZEPHYR_BRANCH" -f
        fi
    else
        log "Zephyr update skipped due to local modifications"
    fi

    cd "$WEST_DIR"

    # -------- FETCH MODULES --------
    log "Updating west modules"
    west update
    west zephyr-export

    # -------- PYTHON REQUIREMENTS --------
    log "Installing Zephyr Python dependencies"
    pip install -r "$ZEPHYR_REPO_NAME/scripts/requirements.txt"

    # -------- SDK --------
    log "Setting up Zephyr SDK"

    SDK_PATH="$HOME/zephyr-sdk-$ZEPHYR_SDK_VERSION"

    # Check if SDK already exists
    if [ -d "$SDK_PATH" ]; then
        log "Zephyr SDK already present at $SDK_PATH (skipping download)"
    else
        log "Downloading Zephyr SDK v$ZEPHYR_SDK_VERSION"

        for i in "${!ZEPHYR_SDK_URLS[@]}"; do
            wget "${ZEPHYR_SDK_URLS[$i]}"
            wget -O - "${ZEPHYR_SDK_SHA_URLS[$i]}" | shasum --check --ignore-missing
        done

        for file in zephyr-sdk-*.tar.xz; do
            tar xf "$file" -C "$ZEPHYR_SDK_INSTALL_DIR"
        done

        rm -f zephyr-sdk-*.tar.xz
    fi

    # Ensure toolchain is configured (safe to re-run)
    if [ -d "$SDK_PATH/aarch64-zephyr-elf" ]; then
        log "SDK toolchain already installed"
    else
        log "Installing SDK toolchain"
        "$SDK_PATH/setup.sh" -t aarch64-zephyr-elf -h -c
    fi

# -------- BUILD --------

    cd "$TOP_FOLDER/zephyrproject"

    log "Building Zephyr ($ZEPHYR_REPO_NAME)"

    west build \
        -b "$BOARD" \
        -s "$ZEPHYR_REPO_NAME/$APP" \
        -d build \
        -p always

fi

# -------- FIP --------
if should_build sdimg; then

    cd "$TOP_FOLDER"

    mkdir -p sdcard_bin
    cd sdcard_bin

    cp "$TOP_FOLDER/arm-trusted-firmware-sdcard/build/agilex5/release/bl2.bin" .

    log "Creating FIP"
    "$TOP_FOLDER/fiptool" create \
        --soc-fw "$TOP_FOLDER/arm-trusted-firmware-sdcard/build/agilex5/release/bl31.bin" \
        --nt-fw "$TOP_FOLDER/zephyrproject/build/zephyr/zephyr.bin" \
        fip.bin

    # -------- SD IMAGE --------
    log "Preparing SD image script"

    SCRIPT_NAME="make_sdimage.sh"
    SCRIPT_MARKER=".sdimage_script_url"

    NEED_DOWNLOAD=false

    # If script missing → download
    [ ! -f "$SCRIPT_NAME" ] && NEED_DOWNLOAD=true

    # If URL changed → re-download
    if [ -f "$SCRIPT_MARKER" ]; then
        OLD_URL=$(cat "$SCRIPT_MARKER")
        [ "$OLD_URL" != "$SDIMAGE_SCRIPT_URL" ] && NEED_DOWNLOAD=true
    else
        NEED_DOWNLOAD=true
    fi

    if [ "$NEED_DOWNLOAD" = true ]; then
        log "Downloading SD image script"
        rm -f "$SCRIPT_NAME"
        wget -O "$SCRIPT_NAME" "$SDIMAGE_SCRIPT_URL"
        chmod +x "$SCRIPT_NAME"
        echo "$SDIMAGE_SCRIPT_URL" > "$SCRIPT_MARKER"
    else
        log "SD image script up to date, skipping download"
    fi

    touch dummy.tar.gz

    yes y |sudo ./make_sdimage.sh \
        -k dummy.tar.gz \
        -p fip.bin \
        -o $SD_IMAGE_NAME \
        -g 2G -pg 16

    if should_build zephyr; then
        deactivate
    fi

fi

# -------- SIMICS --------
if should_build simics; then

export PATH="$PATH:$SIMICS_INSTALLATION/simics/bin/"

cd "$TOP_FOLDER"

PROJECT_DIR="project-1"

if [ -d "$PROJECT_DIR" ]; then
    log "Simics project '$PROJECT_DIR' already exists, skipping deploy"
    cd "$PROJECT_DIR"
else
    log "Creating Simics project '$PROJECT_DIR'"
    mkdir "$PROJECT_DIR"
    cd "$PROJECT_DIR"

    log "Deploying Simics"
    simics_intelfpga_cli --deploy agilex5e-universal

    log "Building Simics project"
    make
fi

# -------- CPU CONFIG --------
CPU_CONFIG=""

if [ "$CPU_TYPE" = "a76" ]; then
CPU_CONFIG='$hps_boot_core = 2
$hps_core0_1_power_on = TRUE
$hps_core2_power_on = TRUE
$hps_core3_power_on = TRUE'
fi

# -------- SIMICS SCRIPT --------
cat <<EOF > zephyr_sdcard.simics
local \$board_name = "system.board.fpga"

\$create_hps_serial0_console=TRUE
\$create_hps_sd_card=TRUE
\$create_hps_mmc=FALSE

\$sd_image_filename = ../sdcard_bin/sdimage.img
\$fsbl_image_filename = ../sdcard_bin/bl2.bin
EOF

echo "$CPU_CONFIG" >> zephyr_sdcard.simics

cat <<EOF >> zephyr_sdcard.simics
run-command-file "targets/agilex5e-universal/agilex5e-universal.simics"
run
EOF

rm -rf zephyr.simics
ln -sf zephyr_sdcard.simics zephyr.simics

log "Launching Simics"
./simics zephyr.simics

fi