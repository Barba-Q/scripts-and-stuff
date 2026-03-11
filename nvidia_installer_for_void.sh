#!/bin/bash
# ==============================================================================
# Script to prepare NVIDIA driver installation with DKMS (v1.5)
# for the 'nvidia-open' kernel modules on Void Linux.
# ==============================================================================

# --- Configuration & Color Variables ---
set -e
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- 1. Checks ---
echo -e "${GREEN}Step 1: Performing checks...${NC}"
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run with root privileges (sudo).${NC}"
   exit 1
fi
if [ -z "$1" ]; then
    echo -e "${RED}Error: Please provide the path to the NVIDIA .run file as an argument.${NC}"
    echo -e "Example: sudo ./setup_nvidia_dkms.sh ./NVIDIA-Linux-x86_64-580.126.18.run"
    exit 1
fi
INSTALLER_PATH=$(realpath "$1")
if [ ! -f "$INSTALLER_PATH" ]; then
    echo -e "${RED}Error: The file '$INSTALLER_PATH' was not found.${NC}"
    exit 1
fi

# --- 2. Install Dependencies ---
echo -e "\n${GREEN}Step 2: Installing necessary dependencies...${NC}"
xbps-install -Syu || true
xbps-install -Sy base-devel linux-headers dkms || true

# --- 3. Extract Version and Set Variables ---
echo -e "\n${GREEN}Step 3: Extracting driver version and setting variables...${NC}"
VERSION=$(basename "$INSTALLER_PATH" | grep -oP '\d+\.\d+\.\d+')
if [ -z "$VERSION" ]; then
    echo -e "${RED}Error: Could not extract version number from the filename.${NC}"
    exit 1
fi
DKMS_MODULE_NAME="nvidia-open"
DKMS_SRC_DIR="/usr/src/${DKMS_MODULE_NAME}-${VERSION}"
TEMP_EXTRACT_DIR="/var/tmp/nvidia-installer-extraction"

echo "  -> Detected driver version: ${YELLOW}${VERSION}${NC}"
echo "  -> DKMS source directory: ${YELLOW}${DKMS_SRC_DIR}${NC}"

# --- 4. Clean Up Old Installations ---
echo -e "\n${GREEN}Step 4: Cleaning up any old installations...${NC}"
rm -rf "$TEMP_EXTRACT_DIR"
dkms remove "${DKMS_MODULE_NAME}/${VERSION}" --all || true
rm -rf "$DKMS_SRC_DIR"

# --- 5. Extract Driver ---
echo -e "\n${GREEN}Step 5: Extracting kernel sources from the installer...${NC}"
mkdir -p "$TEMP_EXTRACT_DIR"

if ! sh "$INSTALLER_PATH" -x --target "$TEMP_EXTRACT_DIR/extract"; then
    echo -e "${RED}Error: Extraction failed! Check your disk space in /var/tmp or the installer file.${NC}"
    exit 1
fi

if [ -d "$TEMP_EXTRACT_DIR/extract/kernel" ]; then
    EXTRACTED_DIR="$TEMP_EXTRACT_DIR/extract"
else
    EXTRACTED_DIR=$(find "$TEMP_EXTRACT_DIR/extract" -maxdepth 1 -type d -name "NVIDIA-Linux-x86_64-*" | head -n 1)
fi

if [ -z "$EXTRACTED_DIR" ] || [ ! -d "$EXTRACTED_DIR" ]; then
    echo -e "${RED}Error: Could not find the extracted NVIDIA directory.${NC}"
    exit 1
fi

cd "$EXTRACTED_DIR"

# --- 6. Set Up DKMS ---
echo -e "\n${GREEN}Step 6: Setting up DKMS for the new modules...${NC}"
echo "  -> Copying kernel modules to ${DKMS_SRC_DIR}..."
mkdir -p "$DKMS_SRC_DIR"
cp -r ./kernel/* "$DKMS_SRC_DIR/"

# NEW: Fix for NVIDIA 580.x stray Tegra headers on x86_64
echo "  -> Patching out stray Tegra headers (NVIDIA bug)..."
if [ -f "$DKMS_SRC_DIR/nvidia/nv-clk.c" ]; then
    sed -i 's|#include <soc/tegra/bpmp-abi.h>|/* & */|' "$DKMS_SRC_DIR/nvidia/nv-clk.c"
    sed -i 's|#include <soc/tegra/bpmp.h>|/* & */|' "$DKMS_SRC_DIR/nvidia/nv-clk.c"
fi

echo "  -> Creating dkms.conf..."
cat << EOF > "${DKMS_SRC_DIR}/dkms.conf"
PACKAGE_NAME="${DKMS_MODULE_NAME}"
PACKAGE_VERSION="${VERSION}"
BUILT_MODULE_NAME[0]="nvidia"
BUILT_MODULE_NAME[1]="nvidia-drm"
BUILT_MODULE_NAME[2]="nvidia-modeset"
BUILT_MODULE_NAME[3]="nvidia-uvm"
BUILT_MODULE_NAME[4]="nvidia-peermem"
DEST_MODULE_LOCATION[0]="/kernel/drivers/video"
DEST_MODULE_LOCATION[1]="/kernel/drivers/video"
DEST_MODULE_LOCATION[2]="/kernel/drivers/video"
DEST_MODULE_LOCATION[3]="/kernel/drivers/video"
DEST_MODULE_LOCATION[4]="/kernel/drivers/video"
MAKE[0]="'make' -j\$(nproc) KERNEL_UNAME=\${kernelver} SYSSRC=/lib/modules/\${kernelver}/build IGNORE_CC_MISMATCH=1 module-type=open"
AUTOINSTALL="yes"
EOF

# --- 7. Build and Install DKMS Modules ---
echo -e "\n${GREEN}Step 7: Registering, building, and installing modules via DKMS...${NC}"
echo "  -> Adding module to DKMS..."
dkms add -m "${DKMS_MODULE_NAME}" -v "${VERSION}"
echo "  -> Building the module (this may take a few minutes)..."
dkms build -m "${DKMS_MODULE_NAME}" -v "${VERSION}"
echo "  -> Installing the module for the current kernel..."
dkms install -m "${DKMS_MODULE_NAME}" -v "${VERSION}"

# --- 8. Clean Up ---
echo -e "\n${GREEN}Step 8: Cleaning up temporary files...${NC}"
rm -rf "$TEMP_EXTRACT_DIR"
cd /

# --- FINAL ---
echo -e "\n\n${GREEN}========================= PREPARATION COMPLETE! ==========================${NC}"
echo -e "${GREEN}The nvidia-open kernel modules have been successfully installed via DKMS.${NC}"
echo -e "They will automatically survive future kernel updates."
echo -e "\n${YELLOW}The next step is to install the userspace components (OpenGL etc.).${NC}"
echo ""

# --- Interactive Continuation ---
read -p "Should the NVIDIA installer be started now? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "\n${GREEN}Starting the NVIDIA installer... Please answer the following prompts.${NC}"
    sh "${INSTALLER_PATH}" --no-kernel-module
    echo -e "\n${GREEN}Installation of userspace components complete.${NC}"
    echo -e "A ${YELLOW}reboot${NC} is highly recommended."
else
    echo -e "\n${YELLOW}Action aborted.${NC}"
    echo "You can continue the installation manually at any time with the command:"
    echo -e "  ${YELLOW}sudo ${INSTALLER_PATH} --no-kernel-module${NC}"
fi

echo -e "${GREEN}==========================================================================${NC}"
