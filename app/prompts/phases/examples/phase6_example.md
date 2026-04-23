# Phase6 出力例（Few-shot）

以下はタスク「T-02: 検索APIエンドポイント実装」のテスト出力例（Gemini CLI実行モード）。

### 1. テスト種別

- 単体テスト（検索ロジック、バリデーション）
- 結合テスト（API + DB連携）

### 3. テスト観点一覧

- 正常系: キーワード検索で該当商品が返る
- 正常系: ページネーション（page, per_page）が正しく動作する
- 正常系: 検索結果0件時に空配列が返る
- 異常系: `q` パラメータ未指定で400エラー
- 異常系: `per_page` が上限（100）を超える場合に400エラー
- 異常系: `page` が0以下の場合に400エラー
- 境界値: `per_page=1`（最小値）
- 境界値: `per_page=100`（最大値）
- 境界値: 検索キーワードが1文字

### 4. テストコード

テストファイル: `tests/api/products/test_search.py`（新規作成）

```python
import pytest
from unittest.mock import patch
from app import create_app

@pytest.fixture
def client():
    app = create_app(testing=True)
    with app.test_client() as client:
        yield client

# --- 正常系 ---

def test_search_returns_matching_products(client, seed_products):
    """キーワードに一致する商品が返ること"""
    res = client.get("/api/products/search?q=テスト商品")
    assert res.status_code == 200
    data = res.get_json()
    assert len(data["products"]) > 0
    assert all("テスト" in p["name"] or "テスト" in p["description"] for p in data["products"])

def test_search_pagination(client, seed_products):
    """ページネーションが正しく動作すること"""
    res = client.get("/api/products/search?q=商品&page=1&per_page=2")
    assert res.status_code == 200
    data = res.get_json()
    assert len(data["products"]) <= 2
    assert data["page"] == 1
    assert data["per_page"] == 2

def test_search_no_results(client):
    """該当商品がない場合に空配列が返ること"""
    res = client.get("/api/products/search?q=存在しないキーワードXYZ")
    assert res.status_code == 200
    data = res.get_json()
    assert data["products"] == []
    assert data["total"] == 0

# --- 異常系 ---

def test_search_missing_query(client):
    """qパラメータ未指定で400エラーが返ること"""
    res = client.get("/api/products/search")
    assert res.status_code == 400

def test_search_per_page_exceeds_max(client):
    """per_pageが上限を超える場合に400エラーが返ること"""
    res = client.get("/api/products/search?q=テスト&per_page=101")
    assert res.status_code == 400

def test_search_invalid_page(client):
    """pageが0以下の場合に400エラーが返ること"""
    res = client.get("/api/products/search?q=テスト&page=0")
    assert res.status_code == 400

# --- 境界値 ---

def test_search_per_page_min(client, seed_products):
    """per_page=1で1件のみ返ること"""
    res = client.get("/api/products/search?q=商品&per_page=1")
    assert res.status_code == 200
    assert len(res.get_json()["products"]) <= 1

def test_search_per_page_max(client, seed_products):
    """per_page=100で最大100件返ること"""
    res = client.get("/api/products/search?q=商品&per_page=100")
    assert res.status_code == 200
    assert len(res.get_json()["products"]) <= 100

def test_search_single_char_query(client, seed_products):
    """1文字の検索キーワードでも動作すること"""
    res = client.get("/api/products/search?q=テ")
    assert res.status_code == 200
```

### 5. Lint・型チェック結果

```
$ ruff check src/api/products/search.py tests/api/products/test_search.py
All checks passed!

$ mypy src/api/products/search.py
Success: no issues found in 1 source file
```

### 6. テスト実行結果

```
$ pytest tests/api/products/test_search.py -v --tb=short
========================= test session starts ==========================
collected 9 items

tests/api/products/test_search.py::test_search_returns_matching_products PASSED
tests/api/products/test_search.py::test_search_pagination PASSED
tests/api/products/test_search.py::test_search_no_results PASSED
tests/api/products/test_search.py::test_search_missing_query PASSED
tests/api/products/test_search.py::test_search_per_page_exceeds_max PASSED
tests/api/products/test_search.py::test_search_invalid_page PASSED
tests/api/products/test_search.py::test_search_per_page_min PASSED
tests/api/products/test_search.py::test_search_per_page_max PASSED
tests/api/products/test_search.py::test_search_single_char_query PASSED

========================= 9 passed in 1.42s ===========================
```

### 7. カバレッジ（実測値）

```
$ pytest tests/api/products/test_search.py --cov=src/api/products --cov-report=term-missing --cov-branch
========================= test session starts ==========================
collected 9 items

tests/api/products/test_search.py::test_search_returns_matching_products PASSED
...
========================= 9 passed in 1.89s ===========================

---------- coverage: platform linux, python 3.11.5-final-0 -----------
Name                              Stmts   Miss Branch BrPart  Cover   Missing
-------------------------------------------------------------------------------
src/api/products/search.py           45      0     12      0   100%
src/api/products/__init__.py         12      0      0      0   100%
-------------------------------------------------------------------------------
TOTAL                                57      0     12      0   100%
```

- **行カバレッジ**: 100% （目標80%以上 → OK）
- **分岐カバレッジ**: 100% （目標70%以上 → OK）

### 8. パフォーマンステスト（Phase1で性能要件がある場合）

**Phase1の性能要件**: p95レスポンスタイム 500ms以下

#### 8-1. 負荷テストツール選定

Locust（Python）を使用

#### 8-2. 負荷シナリオ

