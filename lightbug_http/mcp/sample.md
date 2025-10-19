# Initialize
## Request
```
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "elicitation": {}
    },
    "clientInfo": {
      "name": "example-client",
      "version": "1.0.0"
    }
  }
}
```
## Response
```
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "tools": {
        "listChanged": true
      },
      "resources": {}
    },
    "serverInfo": {
      "name": "example-server",
      "version": "1.0.0"
    }
  }
}
```
## Understanding
- やること
    - Protocol Version Negotiation
        - プロトコルが共通であるかを確認
        - 互換性のないバージョン間の通信であるとわかったら通信を終了
    - Capability Discovery
        - Clinent,Serverがそれぞれ対応しているPrimitive(tools,resouces,prompts)とNotification(Sampling,Elicitation,Loggingも)を確認する
    - Identity Exchange
        - clientInfoおよびServerInfoはデバッグ及び互換性の目的で識別情報とバージョンを提供
# Initialized Notification
```
{
  "jsonrpc": "2.0",
  "method": "notifications/initialized"
}
```
- クライアントは準備完了のサインとしてInitialized Notificationを送信
# Tool Discovery
## Request
```
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list"
}
```
## Response
```
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "calculator_arithmetic",
        "title": "Calculator",
        "description": "Perform mathematical calculations including basic arithmetic, trigonometric functions, and algebraic operations",
        "inputSchema": {
          "type": "object",
          "properties": {
            "expression": {
              "type": "string",
              "description": "Mathematical expression to evaluate (e.g., '2 + 3 * 4', 'sin(30)', 'sqrt(16)')"
            }
          },
          "required": ["expression"]
        }
      },
      {
        "name": "weather_current",
        "title": "Weather Information",
        "description": "Get current weather information for any location worldwide",
        "inputSchema": {
          "type": "object",
          "properties": {
            "location": {
              "type": "string",
              "description": "City name, address, or coordinates (latitude,longitude)"
            },
            "units": {
              "type": "string",
              "enum": ["metric", "imperial", "kelvin"],
              "description": "Temperature units to use in response",
              "default": "metric"
            }
          },
          "required": ["location"]
        }
      }
    ]
  }
}
```
## Understanding
- 主要なフィールド
    - name
        - 機能における主キー
        - 命名規則 | calculateではなくcalculator_arithmetic
            - 何をどうするか等
    - title
        - クライアントがユーザーに表示できる、人間が読み取れるツールの表示名
    - description
        - ツールの機能と使用タイミングに関する詳細な説明
    - inputSchema
        - 期待される入力パラメータを定義するJSONスキーマ
        - 必須なのかオプショナルなのかを明確に

# Tool Execution
## Requst
```
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "weather_current",
    "arguments": {
      "location": "San Francisco",
      "units": "imperial"
    }
  }
}
```
## Response
```
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Current weather in San Francisco: 68°F, partly cloudy with light winds from the west at 8 mph. Humidity: 65%"
      }
    ]
  }
}
```
## Understanding
- tools/callメソッドを使う
- Requestの主要なフィールド
    - name
    - arguments
        - inputSchemaに基づいた適切なarg
- JSON-RPC2.0に則っておこなう
    - 固有ID
- Responseの主要なフィールド
    - content[Array]
        - ツールの応答としてはcontentの配列を返す
    - ContentTypes
        - "type": "text"で指定する

# Notification
## notification
```
{
  "jsonrpc": "2.0",
  "method": "notifications/tools/list_changed"
}
```
- サーバー側のツールが変更されたときに一方的に通知できる
- サーバーは接続中のクライアントに事前に通知できる

## Understanding
- idフィールドを持たず、レスポンスも必要としない
- notifications/tools/list_changedは初期化時に"listChanged":trueとしたサーバーからのみ送信される
- イベントドリブンに、サーバー側でのstateが変わったときに通知を送る
- クライアントはこれを受けて以下の様に反応することがしばしばある
```
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/list"
}
```

## Words
- Tools
- Resouces
    - サポートしている場合resouces/listとresouces/readがつかえる
- Prompts
- Sampling
- Elicitation
    - サーバーがユーザーから追加の情報を要求できるようにする
    - 追加情報を要求するためにelicitation/requestが送られる
    - Client側で"elicitation": {}とあればサーバーからelicitation/createが受け取れる
- Logging
    - サーバーがデバッグ及び監視の目的でクライアントにログメッセージを送れる
- Notification
    - サーバーもクライアントも任意のタイミング(たとえばtoolが変わったタイミング)で通知を送れる
    - これはリクエストでないので受け取った側がレスポンスを返す必要はない
- {listChanged: true}
    - toolListが変更された場合にtools/list_changedというNotificationをおくる