# relay-dev examples

このディレクトリには、現行アーキテクチャの `runs/<run-id>/artifacts/...` から抽出し、公開用に sanitize した examples だけを置く方針です。

公開用 example の条件:

- `example-manifest.json` を持つ
- raw `runs/`、provider job logs、ローカル絶対パス、secrets を含まない
- 主要 Markdown artifacts と JSON artifacts が揃っている
- validator status、redaction notes、成果指標が確認できる

`gemini_video_plugin/` はリファクタ前の旧成果物であり、portfolio の主証拠としては使いません。現行 run 由来の flagship example を追加した後に置換します。
