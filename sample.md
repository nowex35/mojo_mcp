# MCP と Streaming ディレクトリの依存関係まとめ

## 📁 ディレクトリ構成

```
lightbug_http/
├── mcp/                    (MCPプロトコル実装)
│   ├── __init__.mojo
│   ├── jsonrpc.mojo       ← 基盤層（依存なし）
│   ├── messages.mojo
│   ├── session.mojo
│   ├── timeout.mojo
│   ├── tools.mojo
│   ├── utils.mojo
│   ├── server.mojo        ← 統合層（最上位）
│   └── streaming_transport.mojo
│
└── streaming/              (HTTPストリーミング実装)
    ├── __init__.mojo
    ├── streamable_service.mojo
    ├── streamable_response.mojo
    ├── streamable_body_stream.mojo
    ├── streamable_exchange.mojo
    ├── streamable_request.mojo
    ├── server.mojo
    └── shared_connection.mojo
```

## 🔄 クロスディレクトリ依存関係

### **MCP → Streaming** (主要な統合方向)
```
mcp/server.mojo
  └→ streaming/server.mojo (StreamingServer)

mcp/streaming_transport.mojo
  ├→ streaming/streamable_service.mojo (StreamableHTTPService)
  └→ streaming/streamable_exchange.mojo (StreamableHTTPExchange)
```

### **Streaming → MCP** (ユーティリティ関数の利用)
```
streaming/streamable_body_stream.mojo
  └→ mcp/utils.mojo (hex)

streaming/streamable_exchange.mojo
  └→ mcp/utils.mojo (hex)

streaming/server.mojo
  └→ mcp/utils.mojo (delete_zombies)
```

## 📊 MCP内部の依存関係

```
server.mojo (統合層 - 最上位)
  ├→ jsonrpc.mojo
  ├→ messages.mojo
  ├→ session.mojo
  ├→ tools.mojo
  ├→ utils.mojo
  ├→ timeout.mojo
  └→ streaming_transport.mojo

streaming_transport.mojo (トランスポート層)
  ├→ jsonrpc.mojo (parse_message, 型定義)
  ├→ messages.mojo (プロトコルバージョン)
  └→ server.mojo (MCPServer)

messages.mojo (メッセージ層)
  ├→ jsonrpc.mojo (JSONRPCResponse, JSONRPCNotification)
  └→ utils.mojo (current_time_ms)

timeout.mojo (タイムアウト管理)
  ├→ jsonrpc.mojo (型定義)
  └→ utils.mojo (current_time_ms)

tools.mojo (ツール実行)
  └→ utils.mojo (current_time_ms, add_json_key_value)

session.mojo (セッション管理)
  └→ utils.mojo (current_time_ms)

jsonrpc.mojo (基盤層 - 依存なし)
  └→ 外部依存のみ (python, utils.Variant)

utils.mojo (ユーティリティ)
  └→ lightbug_http._libc, _logger
```

## 📊 Streaming内部の依存関係

```
server.mojo (サーバー実装)
  ├→ streamable_exchange.mojo
  ├→ streamable_service.mojo
  └→ shared_connection.mojo

streamable_exchange.mojo (HTTP交換)
  └→ shared_connection.mojo

streamable_response.mojo (レスポンス)
  └→ streamable_body_stream.mojo

streamable_request.mojo (リクエスト)
  └→ streamable_body_stream.mojo

streamable_service.mojo (サービストレイト)
  └→ streamable_exchange.mojo

streamable_body_stream.mojo (ボディストリーム)
  └→ 外部依存のみ

shared_connection.mojo (共有接続)
  └→ 外部依存のみ
```

## 🏗️ アーキテクチャの特徴

### **レイヤー構造**

```
┌─────────────────────────────────────┐
│     Application Layer (MCP)         │
│  ┌──────────────────────────────┐   │
│  │ server.mojo (MCPServer)      │   │ ← 最上位統合レイヤー
│  └──────────────────────────────┘   │
│  ┌──────────────────────────────┐   │
│  │ streaming_transport.mojo     │   │ ← トランスポート層
│  └──────────────────────────────┘   │
│  ┌──────────────────────────────┐   │
│  │ messages, session, tools,    │   │ ← ビジネスロジック層
│  │ timeout                      │   │
│  └──────────────────────────────┘   │
│  ┌──────────────────────────────┐   │
│  │ jsonrpc.mojo                 │   │ ← プロトコル基盤層
│  └──────────────────────────────┘   │
└─────────────────────────────────────┘
              ↓ 利用
┌─────────────────────────────────────┐
│   Transport Layer (Streaming)       │
│  ┌──────────────────────────────┐   │
│  │ server.mojo (StreamingServer)│   │ ← HTTPサーバー
│  └──────────────────────────────┘   │
│  ┌──────────────────────────────┐   │
│  │ streamable_exchange.mojo     │   │ ← HTTP交換処理
│  └──────────────────────────────┘   │
│  ┌──────────────────────────────┐   │
│  │ streamable_request/response  │   │ ← リクエスト/レスポンス
│  └──────────────────────────────┘   │
│  ┌──────────────────────────────┐   │
│  │ streamable_body_stream.mojo  │   │ ← チャンク転送
│  └──────────────────────────────┘   │
└─────────────────────────────────────┘
```

