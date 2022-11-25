# DVTVMCLI

通过`Virtualization.framework`创建管理虚拟机的软件，轻便简单地创建Debian/Ubuntu虚拟机。

## 安装

### 系统环境

- macOS 11+
- Xcode(如果需要自己打包)

### 方案1

将`bin`文件夹下的三个文件拷贝到`PATH`包含了的路径文件夹下，或者拷贝后配置`PATH`。

### 方案2

克隆源码，然后在源码的文件夹路径下在终端下自行打包。自定义安装路径请编辑`Makefile`。

默认安装在`/opt/tools/bin`。ARM架构的macOS推荐安装在`/opt`目录。x86架构一般安装在`/usr/local`目录

> forward是socat的封装，需要自行安装socat，建议通过brew进行安装

## 使用

安装后在`~/.zshrc`或`~/.baserc`等终端环境配置文件加入`VMCTLDIR`配置，用于存放虚拟机文件。

```shell
export VMCTLDIR="$HOME/Virtual"
```

### vmcli

`vmcli`是创建管理虚拟机的关键程序。

```shell
OVERVIEW: 虚拟机控制程序

当使用tty连接虚拟机的时候，esc+q退出，command+w关闭

USAGE: vmcli [--cpu-count <cpu-count>] [--memory-size <memory-size>] [--memory-size-suffix <memory-size-suffix>] [--disk <disk> ...] [--cdrom <cdrom> ...] [--folder <folder> ...] [--network <network> ...] [--balloon <balloon>] [--kernel <kernel>] [--initrd <initrd>] [--cmdlines <cmdlines> ...] [--test <test>]

OPTIONS:
  -c, --cpu-count <cpu-count>
                          CPU 数量，范围：1 ~ 4 (default: 1)
  -m, --memory-size <memory-size>
                          运行内存，范围：128MiB ~ 16GiB (default: 512)
  --memory-size-suffix <memory-size-suffix>
                          运行内存单位，范围：MB、MiB、GB、GiB (default: MiB)
  -d, --disk <disk>       挂载的磁盘
  --cdrom <cdrom>         挂载的只读光盘
  -f, --folder <folder>   共享的文件夹
  -n, --network <network> 挂载的网卡。示例：aa:bb:cc:dd:ee:ff 创建一个共享的网络
  --balloon <balloon>     启用/禁用内存膨胀 (default: true)
  -k, --kernel <kernel>   vmlinuz文件路径
  --initrd <initrd>       initrd文件路径
  -c, --cmdlines <cmdlines>
                          内核运行的命令
  --test <test>           配置测试 (default: false)
  -h, --help              Show help information.
```

### vmctl

`vmcli`参数太多，每一次启动虚拟机都设置这些参数太过于麻烦，`vmctl`可以快速的启动管理通过`vmbuilders`文件夹下创建的虚拟机。

```shell
使用: vmctl {test|start|stop|attach|ip} vm #测试/启动/停止/tty连接/查ip 虚拟机
      vmctl list #列出虚拟机状态
```

### forward

`forward`是利用`socat`快捷设定管理端口数据转发的脚本

```shell
用法：
    forward start ip=目标ip from=本机端口 to=目标端口 [deal={tcp|udp}]
    eg: forward ip=192.168.1.101 from=80 to=80 <将本地80端口tcp报文转发到192.168.1.101主机的80端口>
    eg: forward ip=192.168.1.101 from=80 to=80 deal=udp <将本地80端口udp报文转发到192.168.1.101主机的80端口>
    forward stop [ip=目标ip|from=本机端口|to=目标端口|deal={tcp|udp}]
    forward list
```

## 示例

首先创建`ssh`登录的公私钥，如果已经创建跳过。参考：[Mac本地生成SSH Key 的方法](https://juejin.cn/post/6844903999460622350)；搜索关键词：macOS 创建ssh密钥。

创建虚拟机文件夹，从`vmbuilders`文件夹拷贝`build_ubuntu.sh`或`build_debian.sh`脚本。

在终端进入虚拟机文件夹，运行`build_ubuntu.sh`或`build_debian.sh`脚本，如果需要修改虚拟机内存大小、CPU数量、硬盘大小请编辑脚本，或者创建虚拟机之后修改虚拟机的配置文件：`conf/vm.conf`

> 注意，如果需要自定义`config/vm.conf`，最后一行一定要留空，不然最后一行配置读取不到

```shell
# ./build_debian.sh 
$ ./build_ubuntu.sh
```

等待脚本下载镜像并创建虚拟机所需要的文件，在脚本运行完毕之后就可以管理启动虚拟机了。

```shell
$ vmctl start ubuntu
# 第一次登录没有root和自定义用户的秘密，所以接下来tty启动查看ip，一定要启动后立马tty连接虚拟机
$ vmctl attach ubuntu
# 查询到ip之后，通过ssh远程登录到虚拟机设置密码
# 或者等虚拟机启动后通过vmctl查询ip，该方式不一定能查询到，原理是使用arp通过mac地址查ip
$ vmctl ip ubuntu
```

## 扩展

`Virtualization.framework`启动虚拟机内核和系统是分离的，所以在虚拟机系统内升级内核后重启后内核是不会变的。

升级内核的方式是先在虚拟机内升级内核，然后通过`ssh`把虚拟机系统内核拷贝出来，替换掉虚拟机文件夹`boot`文件夹下的两个内核文件，关闭虚拟机，通过`vmctl`启动虚拟机才能启动新的内核。

最后清理虚拟机系统内的老内核。

替换的时候先保留老内核，避免替换的内核没办法启动。

> 以上验证设备是21款的M1MaxMacBookPro，系统是macOS13.1 beta，x86环境未测试。

## 参考

[vmcli](https://github.com/gyf304/vmcli)  一组实用程序，帮助您使用`Virtualization.framework`管理虚拟系统。
