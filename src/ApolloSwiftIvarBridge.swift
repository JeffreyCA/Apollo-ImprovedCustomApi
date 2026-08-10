//
//  ApolloSwiftIvarBridge.swift
//  Apollo-Reborn
//
//  Tiny ABI-safe helpers for the handful of Swift stored properties that Apollo
//  does not expose to Objective-C. Objective-C code locates the ivar by name and
//  passes its storage address here; Swift performs the assignment so retain/
//  release behavior and Optional<String>'s spare-bit representation stay owned
//  by the Swift runtime instead of being reimplemented with raw memory writes.
//

import Foundation
import UIKit

@_cdecl("ApolloSwiftAssignOptionalString")
public func ApolloSwiftAssignOptionalString(
    _ storage: UnsafeMutableRawPointer?,
    _ utf8Value: UnsafePointer<CChar>?
) {
    guard let storage else { return }
    let value = utf8Value.map { String(cString: $0) }
    storage.assumingMemoryBound(to: Optional<String>.self).pointee = value
}

@_cdecl("ApolloSwiftAssignOptionalStringArray")
public func ApolloSwiftAssignOptionalStringArray(
    _ storage: UnsafeMutableRawPointer?,
    _ arrayObject: UnsafeRawPointer?
) {
    guard let storage else { return }
    let value: [String]?
    if let arrayObject {
        let array = Unmanaged<NSArray>.fromOpaque(arrayObject).takeUnretainedValue()
        value = array.compactMap { $0 as? String }
    } else {
        value = nil
    }
    storage.assumingMemoryBound(to: Optional<[String]>.self).pointee = value
}

/// ApolloNavigationController keeps its forward history in a Swift
/// `[UIViewController]` stored ivar. Objective-C can locate that ivar, but it
/// must not treat the one-word Swift Array value as an NSArray object or write
/// `_swiftEmptyArrayStorage` by hand. Keeping the assignment here makes Swift
/// own the array ABI and its retain/release operations.
@_cdecl("ApolloSwiftClearViewControllerArray")
public func ApolloSwiftClearViewControllerArray(
    _ storage: UnsafeMutableRawPointer?
) {
    guard let storage else { return }
    storage.assumingMemoryBound(to: [UIViewController].self).pointee.removeAll(
        keepingCapacity: false
    )
}

/// Diagnostic companion for the clear helper. This is intentionally a count,
/// not an NSArray bridge: no Objective-C caller should ever take ownership of
/// Apollo's private Swift-array storage.
@_cdecl("ApolloSwiftViewControllerArrayCount")
public func ApolloSwiftViewControllerArrayCount(
    _ storage: UnsafeRawPointer?
) -> UInt {
    guard let storage else { return 0 }
    return UInt(storage.assumingMemoryBound(to: [UIViewController].self).pointee.count)
}

// Process-local wrapper around the exact AnyHashable identity Apollo's
// ListAdapter uses for diffing. Objective-C must never decode Swift Array,
// Dictionary, AnyHashable, or Foundation.IndexPath storage itself; these two C
// entry points keep every collection operation on the Swift side of the ABI.
private final class ApolloListAdapterIdentityToken: NSObject, NSCopying {
    let key: AnyHashable

    init(key: AnyHashable) {
        self.key = key
        super.init()
    }

    override var description: String { "<ApolloListAdapterIdentityToken>" }
    override var debugDescription: String { description }

    func copy(with zone: NSZone? = nil) -> Any { self }
}

@_cdecl("ApolloSwiftListAdapterModelIdentifier")
public func ApolloSwiftListAdapterModelIdentifier(
    _ objectsStorage: UnsafeRawPointer?,
    _ section: Int,
    _ row: Int
) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let objectsStorage, section == 0, row >= 0 else { return nil }
    let objects = objectsStorage.assumingMemoryBound(to: [AnyHashable].self).pointee
    guard row < objects.count else { return nil }
    let token = ApolloListAdapterIdentityToken(key: objects[row])
    return Unmanaged.passRetained(token).toOpaque()
}

@_cdecl("ApolloSwiftListAdapterIndexPathForModelIdentifier")
public func ApolloSwiftListAdapterIndexPathForModelIdentifier(
    _ mappingStorage: UnsafeRawPointer?,
    _ tokenObject: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let mappingStorage, let tokenObject else { return nil }
    let object = Unmanaged<AnyObject>.fromOpaque(tokenObject).takeUnretainedValue()
    guard let token = object as? ApolloListAdapterIdentityToken else { return nil }
    let mapping = mappingStorage.assumingMemoryBound(
        to: [AnyHashable: IndexPath].self
    ).pointee
    guard let path = mapping[token.key] else { return nil }
    return Unmanaged.passRetained(path as NSIndexPath).toOpaque()
}
