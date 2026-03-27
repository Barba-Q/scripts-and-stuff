 #!/bin/bash
# ==============================================================================
# Script to prepare NVIDIA driver installation with DKMS (v2.2)
# OPEN MODULES(Void Linux).
# ADDED: Automated Scorched-Earth cleanup & Dracut Firmware Override.
# special thanks to jvassalo 
# ==============================================================================

set -e
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}Step 1: Performing checks & finding installer...${NC}"
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run with root privileges (sudo).${NC}"
   exit 1
fi

INSTALLER_FILE=$(find . -maxdepth 1 -type f -name "NVIDIA-Linux-x86_64-*.run" | sort -V | tail -n 1)
if [ -z "$INSTALLER_FILE" ]; then
    echo -e "${RED}Error: No NVIDIA .run file found in the current directory!${NC}"
    exit 1
fi
INSTALLER_PATH=$(realpath "$INSTALLER_FILE")
echo "  -> Found installer: ${YELLOW}$(basename "$INSTALLER_PATH")${NC}"

echo -e "\n${GREEN}Step 2: Installing missing basic dependencies...${NC}"
xbps-install -Sy base-devel linux-headers dkms libglvnd || true

echo -e "\n${GREEN}Step 3: Extracting driver version...${NC}"
VERSION=$(basename "$INSTALLER_PATH" | grep -oP '\d+\.\d+(?:\.\d+)?')
if [ -z "$VERSION" ]; then
    echo -e "${RED}Error: Could not extract version number.${NC}"
    exit 1
fi

# OPEN MODULE NAME FOR 50-SERIES:
DKMS_MODULE_NAME="nvidia-open"
DKMS_SRC_DIR="/usr/src/${DKMS_MODULE_NAME}-${VERSION}"
TEMP_EXTRACT_DIR="/var/tmp/nvidia-installer-extraction"
echo "  -> Target Version: ${YELLOW}${VERSION}${NC}"

echo -e "\n${GREEN}Step 4: Configuring GRUB and disabling nouveau...${NC}"
GRUB_FILE="/etc/default/grub"
if grep -q "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE"; then
    if ! grep -q "nvidia-drm.modeset=1" "$GRUB_FILE"; then
        sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^\"]*\)"/\1 rd.driver.blacklist=nouveau nouveau.modeset=0 nvidia-drm.modeset=1"/' "$GRUB_FILE"
        if command -v update-grub &> /dev/null; then
            update-grub
        else
            grub-mkconfig -o /boot/grub/grub.cfg
        fi
        echo "  -> GRUB updated successfully."
    else
        echo "  -> GRUB already configured."
    fi
fi

echo -e "\n${GREEN}Step 5: SCORCHED EARTH - Cleaning up all previous NVIDIA modules...${NC}"
rm -rf "$TEMP_EXTRACT_DIR"
# Find and remove any installed nvidia or nvidia-open modules from DKMS
for module in $(dkms status | grep -E "^(nvidia|nvidia-open)/" | awk -F', ' '{print $1}'); do
    echo "  -> Purging old module: $module"
    dkms remove "${module}" --all || true
done
rm -rf "$DKMS_SRC_DIR"

echo -e "\n${GREEN}Step 6: Extracting kernel sources...${NC}"
mkdir -p "$TEMP_EXTRACT_DIR"
if ! sh "$INSTALLER_PATH" -x --target "$TEMP_EXTRACT_DIR/extract"; then
    echo -e "${RED}Error: Extraction failed!${NC}"
    exit 1
fi
if [ -d "$TEMP_EXTRACT_DIR/extract/kernel" ]; then
    EXTRACTED_DIR="$TEMP_EXTRACT_DIR/extract"
else
    EXTRACTED_DIR=$(find "$TEMP_EXTRACT_DIR/extract" -maxdepth 1 -type d -name "NVIDIA-Linux-x86_64-*" | head -n 1)
fi
cd "$EXTRACTED_DIR"

echo -e "\n${GREEN}Step 7: Setting up DKMS...${NC}"
mkdir -p "$DKMS_SRC_DIR"
cp -r ./kernel/* "$DKMS_SRC_DIR/"

if [ -f "$DKMS_SRC_DIR/nvidia/nv-clk.c" ]; then
    sed -i 's|#include <soc/tegra/bpmp-abi.h>|/* & */|' "$DKMS_SRC_DIR/nvidia/nv-clk.c"
    sed -i 's|#include <soc/tegra/bpmp.h>|/* & */|' "$DKMS_SRC_DIR/nvidia/nv-clk.c"
fi

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

echo -e "\n${GREEN}Step 8: Building OPEN modules via DKMS...${NC}"
dkms add -m "${DKMS_MODULE_NAME}" -v "${VERSION}"
dkms build -m "${DKMS_MODULE_NAME}" -v "${VERSION}"
dkms install -m "${DKMS_MODULE_NAME}" -v "${VERSION}"

echo -e "\n${GREEN}Step 9: Cleaning up extraction temp files...${NC}"
rm -rf "$TEMP_EXTRACT_DIR"
cd /

echo -e "\n${GREEN}Step 10: Installing userspace libraries & firmware silently...${NC}"
sh "${INSTALLER_PATH}" -s --no-kernel-module --install-libglvnd --run-nvidia-xconfig

echo -e "\n${GREEN}Step 11: Forcing Dracut to include GSP Firmware...${NC}"
mkdir -p /etc/dracut.conf.d
echo 'install_items+=" /lib/firmware/nvidia/* "' > /etc/dracut.conf.d/20-nvidia-fw.conf

echo -e "\n${GREEN}Step 12: Rebuilding initramfs with new modules and GSP firmware...${NC}"
dracut --force

echo -e "\n\n${GREEN}========================= INSTALLATION COMPLETE! ==========================${NC}"
echo -e "Reboot your machine."
