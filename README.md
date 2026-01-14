# Mojo MCP Server

大学の情報特別演習で実装したModel Context Protocol (MCP) サーバーの部分実装です。

## 概要

本プロジェクトは、[lightbug_http](https://github.com/saviorand/lightbug_http)というMojo言語向けのHTTPフレームワークを基盤として、[MCP (Model Context Protocol)](https://modelcontextprotocol.io/) の一部機能を実装したものです。

MCP 2025-06-18 仕様に基づき、**tools機能**の動作確認までを完了しています。

## 実施内容

1. **HTTPサーバー実装のコードリーディング**
   - lightbug_httpフレームワークのアーキテクチャ理解
   - HTTPリクエスト/レスポンス処理の仕組みの調査

2. **MCP プロトコルの実装**
   - JSON-RPC 2.0 ベースのメッセージング
   - セッション管理
   - ツール登録・実行機能

3. **並行処理の実装**
   - fork による複数接続の処理

## 実装範囲

MCP 2025-06-18 仕様のうち、以下の機能を実装・動作確認しています：

| 機能 | 状態 |
|------|------|
| initialize / initialized | 実装済み |
| tools/list | 実装済み |
| tools/call | 実装済み |
| resources/* | 未実装 (スタブのみ) |
| prompts/* | 未実装 (スタブのみ) |

## ディレクトリ構成

```
.
├── lightbug_http/          # HTTPフレームワーク (OSS)
│   ├── mcp/                # MCP実装 (本演習で作成)
│   │   ├── mcp_server.mojo      # MCPサーバー本体
│   │   ├── jsonrpc.mojo         # JSON-RPC 2.0 実装
│   │   ├── messages.mojo        # MCPメッセージ定義
│   │   ├── tools.mojo           # ツール機能
│   │   ├── session.mojo         # セッション管理
│   │   ├── timeout.mojo         # タイムアウト管理
│   │   ├── streaming_server.mojo
│   │   ├── streaming_transport.mojo
│   │   └── ...
│   ├── http/               # HTTP関連モジュール
│   └── ...
├── mcp_test/               # テストスイート (本演習で作成)
│   ├── test_mcp_server.py  # pytest ベースのテスト
│   └── README.md           # テスト実行手順
├── working_mcp_server.mojo # サンプルMCPサーバー
├── mojoproject.toml        # プロジェクト設定
└── pixi.toml               # パッケージ管理設定
```

## 動作環境

- Mojo (MAX 25.4.0以上)
- Python 3.7以上 (テスト実行用)
- Pixi (パッケージ管理)

## セットアップ

```bash
# 依存関係のインストール
pixi install
```

## 使用方法

### MCPサーバーの起動

```bash
pixi run mojo working_mcp_server.mojo
```

サーバーは `http://127.0.0.1:8081` で起動します。

### サンプルコード

```mojo
from lightbug_http.mcp import MCPServer
from lightbug_http.mcp.tools import MCPToolResult, MCPToolRequest, create_string_parameter

fn echo_tool(request: MCPToolRequest) raises -> MCPToolResult:
    var result = MCPToolResult()
    var message = request.get_string("message", "No message provided")
    result.add_text_content("Echo: " + message)
    return result

fn main() raises:
    var server = MCPServer(server_name="my-mcp-server", server_version="1.0.0")

    server.tool(
        name="echo",
        description="Echoes back the provided message",
        parameters=create_string_parameter("message", "The message to echo", True),
        executor=echo_tool
    )

    server.start(address="127.0.0.1:8081")
```

### テストの実行

```bash
# 仮想環境の作成と依存関係インストール
python3 -m venv mcp_test/venv
mcp_test/venv/bin/pip install -r mcp_test/requirements.txt

# テスト実行 (サーバー起動後)
mcp_test/venv/bin/pytest mcp_test/test_mcp_server.py -v
```

詳細は [mcp_test/README.md](mcp_test/README.md) を参照してください。

## 参考資料

- [Model Context Protocol Specification](https://spec.modelcontextprotocol.io/)
- [lightbug_http - Mojo HTTP Framework](https://github.com/saviorand/lightbug_http)
- [Mojo Programming Language](https://www.modular.com/mojo)

## ライセンス

本リポジトリのMCP実装部分 (`lightbug_http/mcp/` および `mcp_test/`) は教育目的で作成されました。
lightbug_httpフレームワーク自体のライセンスについては、元のリポジトリを参照してください。
