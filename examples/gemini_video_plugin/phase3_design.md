# Phase3 構造化・設計: gemini_video プラグイン追加

### 0. 既存資産の再利用判定

| 機能/モジュール | 判定 | 既存パス | 対応内容 |
|----------------|------|----------|----------|
| プラグイン基底クラス | そのまま再利用 | `plugins/base_plugin.py` | `BasePlugin` を継承して実装。 |
| 設定ファイル | 拡張して利用 | `config/config.yaml` | `plugins.gemini_video` セクションを追加。 |
| ログ出力 | そのまま再利用 | — | `loguru` を使用してプロジェクト標準のログ出力を維持。 |
| デバイス設定モデル | 拡張して利用 | `plugins/base_plugin.py` | `DeviceConfig` を継承したプラグイン固有設定を実装。 |

**新規作成の根拠**: 既存の `video_analysis` プラグインは OpenCV 等を用いたローカル解析を主眼としており、Gemini API (LMM) を用いたマルチモーダル解析機能は存在しないため。

---

### 1. 機能一覧（ユーザーストーリー形式）

- **動画解析の依頼**: ユーザーとして、ローカルの動画ファイルパスと解析指示（プロンプト）を指定することで、Gemini API による高度なシーン解析や異常検知の結果を受け取ることができる。
- **自由なプロンプト指定**: ユーザーとして、「この動画の作業内容を3行で要約して」「不審な動きがあれば報告して」など、目的に合わせた自然言語での問い合わせができる。
- **プラグイン管理**: 管理者として、`config.yaml` を通じて API キーや使用モデル、タイムアウト設定を一括管理できる。

---

### 2. 画面構成（UI単位）

- **MCP ツール出力**: 解析結果は Claude Desktop 等の MCP クライアント上のテキストコンテンツとして表示される。

---

### 3. API設計（MCP ツール）

#### ツール名: `analyze_video_gemini`
- **概要**: Gemini API を使用して動画ファイルを解析します。
- **入力引数 (inputSchema)**:
    - `video_path` (string, required): 解析対象の動画ファイルの絶対パス。
    - `prompt` (string, required): 解析のための指示文（例: 「異常を検知してください」）。
- **出力 (TextContent)**:
    - `type`: "text"
    - `text`: Gemini から返却された解析結果の文字列。

---

### 4. データ構造（オブジェクト）

#### `GeminiVideoConfig(DeviceConfig)`
※ 本プラグインでは「デバイス」を Gemini API サービスとして扱う。
- `api_key`: str (required)
- `model`: str (default: "gemini-1.5-flash")
- `timeout`: int (default: 120, APIレスポンス待ち時間)

---

### 5. 非機能要件

- **性能**: 動画のアップロードと API 処理には時間がかかる。120秒をデフォルトタイムアウトとし、大規模動画の場合は `asyncio.to_thread` で MCP サーバーのメインループをブロックしないようにする。
- **セキュリティ**: API キーは設定ファイル（`config.yaml`）で管理し、ログには出力しない。
- **信頼性**: ネットワークエラーや API 制限（Rate Limit）発生時に、適切なエラーログを `loguru` で記録し、ユーザーに分かりやすいメッセージを返す。

---

### 6. 実装優先順位

1. **基礎構造**: `plugins/gemini_video/plugin.py` の作成と `BasePlugin` の継承。
2. **設定管理**: `GeminiVideoConfig` モデルと `config.yaml` 読み込みの実装。
3. **API 連携ロジック**: `google-generativeai` を用いた動画アップロードおよび解析処理の実装。
4. **MCP ツール公開**: `get_tools` および `execute_tool` の実装。
5. **テスト・検証**: `test/test_gemini_video.py` による正常系・異常系の動作確認。

---

### 7. 機能間依存関係

- `GeminiVideoPlugin` → `BasePlugin` (継承)
- `GeminiVideoPlugin` → `google-generativeai` (外部 SDK 依存)
- `MCPServer` (core) → `GeminiVideoPlugin` (ツール動的登録)

---

### 8. 主要処理フロー

1. **引数バリデーション**: `video_path` の存在と読み取り権限を確認。
2. **API 初期化**: `google-generativeai` に API キーを設定。
3. **ファイルアップロード**: `genai.upload_file()` を実行。
4. **ステータス待機**: ファイルの状態が `ACTIVE` になるまでポーリング（または SDK の完了待機）。
5. **コンテンツ生成**: `model.generate_content([file, prompt])` を呼び出し。
6. **後処理**: 解析結果を取得し、アップロードしたファイルを `file.delete()` で API 側から削除。
7. **返却**: 結果を `types.TextContent` のリスト形式で MCP サーバーに返す。

---

### 9. エラーハンドリング設計

- **ファイル未検出**: `FileNotFoundError` をキャッチし、「ファイルが見つかりません: {path}」を返却。
- **認証エラー**: API キーが無効な場合、ログに詳細を記録し、ユーザーには「API 認証に失敗しました」と通知。
- **API 制限**: クォータ制限（429 Too Many Requests）発生時、その旨を通知。
- **タイムアウト**: 処理が規定時間を超えた場合、タイムアウトエラーとして処理を中断し通知。

---

### 10. データ移行計画

- なし。

---

### 11. ロールバック戦略

- `plugins/gemini_video/` ディレクトリの削除。
- `config/config.yaml` から `gemini_video` 設定の削除。

---

### 12. 監視・アラート設計

- **ログ出力**: `loguru` を使用し、`/logs` ディレクトリ内のファイルに API 呼び出しの結果と所要時間を出力。
- **エラー監視**: 致命的なエラー（認証失敗等）は `logger.error` で記録し、監視対象とする。

---

## 要約（200字以内）
Gemini 1.5 Flash を使用した動画解析プラグイン `gemini_video` を新規設計。`analyze_video_gemini` ツールを提供し、ローカル動画のアップロード、処理待ち、プロンプトによる解析を順次実行するフローを定義。`BasePlugin` 準拠の同期・非同期混在実装（SDK呼び出しは `to_thread` 使用）とし、設定は `config.yaml` で管理。エラー時は `loguru` で記録し、安全なリソース削除（API側のファイル削除）も含む。
