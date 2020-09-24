// Copyright © 2020 Metabolist. All rights reserved.

import Combine
import Foundation
import HTTP
import Mastodon

public final class MastodonAPIClient: HTTPClient {
    public var instanceURL: URL
    public var accessToken: String?

    public required init(session: URLSession, instanceURL: URL) {
        self.instanceURL = instanceURL
        super.init(session: session, decoder: MastodonDecoder())
    }

    public override func dataTaskPublisher<T: DecodableTarget>(
        _ target: T) -> AnyPublisher<(data: Data, response: HTTPURLResponse), Error> {
        super.dataTaskPublisher(target)
            .mapError { [weak self] error -> Error in
                if case let HTTPError.invalidStatusCode(data, _) = error,
                   let apiError = try? self?.decoder.decode(APIError.self, from: data) {
                    return apiError
                }

                return error
            }
            .eraseToAnyPublisher()
    }
}

extension MastodonAPIClient {
    public func request<E: Endpoint>(_ endpoint: E) -> AnyPublisher<E.ResultType, Error> {
        dataTaskPublisher(target(endpoint: endpoint))
            .map(\.data)
            .decode(type: E.ResultType.self, decoder: decoder)
            .eraseToAnyPublisher()
    }

    public func pagedRequest<E: Endpoint>(
        _ endpoint: E,
        maxID: String? = nil,
        minID: String? = nil,
        sinceID: String? = nil,
        limit: Int? = nil) -> AnyPublisher<PagedResult<E.ResultType>, Error> {
        let pagedTarget = target(endpoint: Paged(endpoint, maxID: maxID, minID: minID, sinceID: sinceID, limit: limit))
        let dataTask = dataTaskPublisher(pagedTarget).share()
        let decoded = dataTask.map(\.data).decode(type: E.ResultType.self, decoder: decoder)
        let info = dataTask.map { _, response -> PagedResult<E.ResultType>.Info in
            var maxID: String?
            var minID: String?
            var sinceID: String?

            if let links = response.value(forHTTPHeaderField: "Link") {
                let queryItems = Self.linkDataDetector.matches(
                    in: links,
                    range: .init(links.startIndex..<links.endIndex, in: links))
                    .compactMap { match -> [URLQueryItem]? in
                        guard let url = match.url else { return nil }

                        return URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems
                    }
                    .reduce([], +)

                maxID = queryItems.first { $0.name == "max_id" }?.value
                minID = queryItems.first { $0.name == "min_id" }?.value
                sinceID = queryItems.first { $0.name == "since_id" }?.value
            }

            return PagedResult.Info(maxID: maxID, minID: minID, sinceID: sinceID)
        }

        return decoded.zip(info).map(PagedResult.init(result:info:)).eraseToAnyPublisher()
    }
}

private extension MastodonAPIClient {
    // swiftlint:disable force_try
    static let linkDataDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    // swiftlint:enable force_try

    func target<E: Endpoint>(endpoint: E) -> MastodonAPITarget<E> {
        MastodonAPITarget(baseURL: instanceURL, endpoint: endpoint, accessToken: accessToken)
    }
}
