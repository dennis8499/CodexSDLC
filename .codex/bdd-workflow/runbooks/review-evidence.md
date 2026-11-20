# 審查登記與交付

從安裝工作流的目錄執行。以下為 PowerShell 7 用法。把範例中的需求、路徑和收據換成本次值。保存指令回傳的 ID，依 `-Json` 結果與退出碼處理下一步。

## 審規格與登記核准

需要規格就緒審查時，orchestrator 在請使用者核准前登記開始，再將草案路徑與 `review_id` 給 `reviewer` 的 `spec` 模式。Reviewer 將結果寫入 `spec-review.md`。有引用的契約或資料表設計時，開始審查及核准都帶同一組 `-Contract` 路徑。

```powershell
$review = & ./.codex/scripts/review-check.ps1 -Action Start -Mode spec -FeatureId order-cancel -Json | ConvertFrom-Json
# Reviewer 寫完 spec-review.md 後
& ./.codex/scripts/review-check.ps1 -Action Complete -FeatureId order-cancel -ReviewId $review.review_id -Json
```

第③步核准後、實作前登記已核准的規格。範圍包含各 repo 的實作與測試路徑。路徑相對於工作流目錄，子目錄以 `/` 結尾。影響跨端契約、資料遷移、金額或授權時，風險填 `high`。其餘依需求填 `general` 或 `low`。採規格審查時加 `-SpecReviewId`，指向對應草案已完成的 PASS。做法、條件、範圍或引用內容改動後，重走相關審查及核准，重新登記。

```powershell
& ./.codex/scripts/review-check.ps1 -Action Approve -FeatureId order-cancel -Risk general -Scope @('backend/src/', 'backend/tests/', 'frontend/src/', 'frontend/tests/') -Json
```

## 審實作

```powershell
$review = & ./.codex/scripts/review-check.ps1 -Action Start -Mode code -FeatureId order-cancel -Json | ConvertFrom-Json
# Reviewer 寫完 review.md 後
& ./.codex/scripts/review-check.ps1 -Action Complete -FeatureId order-cancel -ReviewId $review.review_id -Json
```

- Orchestrator 把 `review_id`、實際受審範圍、測試證據和 `changed_files` 所列的變動給獨立 reviewer。Reviewer 在報告首段加 `REVIEW-ID: <review_id>` 和 `VERDICT: PASS` 或 `VERDICT: FAIL`。
- 每項新必修用未出現在 `issue_ids` 的 `R-1`、`R-2` 等 ID。必修沿用原 ID，`required_ids` 逐項寫明待修、附證據的已修、或使用者同意的接受不修。已處置的發現保留在現有報告的「歷史發現」。
- 登記完成後若規格或受審檔案變動，依交付檢查訊息補審變動範圍。審查前後版本一致才可完成登記。進行中的舊案在交付前補登記適用的核准，重跑一次程式碼審查，並為延續中的必修配置 ID。
- 中斷或未完成時，以 `-Action Complete -ReviewId <id> -Incomplete` 登記該次嘗試。

## 逐項接受風險

使用者接受本輪某項必修時，在 `spec.md` 寫決定引用及涵蓋的 ID。保留該次審查結論。

```markdown
## 風險決議

- accept-risk: <review_id> R-1 | 使用者當次決定摘要及理由

## 交付 —— <日期>

- review-version: <review_id>
- [R-1] 該項已接受的殘留風險
```

同一次接受多項時，每個 ID 各寫一筆。驗證、待人工驗證和其他殘留風險亦寫在最新的交付段落，完成後執行 `delivery-check.ps1`。

## 經同意採最小審核

僅用於一般需求的同一受審版本連續兩次獨立程式碼審查中斷或未完成。保留兩次嘗試，檢查測試是否實際驗到驗收條件，處置既知必修，並取得當次使用者明確同意。已完成的 FAIL 走逐項處置。

在 `spec.md` 登記後，以 `-Action Start -Mode minimal` 取得 `review_id`，寫有該 ID 的 `review.md`，完成後登記。最低條件已具備時用 `VERDICT: PASS` 完成這份最小審核。

```markdown
## 最小審核

- attempts: <first_review_id>, <second_review_id>
- checked: 查過的實作與測試
- remaining-risk: 未覆蓋的風險
- decision: 當次使用者同意的引用及摘要
```

在最新的交付段落寫「經同意採最小審核」，附上查驗、未覆蓋的風險及既知必修處置。高風險需求走獨立程式碼審查。交付檢查讀取 `reviews/` 的最小紀錄，重新開啟會話及缺少 Codex hooks 時也從這裡續跑。
