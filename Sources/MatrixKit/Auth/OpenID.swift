import Foundation

/// An OpenID token issued by the homeserver
/// (`POST /user/{userId}/openid/request_token`). MatrixRTC call servers
/// (MSC4143) accept it in place of Matrix credentials when minting
/// LiveKit access tokens.
public struct OpenIDToken: Hashable, Sendable, Codable {
    /// The token to present to the call server.
    public var accessToken: String
    /// Token type (always `"Bearer"` per spec).
    public var tokenType: String
    /// The homeserver that issued the token.
    public var matrixServerName: String
    /// Lifetime in seconds from issuance.
    public var expiresIn: Int

    public init(
        accessToken: String, tokenType: String,
        matrixServerName: String, expiresIn: Int
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.matrixServerName = matrixServerName
        self.expiresIn = expiresIn
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case matrixServerName = "matrix_server_name"
        case expiresIn = "expires_in"
    }
}

/// `POST .../openid/request_token` body (empty object).
public struct OpenIDTokenRequest: Hashable, Sendable, Codable {
    public init() {}
}
