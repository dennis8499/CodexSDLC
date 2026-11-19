# 資料來源

需求要用到、又不是這個功能自己產生的資料 —— 畫面、報表、API、匯出檔上的欄位，計算的輸入，在排做法前逐項對到來源。

- **去哪對**：表與欄位、既有的 client／SDK 呼叫、設定檔的 key（`ConnectionStrings`、`BaseUrl` 這類；索引只記 key 名、不記值）、匯入檔的 parser、SP 裡跨庫或 linked server 的查詢（多段式名稱、`OPENQUERY`）。需求決議指了文件或樣本的 path → 讀它，對到裡面的欄位。
- **一次 `impact-scope.ps1` 帶上全部資料項的關鍵字**（業務詞 ＋ 可能的程式名），命中的再開檔確認；沒命中的，再各看一次設定 key 與外部 client。還對不到 → 「來源待確認」，寫明查過什麼。**不要換關鍵字一直找** —— repo 外的系統是無界的，問人比你找便宜。
- **對到不只一處**（客戶名稱 CRM 有、ERP 也有）→ 都列出來；以哪個為準是業務決策，寫成「需求缺口：」。
- **需求決議標了「待定」的不算待確認** —— 那是使用者決定先不定，將使用者尚未決定的條件寫進受影響做法的「風險」。

一個來源一行：

```text
## 資料來源
- `orders.total_amount`（Order.cs:31）← 訂單金額
- `ErpClient.GetCreditLimit`（ErpClient.cs:58；設定 key `Erp:BaseUrl`）← 信用額度
- 物流商 `GET /tracking/{no}`（docs/logistics-api.md:40）← 物流狀態、預計到貨日
- 來源待確認：匯率 —— 查過 impact-scope「匯率,ExchangeRate,Currency」、設定 key、`*.sql`
```

`current-state.md` 已經有這一節 → 對到的直接採信，標「來源待確認」的看需求決議怎麼答。需求沒有這種資料 → 回傳寫「資料來源：無」就結束。

**在 `analyze`，還有「來源待確認」就先交回 ①。**照 `mode: survey` 的格式把查到的現況連同這一節寫進 `bdd-docs/{feature-id}/current-state.md`（已經在就只更新這一節；這時不寫 `analysis.md`），回 `blocked`，「風險與待確認」一項一行：`來源待確認：匯率 —— 查過 …`。orchestrator 會回 ① 問他。

**在 `survey`**，照樣把「來源待確認」寫進 `current-state.md`。撞到精讀上限而來不及查的放進「沒查到」，避免把仍可在 repo 查明的事項丟給使用者。
