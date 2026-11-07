import Foundation
import Photos
import Synchronization
import UniformTypeIdentifiers

/// The System Photo Library through PhotoKit (LIB-54), only ever read (DEC-106): its albums, folders, smart
/// and shared albums, their assets with their fields and files, each file written by
/// `PHAssetResourceManager`, downloaded from iCloud where it's only there, and Photos' changes as
/// `PHPhotoLibraryChangeObserver` hears of them. Its images at a size are the app's (`PhotoKitImages`, LIB-59):
/// `PHImageManager` gives them as `NSImage`, which the library's package doesn't use.
public final class PhotoKitLibrary: ApplePhotosLibrary {
    public init() {}

    public var fields: Set<ApplePhotosField> {
        var fields = Set(ApplePhotosField.everywhere)
        if #available(macOS 27, iOS 27, *), Self.hasMacOS27Fields {
            fields.formUnion(ApplePhotosField.fromMacOS27)
        }
        return fields
    }

    // MARK: - Access

    public func access() -> ApplePhotosAccess {
        Self.access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAccess() async -> ApplePhotosAccess {
        await Self.access(PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    static func access(_ status: PHAuthorizationStatus) -> ApplePhotosAccess {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .limited: .limited
        case .authorized: .authorized
        @unknown default: .denied
        }
    }

    private func requireAccess() throws {
        let access = access()
        guard access.canRead else { throw ApplePhotosError.noAccess(access) }
    }

    // MARK: - Collections

    public func collections() async throws -> [ApplePhotosCollection] {
        try requireAccess()
        if access() == .limited {
            var chosen = ApplePhotosCollection.chosenForRedlamp
            chosen.estimatedCount = PHAsset.fetchAssets(with: nil).count
            return [chosen]
        }
        var found: [ApplePhotosCollection] = []
        func walk(_ result: PHFetchResult<PHCollection>, parent: String?) {
            result.enumerateObjects { collection, _, _ in
                if let list = collection as? PHCollectionList {
                    found.append(ApplePhotosCollection(
                        id: list.localIdentifier, title: list.localizedTitle ?? "", kind: .folder, parent: parent,
                    ))
                    walk(PHCollection.fetchCollections(in: list, options: nil), parent: list.localIdentifier)
                } else if let album = collection as? PHAssetCollection, Self.isListed(album) {
                    found.append(Self.collection(album, parent: parent))
                }
            }
        }
        walk(PHCollectionList.fetchTopLevelUserCollections(with: nil), parent: nil)
        var listed = Set(found.map(\.id))
        for (type, subtype) in [
            (PHAssetCollectionType.smartAlbum, PHAssetCollectionSubtype.any),
            (.album, .albumCloudShared),
        ] {
            PHAssetCollection.fetchAssetCollections(with: type, subtype: subtype, options: nil)
                .enumerateObjects { album, _, _ in
                    if Self.isListed(album), listed.insert(album.localIdentifier).inserted {
                        found.append(Self.collection(album, parent: nil))
                    }
                }
        }
        return found
    }

    /// Hidden photos come with an option, not as an album; Recently Deleted is never listed.
    private static func isListed(_ album: PHAssetCollection) -> Bool {
        album.assetCollectionSubtype != .smartAlbumAllHidden
    }

    private static func collection(_ album: PHAssetCollection, parent: String?) -> ApplePhotosCollection {
        let kind: ApplePhotosCollection.Kind = switch album.assetCollectionType {
        case .smartAlbum: .smartAlbum
        case .album where album.assetCollectionSubtype == .albumCloudShared: .sharedAlbum
        default: .album
        }
        let count = album.estimatedAssetCount
        return ApplePhotosCollection(
            id: album.localIdentifier, title: album.localizedTitle ?? "", kind: kind, parent: parent,
            estimatedCount: count == NSNotFound ? nil : count,
        )
    }

    // MARK: - Assets

    public func assets(in ids: [String]) async throws -> [ApplePhotosAsset] {
        try requireAccess()
        var found: [String: PHAsset] = [:]
        var order: [String] = []
        var albumsOf: [String: [String]] = [:]
        for (album, assets) in fetches(ids, Self.fetchOptions(allBursts: false)) {
            assets.enumerateObjects { asset, _, _ in
                let id = asset.localIdentifier
                if found.updateValue(asset, forKey: id) == nil {
                    order.append(id)
                }
                albumsOf[id, default: []].append(album)
            }
        }
        for id in order {
            guard let key = found[id], key.representsBurst, let burst = key.burstIdentifier else { continue }
            PHAsset.fetchAssets(withBurstIdentifier: burst, options: Self.fetchOptions(allBursts: true))
                .enumerateObjects { frame, _, _ in
                    let frameID = frame.localIdentifier
                    guard found[frameID] == nil else { return }
                    found[frameID] = frame
                    order.append(frameID)
                    albumsOf[frameID] = albumsOf[id]
                }
        }
        let clouds = cloudIdentifiers(order)
        return order.compactMap { id in
            found[id].map { Self.asset($0, cloud: clouds[id], albums: albumsOf[id] ?? []) }
        }
    }

    /// The assets of each collection `ids` names, as `options` fetches them, by the collection's ID: with limited
    /// access, the stand-in's are every asset Photos lets Redlamp read, to which limited access restricts a fetch.
    private func fetches(_ ids: [String], _ options: PHFetchOptions) -> [(String, PHFetchResult<PHAsset>)] {
        let chosen = ApplePhotosCollection.chosenForRedlamp.id
        var fetches: [(String, PHFetchResult<PHAsset>)] = []
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids.filter { $0 != chosen }, options: nil)
            .enumerateObjects { album, _, _ in
                fetches.append((album.localIdentifier, PHAsset.fetchAssets(in: album, options: options)))
            }
        if ids.contains(chosen), access() == .limited {
            fetches.append((chosen, PHAsset.fetchAssets(with: options)))
        }
        return fetches
    }

    private static func fetchOptions(allBursts: Bool) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = allBursts
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        #if compiler(>=6.4)
            if #available(macOS 27, iOS 27, *) {
                options.prefetchAssetExtendedMetadata = true
            }
        #endif
        return options
    }

    /// The assets' cloud identifiers, by local identifier, for those that have one.
    private func cloudIdentifiers(_ ids: [String]) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        var clouds: [String: String] = [:]
        for (id, result) in PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: ids) {
            if case let .success(cloud) = result {
                clouds[id] = Self.archivalString(of: cloud)
            }
        }
        return clouds
    }

    /// The identifier as Photos archives it (`archivalStringValue`, macOS 15.2), which may hold more than
    /// `stringValue`, deprecated in macOS 27, and reads back where a `stringValue` would. The macOS 26 SDK
    /// doesn't declare it, though every macOS Redlamp runs on has it.
    static func archivalString(of cloud: PHCloudIdentifier) -> String {
        #if compiler(>=6.4)
            cloud.archivalStringValue
        #else
            undeclared("archivalStringValue", of: cloud) ?? cloud.stringValue
        #endif
    }

    /// When the asset was last edited or reverted (`adjustmentTimestamp`, macOS 15), which the macOS 26 SDK doesn't
    /// declare either.
    static func adjusted(_ asset: PHAsset) -> Date? {
        #if compiler(>=6.4)
            asset.adjustmentTimestamp
        #else
            undeclared("adjustmentTimestamp", of: asset)
        #endif
    }

    /// A property Apple documents for every macOS Redlamp runs on that the macOS 26 SDK doesn't declare, read by its
    /// name; nil where the object hasn't it.
    private static func undeclared<Value>(_ key: String, of object: NSObject) -> Value? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? Value
    }

    private static func asset(_ asset: PHAsset, cloud: String?, albums: [String]) -> ApplePhotosAsset {
        let mediaType: ApplePhotosAsset.MediaType = switch asset.mediaType {
        case .image: .image
        case .video: .video
        case .audio: .audio
        default: .unknown
        }
        var subtypes = Set<ApplePhotosAsset.Subtype>()
        for (subtype, mine) in [
            (PHAssetMediaSubtype.photoLive, ApplePhotosAsset.Subtype.live), (.photoHDR, .hdr),
            (.photoPanorama, .panorama), (.photoDepthEffect, .depthEffect), (.photoScreenshot, .screenshot),
            (.spatialMedia, .spatial),
        ] where asset.mediaSubtypes.contains(subtype) {
            subtypes.insert(mine)
        }
        let source: ApplePhotosAsset.Source = switch asset.sourceType {
        case .typeCloudShared: .cloudShared
        case .typeiTunesSynced: .synced
        default: .library
        }
        var found = ApplePhotosAsset(
            id: asset.localIdentifier, cloud: cloud, created: asset.creationDate,
            location: asset.location.map {
                ApplePhotosAsset.Location(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            },
            isFavorite: asset.isFavorite, isHidden: asset.isHidden, mediaType: mediaType, subtypes: subtypes,
            burst: asset.burstIdentifier.map { burst in
                ApplePhotosAsset.Burst(
                    id: burst, isKey: asset.representsBurst, isUserPick: asset.burstSelectionTypes.contains(.userPick),
                )
            },
            source: source, hasAdjustments: asset.hasAdjustments, adjusted: adjusted(asset),
            modified: asset.modificationDate, albums: albums,
            resources: PHAssetResource.assetResources(for: asset).map(resource),
        )
        if #available(macOS 27, iOS 27, *) {
            readMacOS27Fields(of: asset, into: &found)
        }
        return found
    }

    /// Whether this build's SDK has PhotoKit's macOS 27 fields.
    private static var hasMacOS27Fields: Bool {
        #if compiler(>=6.4)
            true
        #else
            false
        #endif
    }

    /// The rating, caption and keywords macOS 27 gives (`PHAsset.rating`, `PHAsset.extendedMetadata`).
    @available(macOS 27, iOS 27, *)
    private static func readMacOS27Fields(of asset: PHAsset, into found: inout ApplePhotosAsset) {
        // Built only with an SDK that has them: Xcode 26's (macOS 26.5) doesn't.
        #if compiler(>=6.4)
            found.rating = switch asset.rating {
            case .one: 1
            case .two: 2
            case .three: 3
            case .four: 4
            case .five: 5
            default: 0
            }
            let metadata = asset.extendedMetadata
            found.caption = metadata.caption
            found.keywords = Array(metadata.keywords)
        #endif
    }

    private static func resource(_ resource: PHAssetResource) -> ApplePhotosResource {
        let kind: ApplePhotosResource.Kind = switch resource.type {
        case .photo: .photo
        case .alternatePhoto: .alternatePhoto
        case .fullSizePhoto: .fullSizePhoto
        case .pairedVideo: .pairedVideo
        default: .other
        }
        return ApplePhotosResource(
            kind: kind, type: resource.contentType.identifier, originalFilename: resource.originalFilename,
            pixelWidth: resource.pixelWidth > 0 ? resource.pixelWidth : nil,
            pixelHeight: resource.pixelHeight > 0 ? resource.pixelHeight : nil,
        )
    }

    // MARK: - Files

    /// Written through `requestData`, chunk by chunk, so Stop cancels a download from iCloud:
    /// `writeData(for:toFile:options:)` gives nothing to cancel it by.
    public func write(
        _ resource: ApplePhotosResource, of asset: String, to url: URL,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws {
        try requireAccess()
        guard let found = PHAsset.fetchAssets(
            withLocalIdentifiers: [asset],
            options: Self.fetchOptions(allBursts: true),
        )
        .firstObject
        else { throw ApplePhotosError.notFound(asset) }
        let resources = PHAssetResource.assetResources(for: found)
        guard let source = resources.first(where: {
            Self.resource($0).kind == resource.kind && $0.originalFilename == resource.originalFilename
        }) ?? resources.first(where: { Self.resource($0).kind == resource.kind })
        else { throw ApplePhotosError.unavailable(resource.originalFilename, "Photos has no such file for it") }
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction in progress(fraction) }
        let failure = Mutex<(any Error)?>(nil)
        let request = Mutex<PHAssetResourceDataRequestID?>(nil)
        let cancelled = Cancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let id = PHAssetResourceManager.default().requestData(for: source, options: options) { data in
                    do {
                        try handle.write(contentsOf: data)
                    } catch {
                        failure.withLock { $0 = $0 ?? error }
                    }
                } completionHandler: { error in
                    try? handle.close()
                    if let error = error ?? failure.withLock({ $0 }) {
                        continuation.resume(throwing: cancelled.isSet
                            ? CancellationError()
                            : Self.isOffline(error) ? ApplePhotosError.offline(resource.originalFilename) : error)
                    } else {
                        continuation.resume()
                    }
                }
                request.withLock { $0 = id }
                if cancelled.isSet {
                    PHAssetResourceManager.default().cancelDataRequest(id)
                }
            }
        } onCancel: {
            cancelled.set()
            if let id = request.withLock({ $0 }) {
                PHAssetResourceManager.default().cancelDataRequest(id)
            }
        }
    }

    /// Whether `error`, or an error under it, says the network can't reach iCloud. Photos' own errors for it aren't
    /// documented, so this reads the URL loading system's (unverified until the census).
    static func isOffline(_ error: any Error) -> Bool {
        let offline: Set<Int> = [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorTimedOut, NSURLErrorDataNotAllowed,
            NSURLErrorInternationalRoamingOff,
        ]
        var errors = [error as NSError]
        while let next = errors.popLast() {
            if next.domain == NSURLErrorDomain, offline.contains(next.code) {
                return true
            }
            if let under = next.userInfo[NSUnderlyingErrorKey] as? NSError {
                errors.append(under)
            }
            errors += next.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] ?? []
        }
        return false
    }

    public func assets(withIDs ids: [String]) async throws -> [ApplePhotosAsset] {
        try await assets(withIDs: ids, in: [])
    }

    /// Each album is asked only for the assets `ids` names, every frame of a burst included.
    public func assets(withIDs ids: [String], in albums: [String]) async throws -> [ApplePhotosAsset] {
        try requireAccess()
        guard !ids.isEmpty else { return [] }
        var found: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: Self.fetchOptions(allBursts: true))
            .enumerateObjects { asset, _, _ in found.append(asset) }
        var holding: [String: [String]] = [:]
        if !albums.isEmpty, !found.isEmpty {
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            options.includeAllBurstAssets = true
            options.predicate = NSPredicate(format: "localIdentifier IN %@", found.map(\.localIdentifier))
            for (album, assets) in fetches(albums, options) {
                assets.enumerateObjects { asset, _, _ in
                    holding[asset.localIdentifier, default: []].append(album)
                }
            }
        }
        let clouds = cloudIdentifiers(found.map(\.localIdentifier))
        return found.map {
            Self.asset($0, cloud: clouds[$0.localIdentifier], albums: holding[$0.localIdentifier] ?? [])
        }
    }

    /// The identifiers recorded are fetched first, reading nothing but them; only those Photos doesn't have are read
    /// back and mapped.
    public func localIDs(ofCopies copies: [String: String]) async throws -> [String: String] {
        try requireAccess()
        guard !copies.isEmpty else { return [:] }
        var found: [String: String] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: Array(copies.keys), options: Self.fetchOptions(allBursts: true))
            .enumerateObjects { asset, _, _ in found[asset.localIdentifier] = asset.localIdentifier }
        var recorded: [(cloud: PHCloudIdentifier, local: String)] = []
        for (local, text) in copies where found[local] == nil && !text.isEmpty {
            if let cloud = Self.cloudIdentifier(text) {
                recorded.append((cloud, local))
            }
        }
        guard !recorded.isEmpty else { return found }
        let mappings = PHPhotoLibrary.shared().localIdentifierMappings(for: recorded.map(\.cloud))
        for (cloud, local) in recorded {
            if case let .success(id) = mappings[cloud] {
                found[local] = id
            }
        }
        return found
    }

    /// A cloud identifier as it was recorded, read back. `init(archivalStringValue:)` reads `stringValue`'s text too;
    /// the macOS 26 SDK declares only `init(stringValue:)`, which reads what 0.3.4 recorded.
    static func cloudIdentifier(_ text: String) -> PHCloudIdentifier? {
        #if compiler(>=6.4)
            PHCloudIdentifier(archivalStringValue: text)
        #else
            PHCloudIdentifier(stringValue: text)
        #endif
    }

    /// Photos is asked for each album's photos that aren't hidden, and for the frames picked of each burst in it,
    /// reading nothing but their identifiers.
    public func listedIDs(in ids: [String]) async throws -> [String: Set<String>] {
        try requireAccess()
        guard !ids.isEmpty else { return [:] }
        let photos = PHFetchOptions()
        photos.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let frames = PHFetchOptions()
        frames.includeAllBurstAssets = true
        var listed: [String: Set<String>] = [:]
        for (album, assets) in fetches(ids, photos) {
            var held = Set<String>()
            assets.enumerateObjects { asset, _, _ in
                held.insert(asset.localIdentifier)
                guard asset.representsBurst, let burst = asset.burstIdentifier else { return }
                PHAsset.fetchAssets(withBurstIdentifier: burst, options: frames).enumerateObjects { frame, _, _ in
                    if frame.burstSelectionTypes.contains(.userPick), !frame.isHidden {
                        held.insert(frame.localIdentifier)
                    }
                }
            }
            listed[album] = held
        }
        return listed
    }

    // MARK: - Changes

    public func changeToken() -> Data? {
        guard access().canRead else { return nil }
        return try? NSKeyedArchiver.archivedData(
            withRootObject: PHPhotoLibrary.shared().currentChangeToken, requiringSecureCoding: true,
        )
    }

    public func changes(since token: Data) async throws -> ApplePhotosChanges {
        try requireAccess()
        guard let since = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: token)
        else { throw ApplePhotosError.expiredToken }
        let result: PHPersistentChangeFetchResult
        do {
            result = try PHPhotoLibrary.shared().fetchPersistentChanges(since: since)
        } catch let error as PHPhotosError
            where [.persistentChangeTokenExpired, .persistentChangeDetailsUnavailable].contains(error.code) {
            throw ApplePhotosError.expiredToken
        }
        var changes = ApplePhotosChanges(token: token)
        var last: PHPersistentChangeToken?
        for change in result {
            do {
                let assets = try change.changeDetails(for: .asset)
                changes.inserted.formUnion(assets.insertedLocalIdentifiers)
                changes.updated.formUnion(assets.updatedLocalIdentifiers)
                changes.deleted.formUnion(assets.deletedLocalIdentifiers)
                for type in [PHObjectType.assetCollection, .collectionList] {
                    let collections = try change.changeDetails(for: type)
                    changes.collections.formUnion(collections.insertedLocalIdentifiers)
                    changes.collections.formUnion(collections.updatedLocalIdentifiers)
                    changes.collections.formUnion(collections.deletedLocalIdentifiers)
                }
            } catch {
                throw ApplePhotosError.expiredToken
            }
            last = change.changeToken
        }
        changes.inserted.subtract(changes.deleted)
        changes.updated.subtract(changes.deleted.union(changes.inserted))
        if access() == .limited {
            // How Photos tells of other photos being chosen for Redlamp isn't documented (unverified until the
            // census), so the stand-in's photos are compared after every change.
            changes.collections.insert(ApplePhotosCollection.chosenForRedlamp.id)
        }
        if let last, let archived = try? NSKeyedArchiver.archivedData(
            withRootObject: last,
            requiringSecureCoding: true,
        ) {
            changes.token = archived
        }
        return changes
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observer = ChangeObserver(continuation)
        PHPhotoLibrary.shared().register(observer)
        continuation.onTermination = { _ in PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        return stream
    }

    private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
        let continuation: AsyncStream<Void>.Continuation

        init(_ continuation: AsyncStream<Void>.Continuation) {
            self.continuation = continuation
        }

        func photoLibraryDidChange(_: PHChange) {
            continuation.yield()
        }
    }
}
