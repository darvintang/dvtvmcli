#!/bin/bash
set -e

# 这个脚本创建一个debian虚拟机，并创建一个管理员用户
# 使用当前用户名和SSH公钥。
username=$USER

# 硬盘容量，16GiB。后期可以扩容
disk_size=16384 # 16384 MB

if [ ! -d ./config ]; then
  mkdir ./config
fi

function format_mac {
  sed 's/.\{2\}/&:/g' | cut -d ":" -f 1-6
}

function generate_mac {
  printf '%012x\n' "$(( 0x$(hexdump -e '6/1 "%02x" "\n"' -n 6 /dev/urandom) & 0xfeffffffffff | 0x020000000000 ))"
}

networkCount=3

# 编写默认配置，如果需要更改请自行修改
cat << EOF > ./config/vm.conf
kernel=boot/vmlinuz
initrd=boot/initrd
cmdlines=console=tty0
cmdlines=console=hvc0
cmdlines=irqfixup
cmdlines=root=/dev/vda1
cpu-count=1
memory-size=1024
disk=debian.img
cdrom=seed.iso
EOF

for((i=1;i<=networkCount;i++)); do
  mac=`generate_mac | format_mac`
  echo "network=$mac" >> ./config/vm.conf
done


# 获取cpu架构
arch="$(/usr/bin/uname -m)"

if [ "$arch" = "x86_64" ]; then
	arch="amd64"
fi

# 查看是否存在公钥，用于免密登录虚拟机
if [ ! -e ~/.ssh/id_rsa.pub ]; then
	echo "cannot find ~/.ssh/id_rsa.pub, stop" >&2
	exit 1
fi

# 下载ubuntu vmlinuz 和 initrd 文件
if [ "$arch" = "amd64" ]; then
/usr/bin/curl -C - -o ubnt-vmlinuz "https://cloud-images.ubuntu.com/releases/focal/release/unpacked/ubuntu-20.04-server-cloudimg-$arch-vmlinuz-generic"
else
/usr/bin/curl -C - -o ubnt-vmlinuz.gz "https://cloud-images.ubuntu.com/releases/focal/release/unpacked/ubuntu-20.04-server-cloudimg-$arch-vmlinuz-generic"
gunzip ubnt-vmlinuz.gz
fi

/usr/bin/curl -C - -o ubnt-initrd "https://cloud-images.ubuntu.com/releases/focal/release/unpacked/ubuntu-20.04-server-cloudimg-$arch-initrd-generic"

# 下载debian磁盘镜像
/usr/bin/curl -LC - -o debian.img "https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-$arch.raw"

# 创建用于复制vmlinuz和initrd的临时磁盘映像
dd if=/dev/null of=kernel.img bs=1m count=0 seek=200
KERNEL_DISK=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount kernel.img)
newfs_msdos -v KERNEL ${KERNEL_DISK}
hdiutil detach ${KERNEL_DISK}

# 添加virtio_console到initramfs 并提取vmlinuz和initrd文件
cat << EOFOUTER | expect | sed 's/[^[:print:]]//g'
set timeout 60
spawn vmcli --kernel=ubnt-vmlinuz --initrd=ubnt-initrd --disk=debian.img --disk=kernel.img --cmdlines=console=hvc0 --cmdlines=irqfixup

expect "(initramfs) "
send -- "mkdir /mnt\r"
expect "(initramfs) "
send -- "mkdir /kernel\r"
expect "(initramfs) "
send -- "mount /dev/vda1 /mnt\r"
expect "(initramfs) "
send -- "mount /dev/vdb /kernel\r"
expect "(initramfs) "
send -- "chroot /mnt\r"
expect "# "
send -- "echo virtio_console >> /etc/initramfs-tools/modules\r"
expect "# "
send -- "update-initramfs -u\r"
expect "# "
send -- "exit\r"
expect "(initramfs) "
send -- "cp /mnt/boot/initrd.img-* /kernel/initrd\r"
expect "(initramfs) "
send -- "cp /mnt/boot/vmlinuz-* /kernel/vmlinuz\r"
expect "(initramfs) "
send -- "umount /mnt\r"
expect "(initramfs) "
send -- "umount /kernel\r"
expect "(initramfs) "
send -- "poweroff\r"
EOFOUTER

# 从上面创建的磁盘里将 initrd 和 vmlinuz 拷贝出来
KERNEL_PATH=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage kernel.img | awk '{ print $2;}')
cp ${KERNEL_PATH}/* .
chmod 644 initrd vmlinuz
hdiutil detach ${KERNEL_DISK}

# 调整已定义大小的目标磁盘大小
/bin/dd if=/dev/null of=debian.img bs=1m count=0 seek="$disk_size"

# 创建cloud.init配置
rm -f seed.iso
mkdir iso_folder

# 注入公钥，免密登录，如果需要自定义管理员用户名修改 - name:
cat << EOF > iso_folder/user-data
#cloud-config
users:
  - default
  - name: $username
    lock_passwd: False
    gecos: $username
    groups: [adm, audio, cdrom, dialout, dip, floppy, lxd, netdev, plugdev, sudo, video]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
    ssh-authorized-keys:
      - $(cat ~/.ssh/id_rsa.pub | head -n 1)
bootcmd:
  - apt remove -y irqbalance
network:
    version: 2
    renderer: networkd
    ethernets:
        enp0s1:
            dhcp4: true
EOF

touch iso_folder/meta-data
hdiutil makehybrid -iso -joliet -iso-volume-name cidata  -joliet-volume-name cidata -o seed.iso iso_folder
rm -rf iso_folder

# 创建boot文件夹，存放虚拟机启动内核文件
if [ ! -d ./boot ]; then
  mkdir ./boot
fi

mv initrd ./boot/initrd
mv vmlinuz ./boot/vmlinuz

# 将不必要的文件移动到clean文件夹
if [ ! -d ./clean ]; then
  mkdir ./clean
fi
mv kernel.img ubnt-* ./clean