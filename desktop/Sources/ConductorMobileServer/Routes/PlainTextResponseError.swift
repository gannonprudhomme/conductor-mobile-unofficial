//
//  PlainTextResponseError.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Hummingbird

/// Hummingbird's `HTTPError` encodes its message as nested JSON. This type preserves the
/// mobile API's existing plain-text error body while still providing the correct HTTP status.
struct PlainTextResponseError: HTTPResponseError {
    let status: HTTPResponse.Status
    let message: String

    init(_ status: HTTPResponse.Status, message: String) {
        self.status = status
        self.message = message
    }

    func response(
        from request: Request,
        context: some Hummingbird.RequestContext
    ) throws -> Response {
        var response = message.response(from: request, context: context)
        response.status = status
        return response
    }
}
