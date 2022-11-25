import ArgumentParser
import Foundation
import Virtualization

enum BootLoader: String, ExpressibleByArgument {
    case linux
}

enum SizeSuffix: UInt64, ExpressibleByArgument {
    case none = 1,
         KB = 1000, KiB = 0x400,
         MB = 1000000, MiB = 0x100000,
         GB = 1000000000, GiB = 0x40000000
}

var origStdinTerm: termios?
var origStdoutTerm: termios?

var vm: VZVirtualMachine?

var stopRequesting = false

func stopVM() {
    guard let vm = vm, vm.state == .running else {
        standardOutput("虚拟机状态异常")
        return
    }
    if stopRequesting {
        return
    }
    do {
        standardOutput("检测到esc+q，退出虚拟机。")
        stopRequesting = true
        try vm.requestStop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            quit(0)
        }
    } catch let error {
        standardOutput("虚拟机退出失败：\(error.localizedDescription)")
        standardOutput("强制退出")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            quit(1)
        }
    }
}

func standardOutput(_ value: String) {
    if let data = value.data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
}

// mask TERM signals so we can perform clean up
let signalMask = SIGPIPE | SIGINT | SIGTERM | SIGHUP
signal(signalMask, SIG_IGN)

let sigintSrc = DispatchSource.makeSignalSource(signal: signalMask, queue: .main)
sigintSrc.setEventHandler {
    quit(1)
}

sigintSrc.resume()

func setupTty() {
    if isatty(0) != 0 {
        origStdinTerm = termios()
        var term = termios()
        tcgetattr(0, &origStdinTerm!)
        tcgetattr(0, &term)
        cfmakeraw(&term)
        tcsetattr(0, TCSANOW, &term)
    }
}

func resetTty() {
    if origStdinTerm != nil {
        tcsetattr(0, TCSANOW, &origStdinTerm!)
    }
    if origStdoutTerm != nil {
        tcsetattr(1, TCSANOW, &origStdoutTerm!)
    }
}

func quit(_ code: Int32) -> Never {
    resetTty()
    return exit(code)
}

func openDisk(path: String, readOnly: Bool) throws -> VZVirtioBlockDeviceConfiguration {
    let vmDiskURL = URL(fileURLWithPath: path)
    let vmDisk: VZDiskImageStorageDeviceAttachment
    do {
        vmDisk = try VZDiskImageStorageDeviceAttachment(url: vmDiskURL, readOnly: readOnly)
    } catch {
        throw error
    }
    let vmBlockDevCfg = VZVirtioBlockDeviceConfiguration(attachment: vmDisk)
    return vmBlockDevCfg
}

@available(macOS 12, *)
func openFolder(path: String) throws -> VZDirectorySharingDeviceConfiguration {
    let sharedDirectory = VZSharedDirectory(url: URL(fileURLWithPath: path), readOnly: false)
    let vzDirShare = VZVirtioFileSystemDeviceConfiguration(tag: path)
    vzDirShare.share = VZSingleDirectoryShare(directory: sharedDirectory)
    return vzDirShare
}

class OccurrenceCounter {
    let pattern: Data
    var i = 0
    init(_ pattern: Data) {
        self.pattern = pattern
    }

    func process(_ data: Data) -> Int {
        if self.pattern.count == 0 {
            return 0
        }
        var occurrences = 0
        for byte in data {
            if byte == self.pattern[self.i] {
                self.i += 1
                if self.i >= self.pattern.count {
                    occurrences += 1
                    self.i = 0
                }
            } else {
                self.i = 0
            }
        }
        return occurrences
    }
}

class VMCLIDelegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        quit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        quit(1)
    }

    @available(macOS 12.0, *)
    func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        quit(1)
    }
}

let delegate = VMCLIDelegate()

let vmCfg = VZVirtualMachineConfiguration()

