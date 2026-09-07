import Foundation

// These return through the production @_cdecl function, after the source
// Swift array's local lifetime ends. The Objective-C harness consumes +1 with
// CFBridgingRelease, matching the native media menu's exact calling convention.
@_cdecl("ApolloTestNilMediaURLs")
func ApolloTestNilMediaURLs() -> UnsafeMutableRawPointer? {
    var urls: [URL]? = nil
    return withUnsafePointer(to: &urls) { ApolloSaveAllMediaCopyURLs($0) }
}

@_cdecl("ApolloTestEmptyMediaURLs")
func ApolloTestEmptyMediaURLs() -> UnsafeMutableRawPointer? {
    var urls: [URL]? = []
    return withUnsafePointer(to: &urls) { ApolloSaveAllMediaCopyURLs($0) }
}

@_cdecl("ApolloTestOrderedMediaURLs")
func ApolloTestOrderedMediaURLs() -> UnsafeMutableRawPointer? {
    var urls: [URL]? = [
        URL(string: "https://i.redd.it/first.jpg")!,
        URL(string: "https://i.imgur.com/second.mp4")!,
        URL(string: "https://i.redd.it/first.jpg")!
    ]
    return withUnsafePointer(to: &urls) { ApolloSaveAllMediaCopyURLs($0) }
}

@_cdecl("ApolloTestOptionalURLArraySize")
func ApolloTestOptionalURLArraySize() -> Int {
    MemoryLayout<[URL]?>.size
}

@_cdecl("ApolloTestLinkedAlbumURL")
func ApolloTestLinkedAlbumURL() -> UnsafeMutableRawPointer? {
    var url = URL(string: "https://imgur.com/a/L9afIk4?source=post#2")!
    return withUnsafePointer(to: &url) {
        ApolloLinkedAlbumCopyURL($0, MemoryLayout<URL>.size)
    }
}

@_cdecl("ApolloTestLinkedAlbumInvalidSize")
func ApolloTestLinkedAlbumInvalidSize(_ adjustment: Int) -> UnsafeMutableRawPointer? {
    var url = URL(string: "https://imgur.com/a/L9afIk4")!
    return withUnsafePointer(to: &url) {
        ApolloLinkedAlbumCopyURL($0, MemoryLayout<URL>.size + adjustment)
    }
}
