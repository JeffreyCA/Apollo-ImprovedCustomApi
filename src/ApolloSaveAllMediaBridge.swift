import Foundation

// MediaPageViewController.foundURLs is [URL]?, not an Objective-C NSArray.
// Read through Swift so bridging and ownership stay with the runtime. The
// caller validates the ivar's type/size and consumes this retained NSArray.
@_cdecl("ApolloSaveAllMediaCopyURLs")
public func ApolloSaveAllMediaCopyURLs(_ storage: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard let storage,
          let urls = storage.assumingMemoryBound(to: Optional<[URL]>.self).pointee else { return nil }
    return Unmanaged.passRetained(urls as NSArray).toOpaque()
}

// The linked-album router reads the pager's immutable URL only to confirm
// identity. Keep this Swift value out of Objective-C object-ivar APIs.
@_cdecl("ApolloLinkedAlbumCopyURL")
public func ApolloLinkedAlbumCopyURL(_ storage: UnsafeRawPointer?, _ size: Int) -> UnsafeMutableRawPointer? {
    guard let storage, size == MemoryLayout<URL>.size else { return nil }
    let url = storage.assumingMemoryBound(to: URL.self).pointee
    return Unmanaged.passRetained(url as NSURL).toOpaque()
}