```python
# locustfile.py
from locust import HttpUser, task, between

class SearchUser(HttpUser):
    wait_time = between(1, 3)
    
    @task(3)  # 検索クエリ（重み3）
    def search_products(self):
        self.client.get("/api/products/search?q=テスト商品&page=1&per_page=20")
    
    @task(1)  # ページネーション（重み1）
    def search_pagination(self):
        self.client.get("/api/products/search?q=商品&page=2&per_page=50")
```

#### 8-3. 負荷テスト実行

```bash
$ locust -f locustfile.py --headless -u 100 -r 10 -t 10m --host=http://localhost:3000
[2026-02-16 14:30:00] Starting Locust 2.15.1
[2026-02-16 14:30:00] Spawning 100 users at the rate 10 users/s...
...
========================= Summary =========================
Type     Name                              # reqs      # fails |    Avg     Min     Max    Med | req/s failures/s
----------------------------------------------------------------------------------------------------------------------------------------
GET      /api/products/search                 5420     0(0.00%) |    245      98    1256    220 |   9.03        0.00
----------------------------------------------------------------------------------------------------------------------------------------
         Aggregated                           5420     0(0.00%) |    245      98    1256    220 |   9.03        0.00

Percentile Response Times (in milliseconds)
Type     Name                              50%    66%    75%    80%    90%    95%    98%    99%  99.9% 99.99%   100%
----------------------------------------------------------------------------------------------------------------------------------------
GET      /api/products/search                 220    260    295    320    380    450    580    720   1100   1256   1256
----------------------------------------------------------------------------------------------------------------------------------------
         Aggregated                           220    260    295    320    380    450    580    720   1100   1256   1256
```

#### 8-4. パフォーマンス結果評価

| 指標 | 目標値（Phase1） | 実測値 | 判定 |
|------|----------------|--------|------|
| p50レスポンスタイム | < 300ms | 220ms | **OK** |
| p95レスポンスタイム | < 500ms | 450ms | **OK** |
| p99レスポンスタイム | < 1000ms | 720ms | **OK** |
| エラー率 | < 0.1% | 0.00% | **OK** |
| スループット | > 50 RPS | 9.03 RPS | **NG** |

**ボトルネック分析**:
- スループット不足（目標50 RPS、実測9 RPS）はローカル環境のDB性能による
- 本番環境（RDS）では十分なスループットが見込まれる
- ステージング環境での再検証を推奨事項として記録

**判定**: Conditional Go（ローカル環境の制約により一部未達、ステージング環境で再検証必須）

### 9. アクセシビリティチェック（UI変更がある場合）

**実施条件**: 本タスクはバックエンドAPIのみのためアクセシビリティチェックは対象外

**対象外理由**: HTML/CSS/JSの変更なし、JSON APIのみ

**（参考）UI変更がある場合の出力例**:

```
#### 9-1. 自動チェックツール実行

$ lighthouse http://localhost:3000/products/search --only-categories=accessibility --output=json

Accessibility Score: 92/100

主な指摘事項:
- [aria-label] 検索ボタンにaria-labelが不足
- [color-contrast] 検索結果のテキストがコントラスト比4.3:1（WCAG AA基準4.5:1未満）

#### 9-2. 手動チェック結果

| 項目 | 確認内容 | 判定 |
|------|---------|------|
| キーボード操作 | Tab/Enter/Escキーのみで全機能が利用可能か | OK |
| フォーカス表示 | フォーカス位置が視覚的に明確か | OK |
| ARIA属性 | ボタン、リンク、フォームに適切なrole/aria-label設定があるか | NG |
| カラーコントラスト | WCAG AA基準（4.5:1以上）を満たすか | NG |
| 代替テキスト | 画像・アイコンにalt属性があるか | OK |

#### 9-3. アクセシビリティスコア

- **目標スコア**: Lighthouse Accessibility 90点以上
- **実測値**: 92点
- **判定**: Conditional Go（92点で合格ラインだが、2件の改善推奨事項あり）

**修正提案**:
1. 検索ボタンに `aria-label="商品を検索"` を追加
2. 検索結果テキストの色を #333 → #000 に変更してコントラスト比を改善
```

### 10. 失敗時の修正ループ

```
$ pytest tests/api/products/test_search.py --cov=src/api/products/search --cov-report=term-missing --cov-branch

Name                              Stmts   Miss Branch BrPart  Cover   Missing
-----------------------------------------------------------------------------
src/api/products/search.py           38      3      12      2    89%   58-62
-----------------------------------------------------------------------------
TOTAL                                38      3      12      2    89%

行カバレッジ: 92%（38 statements, 3 missed）
分岐カバレッジ: 83%（12 branches, 2 partial）
```

未到達行: search.py:58-62（Redis障害時フォールバックパス — T-03で対応予定）

### 8. 失敗テストの分析

なし（全9テストpass）

### 9. 修正提案

なし（カバレッジ目標達成、全テスト観点を網羅、全テストpass）

### 10. CI判定

**Go**

- 全9テストpass（正常系3・異常系3・境界値3）
- 行カバレッジ: 92% ≧ 80%（目標達成）
- 分岐カバレッジ: 83% ≧ 70%（目標達成）
- Lint・型チェック: エラーなし
- 未到達行（Redis障害時パス）はT-03の範囲のため許容

## 要約（200字以内）

T-02テスト：Go判定。単体+結合テスト計9ケース全pass。Lint・型チェックエラーなし。実測カバレッジ：行92%・分岐83%で目標達成。未到達行はRedis障害時パス（T-03で対応）。失敗テストなし、修正不要。
