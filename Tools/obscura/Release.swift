// obscura release — the release Mac's half of G-33's signed update feed. Replaces Sparkle's generate_appcast.
//
//   obscura release keygen --key-item <name> [--backup-to <path>] [--dry-run]
//       Creates the Ed25519 update key ONCE, straight into a login-Keychain item, and prints its public half. The
//       maintainer's release step; --dry-run says what would happen and touches nothing. --backup-to writes the
//       private key (base64) to a NEW file at a path the maintainer names — meant for an encrypted backup volume —
//       created 0600, never overwriting. Why not a key file by default: the key's only home is the Keychain; a file
//       exists only where the maintainer explicitly puts one, for the backup G-33 asks for.
//   obscura release public-key --key-item <name>
//       Prints the public key for OBSCURA_UPDATE_PUBLIC_KEY (Apps/Obscura/Update.xcconfig / Signing.local.xcconfig).
//   obscura release feed --app <Obscura.app> --dmg <dmg> --url <https dmg url> [--notes-url <https>] --key-item <name> --out <file>
//       Reads bundle id, version, build and minimum macOS from the app that went into the disk image, computes the
//       disk image's size and SHA-256, signs the manifest with the Keychain key, verifies the result with the public
//       key, and writes the feed file.
//   obscura release verify --feed <file> --public-key <base64>
//       Checks a feed's signature offline and prints its manifest.
// The private key is never printed, logged or passed on a command line. The Keychain item may also be named by the
// OBSCURA_UPDATE_KEY_ITEM environment variable.
import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import ObscuraUpdate
import Security

