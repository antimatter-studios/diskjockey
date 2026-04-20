//
// S3MountConfig.swift — personality for the S3-compatible driver.
//
// The Go driver (vendor/go-networkfs/s3/s3.go) speaks to AWS S3 and
// every S3-compatible backend: MinIO, Cloudflare R2, Backblaze B2 (S3
// mode), Wasabi, etc. Connection parameters differ meaningfully across
// these, so we surface the full set as first-class fields rather than
// pretending S3 has a uniform "endpoint + bucket" shape.
//
// Secret storage: `secret_access_key` is the sensitive half and goes in
// the shared keychain as `password`. `access_key_id` is treated as
// non-sensitive (it's an identifier, not a credential) and lives in the
// plist. This matches how the AWS CLI splits `~/.aws/credentials` from
// `~/.aws/config` for everything except the secret key.
//
// `sessionToken` is for STS / IAM-role scenarios: when set, the Go
// driver uses SigV4 signed with all three. It's sensitive too, but
// short-lived — callers that need it are expected to rotate the whole
// mount (keychain password + this field) together.
//

import Foundation

public struct S3MountConfig: NetworkFSPersonality {
    public static let scheme: DirectMountScheme = .s3

    /// host[:port] of the S3 service. No scheme — use `secure` for that.
    /// Examples: `s3.amazonaws.com`, `minio.local:9000`,
    /// `<account>.r2.cloudflarestorage.com`.
    public let endpoint: String
    public let bucket: String
    public let region: String
    public let accessKeyID: String
    /// Optional key prefix treated as the filesystem root inside the
    /// bucket. Empty = whole-bucket mount.
    public let prefix: String
    /// HTTPS vs plain HTTP. Default true.
    public let secure: Bool
    /// Force path-style addressing. Needed for MinIO and most
    /// self-hosted S3 endpoints; leave false for AWS and modern R2.
    public let usePathStyle: Bool
    /// Optional STS session token for temporary credentials. Stored in
    /// the plist; see file header for the rationale.
    public let sessionToken: String

    public init(
        endpoint: String,
        bucket: String,
        region: String = "us-east-1",
        accessKeyID: String,
        prefix: String = "",
        secure: Bool = true,
        usePathStyle: Bool = false,
        sessionToken: String = ""
    ) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.accessKeyID = accessKeyID
        self.prefix = prefix
        self.secure = secure
        self.usePathStyle = usePathStyle
        self.sessionToken = sessionToken
    }

    public func mountJSON(password: String) -> String {
        // `password` carries the `secret_access_key` from MountKeychain.
        var dict: [String: String] = [
            "endpoint":          endpoint,
            "bucket":            bucket,
            "region":            region,
            "access_key_id":     accessKeyID,
            "secret_access_key": password,
            "secure":            secure ? "true" : "false",
            "use_path_style":    usePathStyle ? "true" : "false",
        ]
        if !prefix.isEmpty {
            dict["prefix"] = prefix
        }
        if !sessionToken.isEmpty {
            dict["session_token"] = sessionToken
        }
        return encodeMountDict(dict)
    }
}
