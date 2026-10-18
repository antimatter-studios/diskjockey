//
//  ImageAttachmentRouteTests.swift — which attachment route each disk-image
//  container takes on its way to a block device (diskjockey#478).
//
//  hdiutil turns raw, VHD and VMDK images into block devices; it does not
//  read qcow2 or VHDX, which go to the DriverKit virtual disk instead. An
//  unrecognised container has no route and must be refused, not guessed.
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

    @Test func onlyTheHdiutilRouteReachesAppleFilesystemsToday() {
        #expect(ImageAttachmentRoute.hdiutil.reachesAppleFilesystems)
        #expect(!ImageAttachmentRoute.driverKit.reachesAppleFilesystems)
        #expect(!ImageAttachmentRoute.unsupported.reachesAppleFilesystems)
    }
}
