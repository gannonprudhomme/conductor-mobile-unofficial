//
//  String+Extensions.swift
//  ConductorFoundation
//
//  Created by Gannon Prudomme on 7/12/26.
//

public extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
