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
        /// virtio socket device, and one virtio block device per disk.
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

            if validate {
                do {
                    try configuration.validate()
                } catch {
                    throw VirtualizationErrors.map(error, during: .configure)
                }
            }
            return configuration
        }

        private static func blockDevice(
            for disk: Disk
        ) throws(MawError) -> VZVirtioBlockDeviceConfiguration {
            let path = disk.url.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path) else {
                throw .diskImageNotFound(path: path)
            }
            do {
                let attachment = try VZDiskImageStorageDeviceAttachment(
                    url: disk.url, readOnly: disk.isReadOnly)
                return VZVirtioBlockDeviceConfiguration(attachment: attachment)
            } catch {
                throw VirtualizationErrors.map(error, during: .configure)
            }
        }
    }
#endif
