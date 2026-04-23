### 1. 実装概要

MCP ツール `analyze_video_gemini` を公開し、外部（Claude Desktop等）から動画解析を実行可能にした。
`BasePlugin` の規約に従い、`get_tools` でツール定義を返し、`execute_tool` で実際の解析処理（T-02で実装済み）を呼び出す構成とした。
非同期実行に対応するため、ブロッキングな API 呼び出しを含むコアロジックを適切に待機し、結果を `TextContent` リスト形式で返却する。

### 2. 変更ファイル一覧

| ファイル | 変更種別 |
|---------|---------|
| plugins/gemini_video/plugin.py | 修正 |
| test/test_gemini_video.py | 修正 |

### 3. 変更内容サマリー

- **plugins/gemini_video/plugin.py**: 
    - `get_tools()` メソッドを実装。`analyze_video_gemini` ツールの名前、説明、引数（video_path, prompt）のスキーマを定義。
    - `execute_tool()` メソッドを実装。ツール名が `analyze_video_gemini` の場合に引数を抽出して `_analyze_video()` を呼び出す条件分岐を追加。
    - 戻り値を `mcp.types.TextContent` のリスト形式に統一（`mcp` ライブラリ未インストール時の fallback 処理も継続）。
- **test/test_gemini_video.py**:
    - `test_mcp_tool_exposure`: `get_tools()` が正しくツール定義を返すことを検証。
    - `test_mcp_tool_execution`: `execute_tool()` が正常系・異常系（引数不足）・担当外ツール名に対して期待通りに動作することを検証。

### 4. テストファイル一覧

| テストファイル | テスト件数 | テスト観点 |
|--------------|-----------|-----------|
| test/test_gemini_video.py | 2件追加 (計11件) | MCPツールの登録状況、ツール実行フロー、エラーハンドリング |

### 5. 想定リスク

- ツール名が他プラグインと重複した場合の競合（現時点では `analyze_video_gemini` と命名して衝突を回避）。
- 大規模なプロンプトや動画パスによる引数の上限（MCPプロトコルの制限に依存）。

### 6. コミットメッセージ案

feat(gemini_video): analyze_video_gemini MCPツールを公開

## 要約（200字以内）

動画解析プラグイン `gemini_video` に MCP ツール `analyze_video_gemini` を追加。`get_tools` によるツール定義の提供と `execute_tool` による実行フローを実装。既存のコアロジックを非同期で呼び出し、結果を `TextContent` 形式で返却する。追加した単体テストでツールの登録と実行（正常・異常系）が正常に動作することを確認済み。
