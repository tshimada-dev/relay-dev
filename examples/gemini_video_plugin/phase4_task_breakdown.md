# Phase4 実装タスク分解: gemini_video プラグイン追加

## 入力
- `outputs/gemini_video_plugin/phase3_design.md`
- `outputs/gemini_video_plugin/phase3-1_design_review.md`

## Phase4 Task List:

[T-01]
目的: プラグインのディレクトリ構造を作成し、設定情報を読み込める状態にする。
変更対象ファイル:
  - `plugins/gemini_video/__init__.py`（新規作成）
  - `plugins/gemini_video/plugin.py`（新規作成: Skeleton実装）
  - `requirements.txt`（修正: google-generativeai を追加）
  - `config/config.yaml_sample`（修正: gemini_video セクションの追加）
実装内容:
  - `plugins/gemini_video/` ディレクトリ作成。
  - `GeminiVideoPlugin` クラスを定義し、`BasePlugin` を継承。
  - Pydantic を使用して `GeminiVideoConfig` モデル（api_key, model, timeout）を実装。
  - `initialize()` および `add_device()` で設定のバリデーションと保持を実装。
受け入れ条件:
  - `requirements.txt` に `google-generativeai` が含まれている。
  - 偽の設定データで `initialize()` を呼び出し、Pydantic によるバリデーションエラーが発生すること。
  - 正しい設定データで `initialize()` が成功し、インスタンスが生成されること。
動作確認手順:
  - `pip install -r requirements.txt` を実行。
  - 簡易的なスクリプトで `GeminiVideoPlugin` をインポートし、`initialize()` を呼び出してログを確認。
依存関係: なし
テスト内容: ユニットテスト（設定モデルのバリデーション確認）。
複雑度: S（理由: 既存のプラグイン構成パターンの再利用）

[T-02]
目的: Gemini API を使用した動画解析のコアロジックを実装する。
変更対象ファイル:
  - `plugins/gemini_video/plugin.py`（修正: 解析ロジック追加）
実装内容:
  - サポート対象拡張子（.mp4, .mov, .avi 等）の事前バリデーションを実装（Reviewer指摘事項3）。
  - `genai.upload_file()` を使用したアップロード処理の実装。
  - ステータスが `ACTIVE` になるまでのポーリング処理を実装し、最大試行回数/タイムアウトを設ける（Reviewer指摘事項2）。
  - `model.generate_content()` による解析要求。
  - `finally` ブロックで `file.delete()` を確実に実行し、API側のリソースを削除する（Reviewer指摘事項1）。
  - ネットワークエラー、認証エラー、クォータ制限の例外ハンドリング。
受け入れ条件:
  - 指定されたパスのファイルが存在しない場合に適切なエラーメッセージが返ること。
  - サポート外の拡張子の場合にアップロード前にエラーを返すこと。
  - 解析の成功・失敗に関わらず、アップロードされたファイルが API 側で削除されること（ログで確認）。
動作確認手順:
  - `loguru` の出力で、アップロード開始、ステータス遷移、解析結果、削除完了の各フェーズが記録されていることを確認。
依存関係: T-01
テスト内容: ユニットテスト（拡張子チェック）、モックを使用した API 呼び出しフローの検証。
複雑度: M（理由: 外部 SDK 連携、非同期待機、例外処理、リソース管理）

[T-03]
目的: MCP ツール `analyze_video_gemini` を公開し、外部から解析を実行可能にする。
変更対象ファイル:
  - `plugins/gemini_video/plugin.py`（修正: `get_tools`, `execute_tool` 実装）
実装内容:
  - `get_tools()` で `analyze_video_gemini` ツールの定義（name, description, inputSchema）を返す。
  - `execute_tool()` でツール名に応じた条件分岐を実装し、T-02 で実装したコアロジックを呼び出す。
  - blocking な API 呼び出しを `asyncio.to_thread()` でラップして非同期実行に対応。
  - 結果を `types.TextContent` のリスト形式で返却。
受け入れ条件:
  - `get_tools()` の戻り値に `analyze_video_gemini` が含まれている。
  - `execute_tool()` に担当外のツール名が渡された場合、`None` を返すこと。
  - 正常なツール呼び出しに対して、Gemini からの結果を含む `TextContent` が返ること。
動作確認手順:
  - `test/test_mcp.py` のような形式でプラグインを直接操作し、ツールの登録状況と実行結果を確認。
依存関係: T-02
テスト内容: 統合テスト（ツール実行フロー全体）。
複雑度: S（理由: プロジェクト標準の `execute_tool` パターンの実装）

[T-04]
目的: 開発者向けのテストスクリプトを作成し、プラグインの品質を保証する。
変更対象ファイル:
  - `test/test_gemini_video.py`（新規作成）
実装内容:
  - `unittest.mock` を使用して Gemini API (google-generativeai) をモック化。
  - 正常系: 動画アップロード → ACTIVE待機 → 解析成功 → ファイル削除 のフロー。
  - 異常系: ファイル不在、API 認証エラー、タイムアウト。
  - `loguru` のログ出力を確認し、意図したメッセージが記録されているか検証。
受け入れ条件:
  - `python test/test_gemini_video.py` を実行して全てのテストケースがパスすること。
動作確認手順:
  - `python test/test_gemini_video.py` を実行。
依存関係: T-03
テスト内容: 網羅的なユニット・統合テスト。
複雑度: M（理由: 外部 API の複雑なモック化が必要）

---
## クリティカルパス:
T-01 → T-02 → T-03 → T-04

## 並列実行可能グループ:
なし（新規プラグイン開発のため、基本は直列依存）

## 並行実装可能（複雑度S）:
Batch S1: T-01, T-03 (T-01完了後に T-02/T-03 をまとめて実装可能だが、順序としては直列推奨)

## 要約（200字以内）
Gemini 動画解析プラグインを4タスクに分解。T-01 で基盤と設定、T-02 で API 連携コアロジック（リソース削除の保証、タイムアウト、拡張子チェック含む）、T-03 で MCP ツール公開、T-04 でモックを用いた包括的テストを実装する。Reviewer指摘の `finally` による削除保証やポーリング制御を T-02 に集約し、品質を確保する。
