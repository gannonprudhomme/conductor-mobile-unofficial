import ConductorData
import Testing

struct DesktopClientTests {
    @Test("Desktop client errors include response details")
    func errorDescriptions() {
        #expect(
            DesktopClientError.requestFailed(statusCode: 500, message: "boom").localizedDescription
                == "The desktop service returned HTTP 500: boom"
        )

        #expect(
            DesktopClientError.requestFailed(statusCode: 404, message: "").localizedDescription
                == "The desktop service returned HTTP 404."
        )
    }
}
