from lightbug_http.http import HTTPResponse
from lightbug_http.header import Headers, Header, HeaderKey
from lightbug_http.io.bytes import bytes
fn BadRequest(message: String) -> HTTPResponse:
    var body = String('{"jsonrpc":"2.0","error":{"code":-32600,"message":"', message, '"},"id":null}')
    return HTTPResponse(
        bytes(body),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=400,
        status_text="Bad Request",
    )
fn MethodNotAllowed() -> HTTPResponse:
    return HTTPResponse(
        bytes('{"jsonrpc":"2.0","error":{"code":-32600,"message":"Method not allowed. MCP requires POST requests."},"id":null}'),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=405,
        status_text="Method Not Allowed",
    )

fn InternalError() -> HTTPResponse:
    return HTTPResponse(
        bytes('{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"},"id":null}'),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=500,
        status_text="Internal Server Error",
    )