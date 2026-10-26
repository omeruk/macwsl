#if os(macOS)
    import Foundation
    import MawCore
    import Virtualization

    extension VMConfiguration.Limits {
        /// The limits Virtualization.framework reports for this Mac.
        public static var host: VMConfiguration.Limits {
            VMConfiguration.Limits(
                cpuCount: VZVirtualMachineConfiguration
                    .minimumAllowedCPUCount...VZVirtualMachineConfiguration.maximumAllowedCPUCount,
                memorySize: ByteSize(
                    bytes: VZVirtualMachineConfiguration.minimumAllowedMemorySize)...ByteSize(
                        bytes: VZVirtualMachineConfiguration.maximumAllowedMemorySize)
            )
        }
    }

    extension VMConfiguration {
        /// Builds the Virtualization.framework configuration: direct Linux boot, a virtio console
        /// (hvc0) on `consoleAttachment`, a virtio entropy device, a traditional memory balloon, a
        /// virtio socket device, one virtio block device per disk, and a virtio network device
        /// with NAT if `network` is set.
        ///
        /// CPU count and memory size are clamped to `Limits.host`. With `validate`, the
        /// configuration is checked with `validate()`, and its errors are mapped to
        /// `MawError`. Tests pass `false` to inspect a configuration in an unsigned process.
        func makeVirtualizationConfiguration(
            consoleAttachment: VZSerialPortAttachment,
            validate: Bool = true
        ) throws(MawError) -> VZVirtualMachineConfiguration {
            for url in [kernelURL, initramfsURL]
            where !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                throw .kernelNotFound(path: url.path(percentEncoded: false))
            }
            let settings = clamped(to: .host)

            let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
            bootLoader.initialRamdiskURL = initramfsURL
            bootLoader.commandLine = commandLine

            let console = VZVirtioConsoleDeviceSerialPortConfiguration()
            console.attachment = consoleAttachment

            let configuration = VZVirtualMachineConfiguration()
            configuration.bootLoader = bootLoader
            configuration.cpuCount = settings.cpuCount
            configuration.memorySize = settings.memorySize.bytes
            configuration.serialPorts = [console]
            configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            configuration.memoryBalloonDevices = [
                VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
            ]
            configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
            configuration.storageDevices = try disks.map { disk throws(MawError) in
                try Self.blockDevice(for: disk)
            }
            if let network {
                configuration.networkDevices = [try Self.networkDevice(for: network)]
            }

            if validate {
                do {
                    try configuration.validate()
                } catch {
                    throw VirtualizationErrors.map(error, during: .configure)
                }
            }
            return configuration
        }

        /// Caching is left to Virtualization.framework (`.automatic`); synchronization follows
        /// `Disk.synchronization`. docs/decisions/0013-systemd-and-the-agent.md records why.
        private static func blockDevice(
            for disk: Disk
        ) throws(MawError) -> VZVirtioBlockDeviceConfiguration {
            let path = disk.url.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path) else {
                throw .diskImageNotFound(path: path)
            }
            do {
                let attachment = try VZDiskImageStorageDeviceAttachment(
                    url: disk.url, readOnly: disk.isReadOnly, cachingMode: .automatic,
                    synchronizationMode: disk.synchronization == .full ? .full : .fsync)
                return VZVirtioBlockDeviceConfiguration(attachment: attachment)
            } catch {
                throw VirtualizationErrors.map(error, during: .configure)
            }
        }

        private static func networkDevice(
            for network: Network
        ) throws(MawError) -> VZVirtioNetworkDeviceConfiguration {
            switch network {
            case .nat(let text):
                guard let address = VZMACAddress(string: text) else {
                    throw .invalidVMConfiguration(reason: "'\(text)' is not a MAC address")
                }
                let device = VZVirtioNetworkDeviceConfiguration()
                device.attachment = VZNATNetworkDeviceAttachment()
                device.macAddress = address
                return device
            }
        }
    }
#endif
