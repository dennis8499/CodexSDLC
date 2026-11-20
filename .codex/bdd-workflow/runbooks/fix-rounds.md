# 額外修正輪與委派收據

正常修正輪用完且最新獨立程式碼審查仍為 FAIL 時，由使用者決定要修的必修 ID。取得當次明確同意後，把決定寫入 `spec.md`。範例是迭代 1、正常上限 3 時的第 4 輪。

## 修正授權

```json
{
  "feature_id": "order-cancel",
  "iteration": 1,
  "review_id": "<當前失敗的程式碼審查 ID>",
  "round": 4,
  "issue_ids": ["R-1", "R-2"],
  "decision": "<使用者當次決定的引用及摘要>"
}
```

在 `spec.md` 以 `## 修正授權` 標題及其下的 JSON 區塊登記。每個迭代可用一次，限第 `M+1` 輪。額外輪 handoff 比照正常修正輪，帶 `feature-id`、`mode: fix`、`round`、`spec`，另加 `- issue-ids: R-1, R-2`。列出本次要修的 ID，都須在決定範圍內。

## 正式委派

啟用的 Codex hook 會在正式送出前登記。無 hooks 時，把同一份 handoff 透過 stdin 交給 `handoff-lint.ps1 -SelfCheck -Register`，成功後才送出。只預覽用 `-SelfCheck`，可加 `-Json` 取結構化結果。照登記結果保存收據及嘗試 ID。

執行端確認結果後，把事件參考和送出狀態記入這一筆收據。

```powershell
& ./.codex/scripts/handoff-lint.ps1 -SelfCheck -FeatureId order-cancel -ReceiptId <receipt_id> -AttemptId <attempt_id> -DispatchStatus Sent -DispatchEvidence <task_or_event_reference>
```

中斷後以原 handoff 跑 `-SelfCheck -Json` 讀回待確認的額外輪收據，依收據內的工作階段、回合及工具呼叫 ID 查原任務。已送出時標 `Sent` 並續接。確認未送出時標 `NotSent`，保留確認證據後以原收據重試。狀態不明先等待或查證。送出狀態由執行端確認。