struct Release: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build and sign Obscura's update feed (G-33). The private key lives only in the release Mac's Keychain.",
        subcommands: [Keygen.self, PublicKey.self, Feed.self, Verify.self])

    struct KeyItem: ParsableArguments {
        @Option(name: .customLong("key-item"), help: "The Keychain item holding the update key (or OBSCURA_UPDATE_KEY_ITEM).")
        var name: String?

        func resolved() throws -> String {
            if let name, !name.isEmpty { return name }
            if let env = ProcessInfo.processInfo.environment["OBSCURA_UPDATE_KEY_ITEM"], !env.isEmpty { return env }
            throw ValidationError("name the Keychain item with --key-item or OBSCURA_UPDATE_KEY_ITEM")
        }
    }

    // MARK: keygen

    struct Keygen: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create the update key in the Keychain (once; the maintainer's release step).")
        @OptionGroup var item: KeyItem
        @Option(name: .customLong("backup-to"), help: "Also write the private key (base64) to this NEW file, 0600 — e.g. on an encrypted backup volume.")
        var backup: String?
        @Flag(name: .customLong("dry-run"), help: "Say what would happen; create nothing.") var dryRun = false

        func run() throws {
            let name = try item.resolved()
            if let backup, FileManager.default.fileExists(atPath: backup) { throw ValidationError("\(backup) already exists; the backup is never overwritten") }
            if dryRun {
                // A dry run does not even read the Keychain.
                print("dry run: would refuse if the login Keychain already holds an item \"\(name)\" (account \(UpdateKeychain.account))")
                print("dry run: would create an Ed25519 key in that Keychain item")
                if let backup { print("dry run: would write the private key backup to \(backup) (new file, mode 0600)") }
                print("dry run: would print the public key for OBSCURA_UPDATE_PUBLIC_KEY; nothing was created or read")
                return
            }
            if UpdateKeychain.exists(name) { throw ValidationError("the Keychain item \"\(name)\" already exists; a second key would orphan every installed copy") }
            let key = Curve25519.Signing.PrivateKey()
            if let backup {
                let fd = open(backup, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0 else { throw ValidationError("could not create \(backup) (errno \(errno))") }
                let text = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
                let written = text.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                close(fd)
                guard written == text.count else { throw ValidationError("could not write the backup to \(backup)") }
            }
            try UpdateKeychain.store(key, name: name)
            print("created the update key in the Keychain item \"\(name)\"")
            if let backup { print("private key backup written to \(backup) (0600); keep it offline") }
            print("public key (OBSCURA_UPDATE_PUBLIC_KEY): \(key.publicKey.rawRepresentation.base64EncodedString())")
        }
    }

    // MARK: public-key

    struct PublicKey: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the update key's public half (base64).")
        @OptionGroup var item: KeyItem

        func run() throws {
            let key = try UpdateKeychain.load(try item.resolved())
            print(key.publicKey.rawRepresentation.base64EncodedString())
        }
    }

    // MARK: feed

    struct Feed: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write the signed update feed for one disk image.")
        @Option(help: "The Obscura.app that went into the disk image (its Info.plist names the version).") var app: String
        @Option(help: "The disk image.") var dmg: String
        @Option(help: "Where the disk image will be served (HTTPS, served without a redirect to another host).") var url: String
        @Option(name: .customLong("notes-url"), help: "Release notes (HTTPS).") var notesURL: String?
        @OptionGroup var item: KeyItem
        @Option(help: "Where to write the feed (e.g. obscura-update.json).") var out: String

        func run() throws {
            let info = URL(filePath: app).appending(path: "Contents/Info.plist")
            guard let data = try? Data(contentsOf: info),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let id = plist["CFBundleIdentifier"] as? String, let version = plist["CFBundleShortVersionString"] as? String,
                  let build = plist["CFBundleVersion"] as? String, let current = AppVersion(marketing: version, build: build)
            else { throw ValidationError("\(app) has no readable bundle id and version") }
            let minimum = plist["LSMinimumSystemVersion"] as? String ?? "15.0"
            guard let dmgURL = URL(string: url), dmgURL.scheme == "https", dmgURL.host() != nil else { throw ValidationError("--url must be https") }
            let notes = try notesURL.map { text -> URL in
                guard let u = URL(string: text), u.scheme == "https" else { throw ValidationError("--notes-url must be https") }
                return u
            }
            let digest = try FeedSigner.digest(of: URL(filePath: dmg))
            let manifest = UpdateManifest(bundleIdentifier: id, version: version, build: build, url: dmgURL, size: digest.size,
                                          sha256: digest.sha256, minimumSystemVersion: minimum, releaseNotesURL: notes)
            let key = try UpdateKeychain.load(try item.resolved())
            let feed = try FeedSigner.sign(manifest, with: key).encoded()
            // Round trip with the public half, as an installed copy one build older would see it.
            let older = AppVersion(marketing: current.marketingString, build: String(max(current.build - 1, 0)))!
            let verifier = FeedVerifier(trust: UpdateTrust(keys: [key.publicKey]), bundleIdentifier: id, current: older)
            let manifestBack = try verifier.verifiedManifest(feed: feed)
            guard manifestBack == manifest else { throw ValidationError("the signed feed did not read back identically") }
            try feed.write(to: URL(filePath: out), options: .atomic)
            print("wrote \(out): \(id) \(version) (\(build)), \(digest.size) bytes, sha256 \(digest.sha256), min macOS \(minimum)")
            print("public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
        }
    }

    // MARK: verify

    struct Verify: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check a feed's signature offline and print its manifest.")
        @Option(help: "The feed file.") var feed: String
        @Option(name: .customLong("public-key"), help: "The base64 public key.") var publicKey: String

        func run() throws {
            guard let trust = UpdateTrust(base64PublicKey: publicKey) else { throw ValidationError("--public-key is not a base64 32-byte Ed25519 key") }
            let data = try Data(contentsOf: URL(filePath: feed))
            let manifest: UpdateManifest
            do {
                // Any bundle id: the check here is the signature; print what the manifest says.
                let signed = try JSONDecoder().decode(SignedFeed.self, from: data)
                let bytes = Data(base64Encoded: signed.manifest) ?? Data()
                let id = (try? JSONDecoder().decode(UpdateManifest.self, from: bytes))?.bundleIdentifier ?? ""
                manifest = try FeedVerifier(trust: trust, bundleIdentifier: id, current: AppVersion(marketing: "0", build: "0")!)
                    .verifiedManifest(feed: data)
            } catch let error as UpdateError {
                print("FAILED: \(error.reason)")
                throw ExitCode(1)
            }
            print("signature verifies")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(manifest), as: UTF8.self))
        }
    }
}

/// The update key's one home: a generic-password item in the login Keychain, holding the raw 32-byte private key.
enum UpdateKeychain {
    static let account = "obscura-update-ed25519"

    static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: name, kSecAttrAccount as String: account]
    }

    static func exists(_ name: String) -> Bool {
        SecItemCopyMatching(query(name) as CFDictionary, nil) == errSecSuccess
    }

    static func store(_ key: Curve25519.Signing.PrivateKey, name: String) throws {
        var attributes = query(name)
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrLabel as String] = name
        attributes[kSecAttrDescription as String] = "Obscura update signing key (Ed25519)"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw ValidationError("the Keychain refused to store the key (OSStatus \(status))") }
    }

    static func load(_ name: String) throws -> Curve25519.Signing.PrivateKey {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw ValidationError("no update key in the Keychain item \"\(name)\" (OSStatus \(status))")
        }
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            throw ValidationError("the Keychain item \"\(name)\" does not hold a 32-byte Ed25519 key")
        }
        return key
    }
}
