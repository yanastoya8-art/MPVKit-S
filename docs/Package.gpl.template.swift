// swift-tools-version:5.9

import Foundation
import PackageDescription
#if canImport(CryptoKit)
import CryptoKit
#endif

private let mpvkitPackageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .standardizedFileURL
    .resolvingSymlinksInPath()

private func mpvkitIsUnsymlinkedDirectory(_ url: URL) -> Bool {
    let standardized = url.standardizedFileURL
    guard standardized.resolvingSymlinksInPath() == standardized,
          let values = try? standardized.resourceValues(
              forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
          ) else {
        return false
    }
    return values.isDirectory == true && values.isSymbolicLink != true
}

private func mpvkitIsUnsymlinkedRegularFile(_ url: URL) -> Bool {
    let standardized = url.standardizedFileURL
    guard standardized.resolvingSymlinksInPath() == standardized,
          let values = try? standardized.resourceValues(
              forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
          ) else {
        return false
    }
    return values.isRegularFile == true && values.isSymbolicLink != true
}

private func mpvkitXCFrameworkSupportsActiveEclipseRuntimeMatrix(at artifact: URL) -> Bool {
    let infoPlist = artifact.appendingPathComponent("Info.plist", isDirectory: false)
    guard mpvkitIsUnsymlinkedDirectory(artifact),
          mpvkitIsUnsymlinkedRegularFile(infoPlist),
          let data = try? Data(contentsOf: infoPlist),
          let propertyList = try? PropertyListSerialization.propertyList(
              from: data,
              options: [],
              format: nil
          ),
          let dictionary = propertyList as? [String: Any],
          let libraries = dictionary["AvailableLibraries"] as? [[String: Any]] else {
        return false
    }

    func containsSlice(
        platform: String,
        variant: String? = nil,
        architectures requiredArchitectures: Set<String>
    ) -> Bool {
        libraries.contains { library in
            guard library["SupportedPlatform"] as? String == platform,
                  library["SupportedPlatformVariant"] as? String == variant,
                  let architectures = library["SupportedArchitectures"] as? [String] else {
                return false
            }
            return requiredArchitectures.isSubset(of: Set(architectures))
        }
    }

    // Eclipse's active private runtime matrix is iOS and tvOS (device and simulator), plus
    // macOS for MPVKit's local native harnesses. iPadOS shares the iOS slices. Catalyst and
    // visionOS remain declared package platforms, but are not active Eclipse release products.
    return containsSlice(platform: "ios", architectures: ["arm64"])
        && containsSlice(
            platform: "ios",
            variant: "simulator",
            architectures: ["arm64", "x86_64"]
        )
        && containsSlice(platform: "macos", architectures: ["arm64", "x86_64"])
        && containsSlice(platform: "tvos", architectures: ["arm64"])
        && containsSlice(
            platform: "tvos",
            variant: "simulator",
            architectures: ["arm64", "x86_64"]
        )
}

private func mpvkitCompleteLocalRuntimeArtifacts(at root: URL) -> [String: URL]? {
    let searchRoots = [root, root.appendingPathComponent("xcframework", isDirectory: true)]
    let requiredArtifacts = [
        "Libmpv", "MoltenVK", "Libplacebo", "Libavcodec", "Libavdevice", "Libavfilter",
        "Libavformat", "Libavutil", "Libswresample", "Libswscale",
    ]
    var validated: [String: URL] = [:]
    for artifactName in requiredArtifacts {
        let candidates = searchRoots.compactMap { searchRoot -> URL? in
            let artifact = searchRoot.appendingPathComponent(
                "\(artifactName).xcframework",
                isDirectory: true
            ).standardizedFileURL
            guard mpvkitXCFrameworkSupportsActiveEclipseRuntimeMatrix(at: artifact) else {
                return nil
            }
            return artifact
        }
        guard candidates.count == 1, let artifact = candidates.first else { return nil }
        validated[artifactName] = artifact
    }
    return validated
}

