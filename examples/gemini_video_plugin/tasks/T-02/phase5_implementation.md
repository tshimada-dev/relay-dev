## 差し戻し対応（Phase5-2より）

Phase 5-2 セキュリティチェックにて指摘された脆弱性を修正した。

1. **Path Traversal 対策**: 
   - `_is_safe_path` メソッドを追加し、`Path.resolve()` を使用して入力パスが許可されたベースディレクトリ（`allowed_base_dirs`）内にあることを厳密にチェックするようにした。
   - `GeminiVideoConfig` に `allowed_base_dirs` 設定を追加。デフォルトではカレントディレクトリ配下のみを許可する。
2. **機密情報のログ出力防止**:
   - `logger.info` で出力していたプロンプトを先頭50文字に切り詰める処理を追加した。
3. **リソース枯渇 (DoS) 対策**:
   - `GeminiVideoConfig` に `max_file_size_mb` 設定を追加し、アップロード前にファイルサイズをチェックするようにした。デフォルト上限は100MB。
4. **情報の露出防止**:
   - エラーメッセージからシステムのフルパスを除去し、ファイル名のみを表示するように変更した。

### 1. 実装概要

Gemini Videoプラグインのコアロジック（T-02）におけるセキュリティ強化とバグ修正を実施。指摘された脆弱性（Path Traversal, 情報漏洩, DoS）をすべて解消し、安全に動画解析を実行できる状態にした。

### 2. 変更ファイル一覧

| ファイル | 変更種別 |
|---------|---------|
| plugins/gemini_video/plugin.py | 修正 |
| config/config.yaml_sample | 修正 |
| test/test_gemini_video.py | 修正 |

### 3. 変更内容サマリー

- **plugins/gemini_video/plugin.py**:
  - `GeminiVideoConfig` モデルに `allowed_base_dirs` と `max_file_size_mb` を追加。
  - `_is_safe_path` メソッドの実装によるパスのサンドボックス化。
  - `_analyze_video` メソッドにパスバリデーション、ファイルサイズチェック、プロンプト切り詰めログ、クリーンなエラーメッセージ出力を追加。
- **config/config.yaml_sample**:
  - `gemini_video` セクションにセキュリティ設定のサンプルを追加。
- **test/test_gemini_video.py**:
  - 新規追加したセキュリティチェック（パスバリデーション、ファイルサイズチェック）をパスするようにモックを更新。

### 4. テストファイル一覧

| テストファイル | テスト件数 | テスト観点 |
|--------------|-----------|-----------|
| test/test_gemini_video.py | 6件 | 設定、デバイス追加、DoS制限、解析フロー、拡張子チェック、タイムアウト |
| (検証用) test/test_gemini_video_security.py | 4件 | Path Traversal、ファイルサイズ、ログ保護、情報漏洩防止（実行後削除済み） |

### 5. 想定リスク

- `allowed_base_dirs` が未設定の場合、カレントディレクトリ以外の動画ファイルにアクセスできなくなる。運用に合わせて設定が必要。
- シンボリックリンクを使用している場合、`Path.resolve()` によって実体パスでチェックされるため、意図しない拒否が発生する可能性がある。

### 6. コミットメッセージ案

fix(gemini_video): implement security hardening for video analysis (T-02)

## 要約（200字以内）

Phase 5-2のセキュリティ指摘に基づき、Gemini Videoプラグインを修正。Path.resolveを用いたPath Traversal対策、ファイルサイズ上限チェック、プロンプトのログ出力制限、およびエラーメッセージからのパス情報除去を実装。config.yaml_sampleにセキュリティ設定を追加し、既存テストも新仕様に合わせて更新。セキュリティ検証テストにより、脆弱性が解消されていることを確認済み。
