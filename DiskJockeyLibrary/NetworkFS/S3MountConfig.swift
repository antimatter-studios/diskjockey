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
// driver uses SigV4 signed with all three. It is a credential too, so it
// is held in memory but never encoded: it lives in the shared keychain
// beside the secret key (see `MountCredentials`), and neither the
// per-domain plist nor the registry's UserDefaults blob carries it
// (diskjockey#172). Decoding still reads one left by an older build, so
// that `MountCredentials` can move it into the keychain rather than lose
// it — unlike the OAuth access token, nothing can refresh it.
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
    /// Optional STS session token for temporary credentials. In memory
    /// only; the keychain owns it on disk. See the file header.
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

    /// This config with `sessionToken` replaced — how `MountCredentials`
    /// puts the keychain's copy back after a load.
    public func withSessionToken(_ token: String) -> S3MountConfig {
        S3MountConfig(endpoint: endpoint, bucket: bucket, region: region,
                      accessKeyID: accessKeyID, prefix: prefix, secure: secure,
                      usePathStyle: usePathStyle, sessionToken: token)
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint, bucket, region, accessKeyID, prefix, secure, usePathStyle
        case sessionToken
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.endpoint = try c.decode(String.self, forKey: .endpoint)
        self.bucket = try c.decode(String.self, forKey: .bucket)
        self.region = try c.decode(String.self, forKey: .region)
        self.accessKeyID = try c.decode(String.self, forKey: .accessKeyID)
        self.prefix = try c.decode(String.self, forKey: .prefix)
        self.secure = try c.decode(Bool.self, forKey: .secure)
        self.usePathStyle = try c.decode(Bool.self, forKey: .usePathStyle)
        // Only an older build wrote this; see the file header.
        self.sessionToken = try c.decodeIfPresent(String.self, forKey: .sessionToken) ?? ""
    }

    /// Every field but `sessionToken`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(bucket, forKey: .bucket)
        try c.encode(region, forKey: .region)
        try c.encode(accessKeyID, forKey: .accessKeyID)
        try c.encode(prefix, forKey: .prefix)
        try c.encode(secure, forKey: .secure)
        try c.encode(usePathStyle, forKey: .usePathStyle)
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