private let mpvkitLocalArtifactsRoot: URL? = {
    if let value = ProcessInfo.processInfo.environment["MPVKIT_LOCAL_ARTIFACTS_DIR"],
       !value.isEmpty {
        let requested = URL(fileURLWithPath: value, relativeTo: mpvkitPackageRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let packagePath = mpvkitPackageRoot.path + "/"
        guard requested.path == mpvkitPackageRoot.path
                || requested.path.hasPrefix(packagePath) else {
            fatalError("MPVKIT_LOCAL_ARTIFACTS_DIR must resolve inside the MPVKit checkout")
        }
        guard mpvkitCompleteLocalRuntimeArtifacts(at: requested) != nil else {
            fatalError(
                "MPVKIT_LOCAL_ARTIFACTS_DIR must contain the complete unpacked active Eclipse runtime"
            )
        }
        return requested
    }

    // On a fresh manifest evaluation, automatically select a complete locally rebuilt runtime so
    // ordinary Xcode builds can use branch-specific libmpv/MoltenVK patches. Inspect every
    // unpacked XCFramework's slice matrix so a one-platform rebuild is never newly selected for a
    // different Apple target. SwiftPM's shared manifest cache does not watch artifact contents, so
    // deterministic build/archive workflows must still set MPVKIT_LOCAL_ARTIFACTS_DIR explicitly.
    let bundledCandidates = [
        mpvkitPackageRoot.appendingPathComponent("dist/release", isDirectory: true),
        mpvkitPackageRoot,
    ].map(\.standardizedFileURL)
    return bundledCandidates.first { mpvkitCompleteLocalRuntimeArtifacts(at: $0) != nil }
}()

private let mpvkitValidatedLocalArtifacts: [String: URL] = {
    guard let root = mpvkitLocalArtifactsRoot else { return [:] }
    return mpvkitCompleteLocalRuntimeArtifacts(at: root) ?? [:]
}()

private func mpvkitSHA256(of file: URL) -> String? {
    guard mpvkitIsUnsymlinkedRegularFile(file) else { return nil }
    #if canImport(CryptoKit)
    guard let data = try? Data(contentsOf: file) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #else
    return nil
    #endif
}

private func mpvkitMoltenVKProvenanceMatchesSelectedArtifact(
    root: URL,
    artifact: URL
) -> Bool {
    let marker = root.appendingPathComponent(
        "MoltenVK.imported-mtltexture-residency-fix",
        isDirectory: false
    ).standardizedFileURL
    guard mpvkitIsUnsymlinkedRegularFile(marker),
          artifact.path.hasPrefix(root.path + "/"),
          let markerData = try? Data(contentsOf: marker),
          let object = try? JSONSerialization.jsonObject(with: markerData),
          let provenance = object as? [String: Any],
          provenance["schema"] as? Int == 1,
          provenance["feature"] as? String == "imported-mtltexture-residency-fix",
          provenance["artifact"] as? String
              == String(artifact.path.dropFirst(root.path.count + 1)),
          let base = provenance["base"] as? [String: Any],
          base["repository"] as? String == "https://github.com/KhronosGroup/MoltenVK",
          base["tag"] as? String == "v1.4.1",
          base["commit"] as? String == "db445ff2042d9ce348c439ad8451112f354b8d2a",
          let backport = provenance["backport"] as? [String: Any],
          backport["source_commit"] as? String
              == "a17d4d53359d8c029406cbe2c50d9a0089964035",
          backport["merge_commit"] as? String
              == "32dceb35e2c95b46cec501033cbc3a1ddf32d6e8",
          backport["patch_sha256"] as? String
              == "d0d37d938d466f0a5504368ad0df83143150e303af014ded7af8947bf8136ee2",
          let build = provenance["build"] as? [String: Any],
          let recordedMatrix = build["platform_slices"] as? [String: [String]],
          let integrity = provenance["integrity"] as? [String: Any],
          let recordedSliceHashes = integrity["slice_sha256"] as? [String: String],
          let recordedInfoHash = integrity["info_plist_sha256"] as? String else {
        return false
    }

    let infoPlist = artifact.appendingPathComponent("Info.plist", isDirectory: false)
    guard mpvkitSHA256(of: infoPlist) == recordedInfoHash,
          let infoData = try? Data(contentsOf: infoPlist),
          let propertyList = try? PropertyListSerialization.propertyList(
              from: infoData,
              options: [],
              format: nil
          ),
          let dictionary = propertyList as? [String: Any],
          let libraries = dictionary["AvailableLibraries"] as? [[String: Any]] else {
        return false
    }

    let requiredIdentifiers: Set<String> = [
        "ios-arm64",
        "ios-arm64_x86_64-simulator",
    ]
    var actualHashes: [String: String] = [:]
    var actualMatrix: [String: Set<String>] = [:]
    for library in libraries {
        guard let identifier = library["LibraryIdentifier"] as? String,
              requiredIdentifiers.contains(identifier),
              actualHashes[identifier] == nil,
              let architectures = library["SupportedArchitectures"] as? [String],
              let binaryPath = (library["BinaryPath"] ?? library["LibraryPath"]) as? String else {
            continue
        }
        let binary = artifact
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent(binaryPath, isDirectory: false)
            .standardizedFileURL
        guard binary.path.hasPrefix(artifact.path + "/"),
              let hash = mpvkitSHA256(of: binary) else {
            return false
        }
        actualHashes[identifier] = hash
        actualMatrix[identifier] = Set(architectures)
    }

    guard Set(actualHashes.keys) == requiredIdentifiers,
          Set(recordedSliceHashes.keys) == requiredIdentifiers,
          Set(recordedMatrix.keys) == requiredIdentifiers else {
        return false
    }
    return requiredIdentifiers.allSatisfy { identifier in
        actualHashes[identifier] == recordedSliceHashes[identifier]
            && actualMatrix[identifier] == Set(recordedMatrix[identifier] ?? [])
    }
}

private let mpvkitLocalMoltenVKHasImportedTextureResidencyFix: Bool = {
    guard let root = mpvkitLocalArtifactsRoot,
          let artifact = mpvkitValidatedLocalArtifacts["MoltenVK"] else {
        return false
    }
    return mpvkitMoltenVKProvenanceMatchesSelectedArtifact(root: root, artifact: artifact)
}()

private let mpvkitSampleBufferSwiftSettings: [SwiftSetting] =
    mpvkitLocalMoltenVKHasImportedTextureResidencyFix
        ? [.define("MPVKIT_MOLTENVK_IMPORTED_TEXTURE_RESIDENCY_FIX")]
        : []

private func mpvkitBinaryTarget(
    name: String,
    url: String,
    checksum: String
) -> Target {
    let artifactName = name.hasSuffix("-GPL")
        ? String(name.dropLast("-GPL".count))
        : name
    if let artifact = mpvkitValidatedLocalArtifacts[artifactName] {
        let relativePath = String(artifact.path.dropFirst(mpvkitPackageRoot.path.count + 1))
        return .binaryTarget(name: name, path: relativePath)
    }
    return .binaryTarget(name: name, url: url, checksum: checksum)
}

private let mpvkitNativeRuntimeHarnessTargets: [Target] = []

let package = Package(
    name: "MPVKit",
    platforms: [.iOS(.v14)],
    products: [
        .library(
            name: "MPVKit-GPL",
            targets: ["_MPVKit-GPL", "MPVKitSampleBufferGPL"]
        ),
        .library(
            name: "MPVKitSampleBuffer-GPL",
            targets: ["MPVKitSampleBufferGPL"]
        ),
    ],
    targets: [
        .target(
            name: "MPVKitSampleBufferGPL",
            dependencies: ["MPVKitSampleBufferCore", "_MPVKit-GPL", "Libmpv-GPL", "_FFmpeg-GPL", "Libuchardet", "Libbluray"],
            path: "Sources/MPVKitSampleBufferGPL",
            swiftSettings: mpvkitSampleBufferSwiftSettings,
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
            ]
        ),
        .target(
            name: "MPVKitSampleBufferCore",
            path: "Sources/MPVKitSampleBufferCore"
        ),
    ] + mpvkitNativeRuntimeHarnessTargets + [
        .target(
            name: "_MPVKit-GPL",
            dependencies: [
                "Libmpv-GPL", "_FFmpeg-GPL", "Libuchardet", "Libbluray",
                .target(name: "Libluajit", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/_MPVKit-GPL",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .target(
            name: "_FFmpeg-GPL",
            dependencies: [
                "Libavcodec-GPL", "Libavdevice-GPL", "Libavfilter-GPL", "Libavformat-GPL", "Libavutil-GPL", "Libswresample-GPL", "Libswscale-GPL",
                "Libssl", "Libcrypto", "Libass", "Libfreetype", "Libfribidi", "Libharfbuzz",
                "MoltenVK", "Libshaderc_combined", "lcms2", "Libplacebo", "Libdovi", "Libunibreak",
                "Libsmbclient", "gmp", "nettle", "hogweed", "gnutls", "Libdav1d", "Libuavs3d"
            ],
            path: "Sources/_FFmpeg-GPL",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("expat"),
                .linkedLibrary("resolv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
        //AUTO_GENERATE_TARGETS_BEGIN//
        //AUTO_GENERATE_TARGETS_END//
    ]
)
