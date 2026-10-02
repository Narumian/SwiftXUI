//
//  Composable.swift
//  SwiftX
//
//  Created by Narumi Inada on 2026/10/02.
//




public protocol Composable<Domain>: Sendable {
    associatedtype Domain
    associatedtype Body: Composable<Domain>

    var body: Body { get }

    func lower(into output: inout Domain)
}
