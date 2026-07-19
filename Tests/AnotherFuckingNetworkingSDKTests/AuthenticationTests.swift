import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("HTTP authentication")
struct AuthenticationTests {
    @Test("Single-flight token loading coalesces concurrent callers")
    func singleFlightLoad() async throws {
        let started = AsyncSignal()
        let release = AsyncSignal()
        let loads = LockedBox(0)
        let provider = SingleFlightTokenProvider(
            loader: {
                loads.withLock { $0 += 1 }
                await started.signal()
                _ = await release.wait()
                return AccessToken(value: "cached")
            },
            refreshLoader: {
                AccessToken(value: "refreshed")
            }
        )

        let first = Task { try await provider.accessToken() }
        #expect(await started.wait())
        let second = Task { try await provider.accessToken() }
        await release.signal()

        #expect(try await first.value == "cached")
        #expect(try await second.value == "cached")
        #expect(loads.withLock { $0 } == 1)
    }

    @Test("A 401 refreshes once and replays the typed request")
    func refreshesAfterUnauthorized() async throws {
        let calls = LockedBox(0)
        let headers = LockedBox<[String]>([])
        let refreshes = LockedBox(0)
        let responseBody = Data(#"{"id":42,"displayName":"Arthur"}"#.utf8)
        let stub = StubSession { request in
            headers.withLock {
                $0.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            }
            let call = calls.withLock { value in
                value += 1
                return value
            }
            if call == 1 {
                return .respond(try .http(for: request, statusCode: 401))
            }
            return .respond(try .http(for: request, data: responseBody))
        }
        let provider = SingleFlightTokenProvider(
            loader: { AccessToken(value: "old") },
            refreshLoader: {
                refreshes.withLock { $0 += 1 }
                return AccessToken(value: "new")
            }
        )
        let client = AuthenticatedAPIClient(
            client: stub.client(),
            authenticator: provider
        )

        let user = try await client.send(GetUserRequest(id: 42))

        #expect(user == TestUser(id: 42, displayName: "Arthur"))
        #expect(headers.withLock { $0 } == ["Bearer old", "Bearer new"])
        #expect(calls.withLock { $0 } == 2)
        #expect(refreshes.withLock { $0 } == 1)
    }

    @Test("Authenticated streams refresh before exposing bytes")
    func refreshesStreamBeforeExposure() async throws {
        let calls = LockedBox(0)
        let stub = StubSession { request in
            let call = calls.withLock { value in
                value += 1
                return value
            }
            if call == 1 {
                return .respond(try .http(for: request, statusCode: 401))
            }
            return .respond(try .http(
                for: request,
                data: Data("streamed".utf8)
            ))
        }
        let provider = SingleFlightTokenProvider(
            loader: { AccessToken(value: "old") },
            refreshLoader: { AccessToken(value: "new") }
        )
        let client = AuthenticatedAPIClient(
            client: stub.client(),
            authenticator: provider
        )

        let stream = try await client.stream(GetUserRequest(id: 42))
        var received = Data()
        for try await byte in stream {
            received.append(byte)
        }

        #expect(received == Data("streamed".utf8))
        #expect(calls.withLock { $0 } == 2)
    }

    @Test("Non-idempotent requests do not replay without explicit opt-in")
    func mutationDoesNotReplayByDefault() async throws {
        let calls = LockedBox(0)
        let refreshes = LockedBox(0)
        let stub = StubSession { request in
            calls.withLock { $0 += 1 }
            return .respond(try .http(for: request, statusCode: 401))
        }
        let provider = SingleFlightTokenProvider(
            loader: { AccessToken(value: "old") },
            refreshLoader: {
                refreshes.withLock { $0 += 1 }
                return AccessToken(value: "new")
            }
        )
        let client = AuthenticatedAPIClient(
            client: stub.client(),
            authenticator: provider
        )

        do {
            _ = try await client.send(MutationRequest())
            Issue.record("Expected the unauthorized mutation to fail")
        } catch let error as NetworkError {
            guard case .requestFailed(let failure) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(failure.statusCode == 401)
        }

        #expect(calls.withLock { $0 } == 1)
        #expect(refreshes.withLock { $0 } == 0)
    }
}

private struct MutationRequest: Request {
    typealias ReturnType = EmptyResponse

    let path = "users"
    let method = HTTPMethod.post
}
