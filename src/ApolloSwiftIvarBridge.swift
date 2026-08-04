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
