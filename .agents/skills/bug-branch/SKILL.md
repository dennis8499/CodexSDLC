---
name: bug-branch
version: 1.1.0
description: Bug 分支路由。使用者回報既有症狀且說不出重現步驟時，供 orchestrator 委派重現、回查原需求並確認修法與改動範圍。
---

# 症狀清楚、原因不明

orchestrator 略過 ①，依序跑 ②′ 重現、②″ 回查，再於③定案，之後依一般流程實作、審核和交付。若「正確行為」本身尚未決定，回到①的需求分析。`implementer` 執行除錯時用 skill `bug-diagnosis`。

## ②′ 建迴路、找原因

委派 `implementer`（`mode: build`，handoff 寫明「這是建迴路」）：**先建一個會紅的測試**，紅在他報的那個症狀上；紅了之後**接著找原因、提出修法，但不改 production code**。它照 skill `bug-diagnosis` 做，回來給測試 path、指令與 exit code，加上哪個假設成立、修法（檔:行、改前 → 改後）、連帶影響、要改的既有測試。**它留著**，④ 交回給它修。

**②′ 之前不得把原 spec 交給 `implementer`** —— 它會去驗證那份 spec，而不是建迴路。

- **回 `blocked` 說建不出迴路** → 照一般的 `blocked` 問使用者（缺哪筆資料、要哪個環境）。
- **迴路紅了、原因還沒找到**（`partial`）→ ③ 先確認迴路；修法等它在 ④ 找到原因、改 production code 之前回來時再問（同 ③ 的第 2 題）。

## ②″ 回查原需求

迴路紅了之後、進 ③ 之前，**你自己查，不問使用者**：從紅測試的 path 出發，`grep -rn 'feature-id:' --include=*.feature` 找出是哪份需求做的，**只讀**那份 `spec.md` 的 Gherkin 區塊、「驗收層」那一行與「交付」各節。

**一次 grep 沒中就停手**，寫進「風險與待確認」直接進 ③ —— **絕不為它多問一輪**。

## ③ 定案

那個紅測試就是驗收條件（**它轉綠 ＝ 完成**）。`spec.md` 的寫法見 skill `spec-authoring` 的「兩個例外」。同一個確認點問：

1. **「它紅的，是不是你講的那件事」**
2. **修法與改動範圍** —— 照 `implementer` 回的修法寫進 `spec.md` 的「改動範圍」，原樣列出來問「這樣修可以嗎」，**不標建議**。修起來會改到別的既有行為、或要改既有測試的期望值 → 在這一題明說。**修法不只一種、各有取捨** → 那時才跑一次正常的 ②，回來照 ③ 選。

②″ 查到原 spec 的話**同一次順帶問**：原 scenario 的期望值跟他現在報的症狀一不一樣？**一樣 ＝ 當初就是這樣定的，不是 bug** —— 那是需求變更，回 ① 走迭代，④⑤ 整段省掉（②′ 那個 `implementer` 就關掉）。

## ④ 修

**`send_input` 交回 ②′ 那個 `implementer`**（訊息照 handoff 格式寫：`mode: build`、`feature-id`、同一份 `spec.md` path；它已經關了才新 spawn），照 ③ 核准的改動範圍修。原因在 ④ 才找到 → 它改 production code 之前會先回 `partial` 報修法：照 ③ 的第 2 題問他，寫進 `spec.md` 再交回。
