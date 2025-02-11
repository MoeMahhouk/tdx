#!/bin/bash
#

# This script will create a TDX guest image (qcow2 format) from a cloud
# image that is released at : https://cloud-images.ubuntu.com
# The cloud image is released as qcow3/qcow2 image (with .img suffix)
# The image comes with only 2 partitions:
#   - rootfs (~2G -> /)
#   - BIOS Boot (4M)
#   - EFI partition (~100M -> /boot/efi/ partition)
#   - Ext boot (/boot/ partition)
#
# As first step, we will resize the rootfs partition to a bigger size
# As second step, we will boot up the image to run cloud-init (using virtinst)
# and finally, we use virt-customize to copy in and run TDX setup script
#
# TODO : ask cloud init to run the TDX setup script

CURR_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# source config file
if [ -f ${CURR_DIR}/../../setup-tdx-config ]; then
    source ${CURR_DIR}/../../setup-tdx-config
fi

LOGFILE=/tmp/tdx-guest-setup.txt
WORK_DIR=${PWD}
FORCE_RECREATE=false
OFFICIAL_UBUNTU_IMAGE=${OFFICIAL_UBUNTU_IMAGE:-"https://cloud-images.ubuntu.com/releases/noble/release/"}
CLOUD_IMG=${CLOUD_IMG:-"ubuntu-24.04-server-cloudimg-amd64.img"}
if [[ "${TDX_SETUP_INTEL_KERNEL}" == "1" ]]; then
    GUEST_IMG="tdx-guest-ubuntu-24.04-intel.qcow2"
else
    GUEST_IMG="tdx-guest-ubuntu-24.04-generic.qcow2"
fi
SIZE=50
GUEST_USER=${GUEST_USER:-"tdx"}
GUEST_PASSWORD=${GUEST_PASSWORD:-"123456"}
GUEST_HOSTNAME=${GUEST_HOSTNAME:-"tdx-guest"}
BINARIES_PATH=${BINARIES_PATH:-"./binaries"}
RAM_BINARIES_PATH=${RAM_BINARIES_PATH:-"${CURR_DIR}/ram-binaries"}
BINARY_DEST_DIR="/bin"

ok() {
    echo -e "\e[1;32mSUCCESS: $*\e[0;0m"
}

error() {
    echo -e "\e[1;31mERROR: $*\e[0;0m"
    cleanup
    exit 1
}

warn() {
    echo -e "\e[1;33mWARN: $*\e[0;0m"
}

check_tool() {
    [[ "$(command -v $1)" ]] || { error "$1 is not installed" 1>&2 ; }
}

usage() {
    cat <<EOM
Usage: $(basename "$0") [OPTION]...
  -h                        Show this help
  -f                        Force to recreate the output image
  -n                        Guest host name, default is "tdx-guest"
  -u                        Guest user name, default is "tdx"
  -p                        Guest password, default is "123456"
  -s                        Specify the size of guest image
  -o <output file>          Specify the output file, default is tdx-guest-ubuntu-24.04.qcow2.
                            Please make sure the suffix is qcow2. Due to permission consideration,
                            the output file will be put into /tmp/<output file>.
  -b <binary path>          Path to the binary to be added to the initrd
  -d <binary destination>   Destination directory within initrd, default is /bin
EOM
}

process_args() {
    while getopts "o:s:n:u:p:b:d:r:rfch" option; do
        case "$option" in
        o) GUEST_IMG=$OPTARG ;;
        s) SIZE=$OPTARG ;;
        n) GUEST_HOSTNAME=$OPTARG ;;
        u) GUEST_USER=$OPTARG ;;
        p) GUEST_PASSWORD=$OPTARG ;;
        b) BINARIES_PATH=$OPTARG ;;
        d) BINARY_DEST_DIR=$OPTARG ;;
        r) RAM_BINARIES_PATH=$OPTARG ;; 
        f) FORCE_RECREATE=true ;;
        h)
            usage
            exit 0
            ;;
        *)
            echo "Invalid option '-$OPTARG'"
            usage
            exit 1
            ;;
        esac
    done

    if [[ "${CLOUD_IMG}" == "${GUEST_IMG}" ]]; then
        error "Please specify a different name for guest image via -o"
    fi

    if [[ ${GUEST_IMG} != *.qcow2 ]]; then
        error "The output file should be qcow2 format with the suffix .qcow2."
    fi
}

