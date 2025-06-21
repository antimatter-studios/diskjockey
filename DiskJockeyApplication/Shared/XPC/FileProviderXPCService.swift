import Foundation
import DiskJockeyLibrary

class FileProviderXPCService: NSObject, FileProviderXPCProtocol {

    func handleRequest(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        // --- Begin generated code integration ---
        // import DiskJockeyLibrary // for FileProviderRequest/Response (SwiftProtobuf)
        // guard let request = try? FileProviderRequest(serializedData: data) else {
        //     reply(Data())
        //     return
        // }
        // switch request.requestType {
        // case .list(let listReq):
        //     let path = listReq.path
        //     let fileManager = FileManager.default
        //     let url = URL(fileURLWithPath: path)
        //     var fileInfos: [FileInfo] = []
        //     if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: []) {
        //         for fileURL in contents {
        //             let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        //             let info = FileInfo.with {
        //                 $0.name = fileURL.lastPathComponent
        //                 $0.isDirectory = resourceValues?.isDirectory ?? false
        //                 $0.size = Int64(resourceValues?.fileSize ?? 0)
        //                 $0.mtime = Int64(resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        //             }
        //             fileInfos.append(info)
        //         }
        //     }
        //     let listResp = ListResponse.with { $0.files = fileInfos }
        //     let response = FileProviderResponse.with { $0.list = listResp }
        //     let responseData = try? response.serializedData()
        //     reply(responseData ?? Data())
        // default:
        //     reply(Data())
        // }
        // --- End generated code integration ---
        // For now, reply with a stubbed directory listing
        struct StubFileInfo: Codable { let name: String; let isDirectory: Bool; let size: Int64; let mtime: Int64 }
        let stubFiles = [
            StubFileInfo(name: "test1.txt", isDirectory: false, size: 100, mtime: Int64(Date().timeIntervalSince1970)),
            StubFileInfo(name: "Documents", isDirectory: true, size: 0, mtime: Int64(Date().timeIntervalSince1970))
        ]
        let data = try? JSONEncoder().encode(stubFiles)
        reply(data ?? Data())
    }
}
