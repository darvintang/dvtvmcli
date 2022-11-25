#!/bin/bash
set -e

# this script creates a ubuntu VM which the current user's
# username and ssh public key.

# uncomment the following line to keep temp files
# skip_cleanup=1

# disk size, default to 4096 mb
disk_size=4096 # 4096 MB

if [ ! -d ./config ]; then
  mkdir ./config
fi

function format_mac {
  sed 's/.\{2\}/&:/g' | cut -d ":" -f 1-6
}

function generate_mac {
  printf '%012x\n' "$(( 0x$(hexdump -e '6/1 "%02x" "\n"' -n 6 /dev/urandom) & 0xfeffffffffff | 0x020000000000 ))"
}

# write default config, change if needed
cat << EOF > ./config/vm.conf
kernel=boot/vmlinux
initrd=boot/initrd
cmdlines=console=hvc0
cmdlines=irqfixup
cmdlines=root=/dev/vda
cpu-count=1
memory-size=1024
disk=disk.img
EOF

for((i=1;i<=networkCount;i++)); do
  mac=`generate_mac | format_mac`
  echo "network=$mac" >> ./config/vm.conf
done

arch="$(/usr/bin/uname -m)"

if [ "$arch" = "x86_64" ]; then
	arch="amd64"
fi

if [ ! -e ~/.ssh/id_rsa.pub ]; then
	echo "cannot find ~/.ssh/id_rsa.pub, stop" >&2
	exit 1
fi

# download files
if [ ! -e vmlinux ]; then
if [ "$arch" = "amd64" ]; then
/usr/bin/curl -o vmlinux "https://cloud-images.ubuntu.com/releases/focal/release/unpacked/ubuntu-20.04-server-cloudimg-$arch-vmlinuz-generic"
else
/usr/bin/curl -o vmlinux.gz "https://cloud-images.ubuntu.com/releases/focal/release/unpacked/ubuntu-20.04-server-cloudimg-$arch-vmlinuz-generic"
gunzip vmlinux.gz
fi
fi

if [ ! -e initrd ]; then
/usr/bin/curl -o initrd "https://cloud-images.ubuntu.com/releases/focal/release/unpacked/ubuntu-20.04-server-cloudimg-$arch-initrd-generic"
fi

if [ ! -e disk.tar.gz ]; then
/usr/bin/curl -o disk.tar.gz "https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-$arch.tar.gz"
fi

tar xzvf disk.tar.gz
mv "focal-server-cloudimg-$arch.img" disk.img
rm README

# create cloudinit config
cat << EOF > user.yaml
users:
  - name: $USER
    lock_passwd: False
    gecos: $USER
    groups: [adm, audio, cdrom, dialout, dip, floppy, lxd, netdev, plugdev, sudo, video]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
    ssh-authorized-keys:
      - $(cat ~/.ssh/id_rsa.pub | head -n 1)
EOF

# boot into initramfs to modify the disk image
cat << EOFOUTER | expect | sed 's/[^[:print:]]//g'
set timeout 60
spawn vmcli -k vmlinux --initrd=initrd -d disk.img --cmdlines=console=hvc0 --cmdlines=irqfixup"

expect "(initramfs) "
send -- "mkdir /mnt\r"
expect "(initramfs) "
send -- "mount /dev/vda /mnt\r"
expect "(initramfs) "
send -- "cat << EOF > /mnt/etc/cloud/cloud.cfg.d/99_user.cfg\r"
send [exec cat user.yaml]
send -- "\rEOF\r"
expect "(initramfs) "
send -- "chroot /mnt\r"
expect "# "
send -- "sudo apt-get remove -y irqbalance\r"
expect "# "
send -- "exit\r"
expect "(initramfs) "
send -- "umount /mnt\r"
expect "(initramfs) "
send -- "poweroff\r"
EOFOUTER

# expand disk to 4GB
/bin/dd if=/dev/null of=disk.img bs=1m count=0 seek="$disk_size"

# 创建boot文件夹，存放虚拟机启动内核文件
if [ ! -d ./boot ]; then
  mkdir ./boot
fi

mv initrd ./boot/initrd
mv vmlinux ./boot/vmlinux

# perform clean up
if [ "$skip_cleanup" != "" ]; then
	exit 0
fi

rm user.yaml
rm disk.tar.gz