download_image() {
    # Get the checksum file first
    if [[ -f ${CURR_DIR}/"SHA256SUMS" ]]; then
        rm ${CURR_DIR}/"SHA256SUMS"
    fi

    wget "${OFFICIAL_UBUNTU_IMAGE}/SHA256SUMS"

    while :; do
        # Download the cloud image if not exists
        if [[ ! -f ${CLOUD_IMG} ]]; then
            wget -O ${CURR_DIR}/${CLOUD_IMG} ${OFFICIAL_UBUNTU_IMAGE}/${CLOUD_IMG}
        fi

        # calculate the checksum
        download_sum=$(sha256sum ${CURR_DIR}/${CLOUD_IMG} | awk '{print $1}')
        found=false
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == *"$CLOUD_IMG"* ]]; then
                if [[ "${line%% *}" != ${download_sum} ]]; then
                    echo "Invalid download file according to sha256sum, re-download"
                    rm ${CURR_DIR}/${CLOUD_IMG}
                else
                    ok "Verify the checksum for Ubuntu cloud image."
                    return
                fi
                found=true
            fi
        done <"SHA256SUMS"
        if [[ $found != "true" ]]; then
            echo "Invalid SHA256SUM file"
            exit 1
        fi
    done
}

create_guest_image() {
    if [ ${FORCE_RECREATE} = "true" ]; then
        rm -f ${CURR_DIR}/${CLOUD_IMG}
    fi

    download_image

    # this image will need to be customized both by virt-customize and virt-install
    # virt-install will interact with libvirtd and if the latter runs in normal user mode
    # we have to make sure that guest image is writable for normal user
    install -m 0777 ${CURR_DIR}/${CLOUD_IMG} /tmp/${GUEST_IMG}
    if [ $? -eq 0 ]; then
        ok "Copy the ${CLOUD_IMG} => /tmp/${GUEST_IMG}"
    else
        error "Failed to copy ${CLOUD_IMG} to /tmp"
    fi

    resize_guest_image
}

resize_guest_image() {
    qemu-img resize /tmp/${GUEST_IMG} +${SIZE}G
    virt-customize -a /tmp/${GUEST_IMG} \
        --run-command 'growpart /dev/sda 1' \
        --run-command 'resize2fs /dev/sda1' \
        --run-command 'systemctl mask pollinate.service'
    if [ $? -eq 0 ]; then
        ok "Resize the guest image to ${SIZE}G"
    else
        warn "Failed to resize guest image to ${SIZE}G"
    fi
}

config_cloud_init_cleanup() {
  virsh shutdown tdx-config-cloud-init &> /dev/null
  sleep 1
  virsh destroy tdx-config-cloud-init &> /dev/null
  virsh undefine tdx-config-cloud-init &> /dev/null
}

config_cloud_init() {
    pushd ${CURR_DIR}/cloud-init-data
    [ -e /tmp/ciiso.iso ] && rm /tmp/ciiso.iso
    cp user-data.template user-data
    cp meta-data.template meta-data

    # configure the user-data
    cat <<EOT >> user-data

user: $GUEST_USER
password: $GUEST_PASSWORD
chpasswd: { expire: False }
EOT

    # configure the meta-dta
    cat <<EOT >> meta-data

local-hostname: $GUEST_HOSTNAME
EOT

    ok "Generate configuration for cloud-init..."
    genisoimage -output /tmp/ciiso.iso -volid cidata -joliet -rock user-data meta-data
    ok "Generate the cloud-init ISO image..."
    popd

    virt-install --debug --memory 4096 --vcpus 4 --name tdx-config-cloud-init \
        --disk /tmp/${GUEST_IMG} \
        --disk /tmp/ciiso.iso,device=cdrom \
        --os-variant ubuntu24.04 \
        --virt-type kvm \
        --graphics none \
        --import \
        --wait=12 &>> $LOGFILE
    if [ $? -eq 0 ]; then
        ok "Complete cloud-init..."
        sleep 1
    else
        warn "Please increase wait time(--wait=12) above and try again..."
        error "Failed to configure cloud init"
    fi

    config_cloud_init_cleanup
}

setup_guest_image() {
    virt-customize -a /tmp/${GUEST_IMG} \
        --mkdir /tmp/tdx/ \
        --mkdir /tmp/tdx/bin \
        --copy-in ${CURR_DIR}/setup.sh:/tmp/tdx/ \
        --copy-in ${CURR_DIR}/../../setup-tdx-guest.sh:/tmp/tdx/ \
        --copy-in ${CURR_DIR}/../../setup-tdx-common:/tmp/tdx \
        --copy-in ${CURR_DIR}/../../setup-tdx-config:/tmp/tdx \
        --copy-in ${CURR_DIR}/../../attestation/:/tmp/tdx \
        --copy-in ${BINARIES_PATH}:/tmp/tdx/bin \
        --run-command "mv /tmp/tdx/bin/${BINARIES_PATH}/* /bin/" \
        --run-command "/tmp/tdx/setup.sh"
    if [ $? -eq 0 ]; then
        ok "Setup guest image..."
    else
        error "Failed to setup guest image"
    fi
}