### **主要な設計原則**

1. **明確な責任分離**:
   - **MCP**: プロトコル、セッション、ツール実行
   - **Streaming**: HTTP通信、ストリーミング、接続管理

2. **依存の方向**:
   - **主流**: MCP → Streaming（MCPがStreamingを利用）
   - **逆流**: Streaming → MCP/utils（ユーティリティ関数のみ）

3. **疎結合性**:
   - Streaming層は独立性が高い（MCPへの依存は最小限）
   - MCP層はStreamingを抽象的に利用

4. **凝集度**:
   - **MCP**: 密結合（機能が相互依存）
   - **Streaming**: 疎結合（モジュラー設計）

## 🎯 重要な観察点

1. **`jsonrpc.mojo`が基盤**: MCP内で唯一、内部依存がない
2. **`server.mojo`が統合ポイント**: 全MCPコンポーネントを統合
3. **`streaming_transport.mojo`がブリッジ**: MCPとStreamingを接続
4. **`utils.mojo`が共有ユーティリティ**: 両ディレクトリから利用される
5. **循環依存なし**: クリーンな依存グラフ

## 📋 詳細な依存関係マトリックス

### MCP ディレクトリ

| ファイル | 内部MCP依存 | 内部Streaming依存 | 外部lightbug依存 | 外部標準ライブラリ |
|---------|------------|-----------------|----------------|------------------|
| `jsonrpc.mojo` | なし | なし | なし | python, utils.Variant |
| `messages.mojo` | jsonrpc, utils | なし | なし | なし |
| `utils.mojo` | なし | なし | _libc, _logger | random, python |
| `session.mojo` | utils | なし | なし | collections, python |
| `timeout.mojo` | jsonrpc, utils | なし | なし | collections |
| `tools.mojo` | utils | なし | _libc | collections, time, memory, os |
| `streaming_transport.mojo` | jsonrpc, server, messages | streamable_service, streamable_exchange | io.bytes | memory |
| `server.mojo` | jsonrpc, messages, session, tools, utils, timeout, streaming_transport | streaming.server | なし | collections |

### Streaming ディレクトリ

| ファイル | 内部MCP依存 | 内部Streaming依存 | 外部lightbug依存 | 外部標準ライブラリ |
|---------|------------|-----------------|----------------|------------------|
| `streamable_service.mojo` | なし | streamable_exchange | なし | なし |
| `streamable_body_stream.mojo` | mcp.utils (hex) | なし | io.bytes, connection | memory |
| `shared_connection.mojo` | なし | なし | connection, io.bytes | memory |
| `streamable_request.mojo` | なし | streamable_body_stream | header, cookie, uri, connection, io | memory |
| `streamable_response.mojo` | なし | streamable_body_stream | header, cookie, connection, strings, io, external.small_time | memory |
| `streamable_exchange.mojo` | mcp.utils (hex) | shared_connection | header, cookie, uri, strings, io | memory, collections |
| `server.mojo` | mcp.utils (delete_zombies) | streamable_exchange, streamable_service, shared_connection | connection, _logger, error, io, _libc | memory |

## 🔍 循環依存のチェック

**結果: 循環依存なし ✓**

- MCP内部: 一方向の依存関係（`server.mojo`が最上位）
- Streaming内部: 一方向の依存関係（`server.mojo`が最上位）
- クロスディレクトリ: MCPがStreamingを利用、StreamingはMCPのutilsのみ利用

## 📝 アーキテクチャ改善の提案

### 現状の課題

1. **Streaming → MCP/utils への依存**
   - `hex`関数と`delete_zombies`関数がStreaming層から参照されている
   - これによりStreaming層の独立性が低下

### 改善案

1. **共通ユーティリティの分離**
   ```
   lightbug_http/
   ├── utils/              (新設: 共通ユーティリティ)
   │   ├── hex.mojo
   │   └── process.mojo
   ├── mcp/
   └── streaming/
   ```

2. **依存の明確化**
   - MCP特有のユーティリティとStreamingでも使う汎用ユーティリティを分離
   - 完全な層分離を実現

この構造により、MCPプロトコルとHTTPストリーミングが明確に分離され、保守性の高いアーキテクチャが実現されています。
