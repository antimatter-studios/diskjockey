//
//  ImageAttachmentRouteTests.swift — which attachment route each disk-image
//  container takes on its way to a block device (diskjockey#478).
//
//  hdiutil turns raw, VHD and VMDK images into block devices; it does not
//  read qcow2 or VHDX, which go to the DriverKit virtual disk instead. An
//  unrecognised container has no route and must be refused, not guessed.
//  Both routes reach Apple's filesystems through Disk Arbitration; the
//  DriverKit route mounts them read-only (diskjockey#486).
//
//  Host-free: nothing is attached.
//

import Testing
@testable import DiskJockeyLibrary

@Suite("Image attachment route")
struct ImageAttachmentRouteTests {
    @Test func rawUsesHdiutil() {
        #expect(ImageAttachmentRoute(container: "raw") == .hdiutil)
    }

    @Test func vhdUsesHdiutil() {
        #expect(ImageAttachmentRoute(container: "vhd") == .hdiutil)
    }

    @Test func vmdkUsesHdiutil() {
        #expect(ImageAttachmentRoute(container: "vmdk") == .hdiutil)
    }

    @Test func qcow2UsesDriverKit() {
        #expect(ImageAttachmentRoute(container: "qcow2") == .driverKit)
    }

    @Test func vhdxUsesDriverKit() {
        #expect(ImageAttachmentRoute(container: "vhdx") == .driverKit)
    }

    @Test func anUnknownContainerIsUnsupported() {
        #expect(ImageAttachmentRoute(container: "dmg") == .unsupported)
        #expect(ImageAttachmentRoute(container: "") == .unsupported)
    }

    @Test func theContainerNameIsMatchedCaseInsensitively() {
        #expect(ImageAttachmentRoute(container: "QCOW2") == .driverKit)
        #expect(ImageAttachmentRoute(container: "VHDX") == .driverKit)
        #expect(ImageAttachmentRoute(container: "Raw") == .hdiutil)
    }

    // Was a refusal for the DriverKit route; since diskjockey#486 both
    // attachment routes reach Apple's filesystems and only `.unsupported`
    // does not.
    @Test func onlyTheHdiutilRouteReachesAppleFilesystemsToday() {
        #expect(ImageAttachmentRoute.hdiutil.reachesAppleFilesystems)
        #expect(ImageAttachmentRoute.driverKit.reachesAppleFilesystems)
        #expect(!ImageAttachmentRoute.unsupported.reachesAppleFilesystems)
    }

    @Test func anAppleFilesystemOnADriverKitImageMountsThroughDiskArbitration() {
        let route = ImageAttachmentRoute(container: "qcow2")
        #expect(route.appleMountType(forProbeKind: "fat32") == "msdos")
        #expect(route.appleMountType(forProbeKind: "fat16") == "msdos")
        #expect(route.appleMountType(forProbeKind: "exfat") == "exfat")
        #expect(route.appleMountType(forProbeKind: "hfs_plus") == "hfs")
        #expect(route.appleMountType(forProbeKind: "apfs") == "apfs")
        #expect(ImageAttachmentRoute(container: "vhdx").appleMountType(forProbeKind: "apfs") == "apfs")
    }

    @Test func aDriverKitImageMountsReadOnlyAndAnHdiutilImageDoesNot() {
        #expect(ImageAttachmentRoute.driverKit.mountsReadOnly)
        #expect(!ImageAttachmentRoute.hdiutil.mountsReadOnly)
    }

    @Test func theHdiutilRouteKeepsItsAppleFilesystems() {
        #expect(ImageAttachmentRoute.hdiutil.appleMountType(forProbeKind: "apfs") == "apfs")
        #expect(ImageAttachmentRoute.hdiutil.appleMountType(forProbeKind: "fat32") == "msdos")
    }

    @Test func anUnsupportedImageReachesNoAppleFilesystem() {
        #expect(ImageAttachmentRoute.unsupported.appleMountType(forProbeKind: "apfs") == nil)
        #expect(ImageAttachmentRoute.unsupported.appleMountType(forProbeKind: "fat32") == nil)
    }

    @Test func aKindThatIsNotAnAppleFilesystemHasNoAppleMountType() {
        #expect(ImageAttachmentRoute.driverKit.appleMountType(forProbeKind: "ext4") == nil)
        #expect(ImageAttachmentRoute.hdiutil.appleMountType(forProbeKind: "ntfs") == nil)
        #expect(ImageAttachmentRoute.driverKit.appleMountType(forProbeKind: "") == nil)
    }

    // The inspector offers mount controls for every container that has an
    // attachment route, qcow2 and VHDX included, and the unsupported notice
    // only for a container it cannot attach.
    @Test func theInspectorOffersMountControlsForQcow2AndVhdxLikeTheOtherImages() {
        for container in ["raw", "vhd", "vmdk", "qcow2", "vhdx"] {
            #expect(DiskImageInspectorMountState(container: container, hasPartitionTable: true)
                    == .mountControls, "\(container)")
        }
    }

    @Test func theInspectorShowsTheUnsupportedNoticeOnlyForAnUnattachableImage() {
        #expect(DiskImageInspectorMountState(container: "dmg", hasPartitionTable: true)
                == .unsupportedContainer)
        #expect(DiskImageInspectorMountState(container: "", hasPartitionTable: false)
                == .unsupportedContainer)
    }

    // The DriverKit route mounts the partitions its media presents; a bare
    // filesystem in a qcow2 or VHDX image presents none, so the inspector
    // says so instead of offering a mount that would attach and find nothing.
    // hdiutil mounts a bare filesystem's whole disk, so those keep the controls.
    @Test func aDriverKitImageWithoutAPartitionTableIsNotOfferedAMount() {
        #expect(DiskImageInspectorMountState(container: "qcow2", hasPartitionTable: false)
                == .wholeDiskUnsupported)
        #expect(DiskImageInspectorMountState(container: "vhdx", hasPartitionTable: false)
                == .wholeDiskUnsupported)
        #expect(DiskImageInspectorMountState(container: "raw", hasPartitionTable: false)
                == .mountControls)
    }
}