inject_binary_into_initrd() {
    # Load the NBD module
    sudo modprobe nbd max_part=8

    # Connect the image
    sudo qemu-nbd -c /dev/nbd0 /tmp/${GUEST_IMG}

    # Probe the partitions
    sudo partprobe /dev/nbd0

    # Identify the partitions
    local root_partition
    root_partition=$(lsblk -lno NAME,TYPE | grep part | awk '{print $1}' | head -n 1)

    # Mount the root partition
    sudo mount /dev/$root_partition /mnt

    # Extract and modify the initrd
    sudo mkdir /mnt/initrd
    sudo cp /mnt/boot/initrd.img-* /mnt/initrd/initrd.img
    pushd /mnt/initrd
    # sudo gzip -d initrd.img
    sudo cpio -id < initrd.img

    # Add the binary
    sudo cp ${BINARIES_PATH} ${BINARY_DEST_DIR}/
    sudo chmod +x ${BINARY_DEST_DIR}/$(basename ${BINARIES_PATH})

    # Add execution to init script
    echo "${BINARY_DEST_DIR}/$(basename ${BINARIES_PATH})" | sudo tee -a /mnt/initrd/init

    # Repack the initrd
    find . | cpio -o -H newc | gzip > /mnt/boot/initrd.img-$(basename /mnt/boot/initrd.img-*)
    popd

    # Cleanup
    sudo umount /mnt
    sudo qemu-nbd -d /dev/nbd0
}

inject_ram_binaries_into_initrd() {
    # Install necessary tools
    sudo apt-get install -y cpio gzip libguestfs-tools file

    # Mount the guest image
    mkdir /mnt/guest
    guestmount -a /tmp/${GUEST_IMG} -i /mnt/guest

    # Unpack the initrd
    mkdir /tmp/initrd
    cd /tmp/initrd

    # Check if the initrd is in gzip format
    local is_compressed=0
    if file /mnt/guest/boot/initrd.img-* | grep -q gzip; then
        gzip -dc < /mnt/guest/boot/initrd.img-* | cpio -idmv
        is_compressed=1
    else
        # If the initrd is not compressed, extract it directly
        cpio -idmv < /mnt/guest/boot/initrd.img-*
    fi

    # Add the binaries
    cp ${RAM_BINARIES_PATH}/* .

    # Modify the startup script
    for binary in *; do
        echo "Adding $binary to initrd"
        # Make the binaries executable
        chmod +x $binary
        echo "./$binary" >> init
    done

    # Repack the initrd
    if [ "$is_compressed" -eq 1 ]; then
        find . | cpio -o -H newc | gzip > /mnt/guest/boot/myinitrd.img
    else
        find . | cpio -o -H newc > /mnt/guest/boot/myinitrd.img
    fi

    # Unmount the guest image
    cd /
    guestunmount /mnt/guest
}

cleanup() {
    if [[ -f ${CURR_DIR}/"SHA256SUMS" ]]; then
        rm ${CURR_DIR}/"SHA256SUMS"
    fi

    # Unmount and remove /mnt/guest if it still exists
    if [ -d /mnt/guest ]; then
        guestunmount /mnt/guest
        rm -rf /mnt/guest
    fi

    # Remove /tmp/initrd if it still exists
    if [ -d /tmp/initrd ]; then
        rm -rf /tmp/initrd
    fi
    ok "Cleanup!"
}

echo "=== tdx guest image generation === " > $LOGFILE

# sanity cleanup
config_cloud_init_cleanup

# install required tools
apt install --yes qemu-utils libguestfs-tools virtinst genisoimage libvirt-daemon-system &>> $LOGFILE

# to allow virt-customize to have name resolution, dhclient should be available
# on the host system. that is because virt-customize will create an appliance (with supermin)
# from the host system and will collect dhclient into the appliance
apt install --yes isc-dhcp-client &>> $LOGFILE

check_tool qemu-img
check_tool virt-customize
check_tool virt-install
check_tool genisoimage

ok "Installation of required tools"

process_args "$@"

#
# Check user permission
#
if (( $EUID != 0 )); then
    warn "Current user is not root, please use root permission via \"sudo\" or make sure current user has correct "\
         "permission by configuring /etc/libvirt/qemu.conf"
    warn "Please refer https://libvirt.org/drvqemu.html#posix-users-groups"
    sleep 5
fi

create_guest_image

config_cloud_init

setup_guest_image

#inject_ram_binaries_into_initrd
#inject_binary_into_initrd

cleanup

mv /tmp/${GUEST_IMG} ${WORK_DIR}/
chmod a+rw ${WORK_DIR}/${GUEST_IMG}

ok "TDX guest image : ${WORK_DIR}/${GUEST_IMG}"