struct VMCLI: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "虚拟机控制程序",
        discussion: "当使用tty连接虚拟机的时候，esc+q退出，command+w关闭"
    )
    @Option(name: .shortAndLong, help: "CPU 数量，范围：1 ~ 4")
    var cpuCount: Int = 1

    @Option(name: .shortAndLong, help: "运行内存，范围：128MiB ~ 16GiB")
    var memorySize: UInt64 = 512 // 512 MiB default

    @Option(name: .long, help: "运行内存单位，范围：MB、MiB、GB、GiB")
    var memorySizeSuffix: SizeSuffix = SizeSuffix.MiB

    @Option(name: [.short, .customLong("disk")], help: "挂载的磁盘")
    var disks: [String] = []

    @Option(name: [.customLong("cdrom")], help: "挂载的只读光盘")
    var cdroms: [String] = []

    @Option(name: [.short, .customLong("folder")], help: "共享的文件夹")
    var folders: [String] = []

    @Option(name: [.short, .customLong("network")], help: """
    挂载的网卡。\
    示例：\
    aa:bb:cc:dd:ee:ff 创建一个共享的网络
    """)
    var networks: [String] = []

    @Option(help: "启用/禁用内存膨胀")
    var balloon: Bool = true

    @Option(name: .shortAndLong, help: "vmlinuz文件路径")
    var kernel: String?

    @Option(help: "initrd文件路径")
    var initrd: String?

    @Option(name: [.short, .customLong("cmdlines")], help: "内核运行的命令")
    var cmdlines: [String] = []

    @Option(help: "配置测试")
    var test = false

    mutating func run() throws {
        var cpuCount = 1
        if (1 ... 4).contains(self.cpuCount) {
            cpuCount = self.cpuCount
        }

        vmCfg.cpuCount = cpuCount

        var memorySize = 512 * SizeSuffix.MiB.rawValue

        let tSize = self.memorySize * self.memorySizeSuffix.rawValue
        if 128 * SizeSuffix.MiB.rawValue <= tSize, tSize <= 16 * SizeSuffix.GiB.rawValue {
            memorySize = tSize
        }

        vmCfg.memorySize = memorySize

        if self.kernel == nil {
            throw ValidationError("vmlinuz文件路径错误")
        }
        let vmKernelURL = URL(fileURLWithPath: kernel!)
        let vmBootLoader = VZLinuxBootLoader(kernelURL: vmKernelURL)
        if self.initrd != nil {
            vmBootLoader.initialRamdiskURL = URL(fileURLWithPath: self.initrd!)
        }

        vmBootLoader.commandLine = self.cmdlines.joined(separator: " ")
        vmCfg.bootLoader = vmBootLoader

        // set up storage
        // TODO: better error handling
        vmCfg.storageDevices = []
        for disk in self.disks {
            try vmCfg.storageDevices.append(openDisk(path: disk, readOnly: false))
        }
        for cdrom in self.cdroms {
            try vmCfg.storageDevices.append(openDisk(path: cdrom, readOnly: true))
        }

        // The #available check still causes a runtime dyld error on macOS 11 (Big Sur),
        // apparently due to a Swift bug, so add an extra check to work around this until
        // the bug is resolved. See eg https://developer.apple.com/forums/thread/688678

        if #available(macOS 12, *) {
            for folder in folders {
                puts("Adding shared folder '\(folder)', but be warned, this might be unstable.")
                try vmCfg.directorySharingDevices.append(openFolder(path: folder))
            }
        }

        // set up networking
        // TODO: better error handling
        vmCfg.networkDevices = []
        for network in self.networks {
//            let parts = network.split(separator: "@")
//            if parts.count != 2 {
//                continue
//            }
            if let macAddress = VZMACAddress(string: network) {
                let netCfg = VZVirtioNetworkDeviceConfiguration()
                netCfg.macAddress = macAddress
                netCfg.attachment = VZNATNetworkDeviceAttachment()
                vmCfg.networkDevices.append(netCfg)
            }
//            let device = String(parts[1])
//            switch device {
//                case "nat":
//                    netCfg.attachment = VZNATNetworkDeviceAttachment()
//                default:
//                    for iface in VZBridgedNetworkInterface.networkInterfaces {
//                        if iface.identifier == device {
//                            netCfg.attachment = VZBridgedNetworkDeviceAttachment(interface: iface)
//                            break
//                        }
//                    }
//            }
//            if netCfg.attachment == nil {
//                continue
//            }
        }

        // set up memory balloon
        let balloonCfg = VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        vmCfg.memoryBalloonDevices = [balloonCfg]

        vmCfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        try vmCfg.validate()
        if !self.test {
            self.start()
        } else {
            print("配置测试通过")
        }
    }

    func start() {
        // disable stdin echo, disable stdin line buffer, disable ^C
        // set up tty
        let vmSerialIn = Pipe()
        let vmSerialOut = Pipe()

        let vmConsoleCfg = VZVirtioConsoleDeviceSerialPortConfiguration()
        let vmSerialPort = VZFileHandleSerialPortAttachment(
            fileHandleForReading: vmSerialIn.fileHandleForReading,
            fileHandleForWriting: vmSerialOut.fileHandleForWriting
        )
        vmConsoleCfg.attachment = vmSerialPort
        vmCfg.serialPorts = [vmConsoleCfg]
        setupTty()

        // set up piping.
        var fullEscapeSequence = Data([0x1B]) // escape sequence always starts with ESC
        if let data = "q".data(using: .nonLossyASCII) {
            fullEscapeSequence.append(data)
        }
        let escapeSequenceCounter = OccurrenceCounter(fullEscapeSequence)

        FileHandle.standardInput.waitForDataInBackgroundAndNotify()
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSFileHandleDataAvailable, object: FileHandle.standardInput, queue: nil)
            { _ in
                let data = FileHandle.standardInput.availableData
                if origStdinTerm != nil && escapeSequenceCounter.process(data) > 0 {
                    // 退出
                    stopVM()
                } else {
                    vmSerialIn.fileHandleForWriting.write(data)
                }
                if data.count > 0 {
                    FileHandle.standardInput.waitForDataInBackgroundAndNotify()
                }
            }

        vmSerialOut.fileHandleForReading.waitForDataInBackgroundAndNotify()
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSFileHandleDataAvailable, object: vmSerialOut.fileHandleForReading, queue: nil)
            { _ in
                let data = vmSerialOut.fileHandleForReading.availableData
                FileHandle.standardOutput.write(data)
                if data.count > 0 {
                    vmSerialOut.fileHandleForReading.waitForDataInBackgroundAndNotify()
                }
            }
        // start VM
        vm = VZVirtualMachine(configuration: vmCfg)
        vm!.delegate = delegate

        vm!.start(completionHandler: { (result: Result<Void, Error>) in
            switch result {
                case .success:
                    standardOutput("虚拟机启动成功")
                    standardOutput("请稍后")
                    return
                case let .failure(error):
                    standardOutput("虚拟机启动失败\(error.localizedDescription)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        quit(1)
                    }
            }
        })

        RunLoop.main.run()
    }
}

VMCLI.main()
