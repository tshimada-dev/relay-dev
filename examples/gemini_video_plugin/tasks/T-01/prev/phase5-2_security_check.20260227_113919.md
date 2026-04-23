# Phase5-2 セキュリティチェック報告書: gemini_video_plugin (T-01)

| 項目 | 判定 | 攻撃シナリオの検討 → 判定根拠 | 修正案 |
|------|------|------|--------|
| SQLインジェクション | N/A | 本プラグイン（T-01）においてデータベースアクセスを行う処理は存在しない。 | — |
| コマンドインジェクション | OK | `plugin.py` 全体を走査し、`subprocess`, `os.system`, `exec`, `eval` 等の外部コマンド実行や動的コード実行を伴う関数呼び出しがないことを確認。 | — |
| XSS | N/A | 本プラグインは MCP サーバーのバックエンドとして動作し、HTML レンダリングやブラウザへの直接出力を伴うパスは存在しない。 | — |
| 認証バイパス | OK | 攻撃: `api_key` なしでプラグインを動作させる。判定: `GeminiVideoConfig` で `api_key` を必須項目（`Field(...)`）として定義しており、`initialize()` 時の Pydantic バリデーションで不正な設定を拒否している。 | — |
| 権限昇格 | N/A | 現時点ではユーザーロールや認可制御の概念が本プラグイン内に存在しない。 | — |
| セッション管理 | N/A | セッションや Cookie を使用する処理は存在しない。 | — |
| 機密データの平文保存 | **NG** | 攻撃: メモリダンプやデバッグツール経由での奪取。判定: `api_key` が `str` 型としてメモリ上に保持されている。Pydantic の `SecretStr` 等を使用していないため、不注意なログ出力やデバッグ表示で露出するリスクがある。 | `api_key` の型を `pydantic.SecretStr` に変更し、露出を抑制する。 |
| ログへの機密情報出力 | OK | `plugin.py:54` にて `logger.info` でモデル名を出力しているが、`api_key` は含まれていない。他の箇所でも `api_key` をログ出力するコードはない。 | — |
| 不要なデータ露出 | **NG** | 攻撃: MCPツール経由での設定取得。判定: `BasePlugin.get_device_info` は `model_dump()` を使用してデバイス設定を全出力する。`GeminiDeviceConfig` に `api_key` を含めた場合、ツール実行結果として平文の API キーが露出する。 | `GeminiDeviceConfig` の `api_key` フィールドに `Field(exclude=True)` を指定するか、`SecretStr` を使用する。 |
| デフォルト資格情報 | OK | `config/config.yaml_sample` において `YOUR_API_KEY` というプレースホルダが使用されており、実際のキーは含まれていない。 | — |
| デバッグモード残存 | OK | コード内に `pdb`, `breakpoint`, `print` 文などのデバッグ用コードが残存していないことを確認。 | — |
| 不要なエンドポイント露出 | OK | `get_tools()` が空リストを返すよう実装されており、不要な機能が MCP 経由で公開されていない。 | — |
| 既知脆弱性ライブラリ | OK | `google-generativeai>=0.5.0` は比較的新しく、既知の重大な脆弱性は報告されていない。他の依存関係も標準的なライブラリの最新版に近い。 | — |
| ライセンス互換性 | OK | `google-generativeai` は Apache License 2.0 であり、商用利用を含め本プロジェクトとの互換性に問題はない。 | — |
| **DoS (メモリ消費)** | **NG** | 攻撃: 大量のデバイス追加。判定: `add_device` において、登録可能なデバイス数や、`device_config` のサイズに対する制限が一切ない。悪意のあるツール呼び出しにより、メモリを枯渇させることが可能。 | デバイス登録数に上限（例: 100個）を設ける、または設定オブジェクトのサイズ制限を検討する。 |

### 総合判定

**Reject**

NG 3件: `api_key` の機密保持（SecretStr 未使用）、`get_device_info` による API キー露出のリスク、およびデバイス登録時の DoS 対策不足が確認された。特に API キーの露出は重大な脆弱性につながるため、Phase 5 へ差し戻し、修正を求める。

### Reject詳細

- 原因分類: 実装不備
- 差し戻し先: Phase5
- 根拠: APIキーが平文 `str` で扱われており、`model_dump()` 等を通じて外部（MCPツール応答など）に露出する設計上の欠陥がある。
- 修正指示:
  1. `GeminiVideoConfig` および `GeminiDeviceConfig` の `api_key` フィールドを `pydantic.SecretStr` 型に変更すること。
  2. `add_device` において、極端に多くのデバイスが登録されないよう上限を設けること。
  3. `BasePlugin.get_device_info` が `api_key` を返さないよう、`GeminiDeviceConfig` で `exclude=True` 設定を検討すること。

## 要約（200字以内）
T-01セキュリティチェック：Reject。APIキーが平文str型で保持されており、BasePluginの共通処理（model_dump）経由でMCPツール等に露出するリスクがある。また、add_deviceに登録上限がなく、大量のデータ送信によるDoS（メモリ枯渇）攻撃が可能。機密情報のSecretStr化、露出防止設定、およびデバイス数の制限を実装するためPhase 5へ差し戻す。
