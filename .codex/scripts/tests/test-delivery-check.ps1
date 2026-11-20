# test-delivery-check.ps1
# delivery-check 是 ⑥ 唯一的機械檢查：它說 OK，orchestrator 就回報交付。最危險的失效是「該紅的時候綠」——
# 漏寫一項殘留風險、最後一輪修正之後沒重跑測試、審核 FAIL 卻當成可以交付，每一種都要有一條必紅的案例。

$DcScript = (Resolve-Path '.codex/scripts/delivery-check.ps1').Path
$DcReviewScript = Join-Path (Split-Path $DcScript -Parent) 'review-check.ps1'
$DcRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-delivery-check-tests-' + [guid]::NewGuid().ToString('N'))
$DcUtf8   = [Text.UTF8Encoding]::new($false)

$DcSpecBody = @'
# cancel-order —— 客戶可以取消還沒出貨的訂單

## 驗收條件

```gherkin
# feature-id: cancel-order
Feature: 取消訂單
  Scenario: 未出貨的訂單可以取消
    Given 訂單 1001 的狀態是「已付款」
    When 客戶取消訂單 1001
    Then 訂單 1001 的狀態變成「已取消」

  Scenario: 已出貨的訂單不能取消
    Given 訂單 1002 的狀態是「已出貨」
    When 客戶取消訂單 1002
    Then 系統拒絕並顯示「已出貨的訂單不能取消」
```

驗收層：application service
'@

$DcDelivery = @'

## 交付 —— 2026-10-29

- 怎麼驗的：dotnet test（2 passed）＋ gherkin-check
- 殘留風險：無
'@

$DcFeature = @'
# feature-id: cancel-order
Feature: 取消訂單
  Scenario: 未出貨的訂單可以取消
    Given 訂單 1001 的狀態是「已付款」
    When 客戶取消訂單 1001
    Then 訂單 1001 的狀態變成「已取消」

  @regression
  Scenario: 已出貨的訂單不能取消
    Given 訂單 1002 的狀態是「已出貨」
    When 客戶取消訂單 1002
    Then 系統拒絕並顯示「已出貨的訂單不能取消」
'@

$DcReviewPass = @'
VERDICT: PASS

## 發現
1. [建議] src/Orders/CancelService.cs:12 —— 方法太長
   會怎麼壞：不會壞，只是難讀

## 沒問題的部分
測試斷言都來自驗收條件的值。
'@

$DcReviewFail = @'
VERDICT: FAIL

## 發現
1. [必修] [R-1] src/Orders/CancelService.cs:40 —— 已出貨的訂單沒有被擋下
   會怎麼壞：訂單 1002（已出貨）取消後狀態變成「已取消」
'@

function New-DcTrx([string[]]$passed) {
    $res = ''; $defs = ''; $i = 0
    foreach ($k in $passed) {
        $i++; $id = "00000000-0000-0000-0000-{0:D12}" -f $i
        $res  += "<UnitTestResult testId=""$id"" testName=""$k"" outcome=""Passed"" />"
        $defs += "<UnitTest name=""$k"" id=""$id""><TestMethod className=""Tests.CancelOrderFeature"" name=""$k"" /></UnitTest>"
    }
    return "<TestRun xmlns=""http://microsoft.com/schemas/VisualStudio/TeamTest/2010""><Results>$res</Results><TestDefinitions>$defs</TestDefinitions><ResultSummary outcome=""Completed""><Counters total=""$i"" executed=""$i"" passed=""$i"" failed=""0"" notExecuted=""0"" inconclusive=""0"" /></ResultSummary></TestRun>"
}

function Write-DcFile([string]$rel, [string]$text) {
    $p = Join-Path $DcRoot $rel
    New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($p, $text, $DcUtf8)
}

function Invoke-DcReview([hashtable]$parameters) {
    Push-Location $DcRoot
    try {
        $raw = & $DcReviewScript -FeatureId 'cancel-order' -Json @parameters
        $reviewExit = $LASTEXITCODE
        return [pscustomobject]@{ exit = $reviewExit; json = ($raw | Out-String | ConvertFrom-Json) }
    } finally { Pop-Location }
}

function Register-DcReview([string]$report, [string]$mode = 'code', [string[]]$scope = @()) {
    if ($mode -eq 'code') {
        if (-not $scope.Count) {
            $scope = @('src/Orders/CancelService.cs')
            if (Test-Path -LiteralPath (Join-Path $DcRoot 'tests/Features/CancelOrder.feature')) {
                $scope += 'tests/Features/CancelOrder.feature'
            }
        }
        $approval = Invoke-DcReview @{ Action = 'Approve'; Risk = 'general'; Scope = $scope }
        Assert-Equal 0 $approval.exit "approve: $($approval.json | ConvertTo-Json -Compress)"
    }
    $start = Invoke-DcReview @{ Action = 'Start'; Mode = $mode }
    Assert-Equal 0 $start.exit "start: $($start.json | ConvertTo-Json -Compress)"
    $script:DcReviewVersion = $start.json.review_id
    Assert-True ([bool]$script:DcReviewVersion)
    $name = if ($mode -eq 'spec') { 'spec-review.md' } else { 'review.md' }
    $parts = $report -split '\r?\n', 2
    $newline = [string][char]10
    Write-DcFile "bdd-docs/cancel-order/$name" ($parts[0] + $newline + "REVIEW-ID: $script:DcReviewVersion" + $newline + [string]$parts[1])
    return (Invoke-DcReview @{ Action = 'Complete'; ReviewId = $script:DcReviewVersion })
}

function Use-DcDeliveryTools([string[]]$omit = @(), [hashtable]$stubs = @{}) {
    $source = Split-Path $DcScript -Parent
    $fixture = Join-Path $DcRoot '.codex/scripts'
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'lib'))
    foreach ($file in @('delivery-check.ps1', 'dlp-gate.ps1', 'dlp-residual-scan.ps1', 'guideline-gate.ps1')) {
        if ($file -in $omit) { continue }
        if ($stubs.ContainsKey($file)) {
            Write-DcFile ".codex/scripts/$file" $stubs[$file]
        } else {
            Copy-Item -LiteralPath (Join-Path $source $file) -Destination $fixture
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $source 'lib') -Filter '*.ps1' -File) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $fixture 'lib')
    }
    $script:DcDeliveryPath = Join-Path $fixture 'delivery-check.ps1'
}

function Remove-DcProject {
    $path = Get-Item -LiteralPath $DcRoot -ErrorAction SilentlyContinue
    if (-not $path) { return }
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ($path.Parent.FullName -ne $temp -or $path.Name -notmatch '^codex-delivery-check-tests-[a-f0-9]{32}$' -or
        ($path.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Unexpected delivery fixture cleanup path'
    }
    Remove-Item -LiteralPath $path.FullName -Recurse -Force
}

# 一個交付得出去的專案：spec（含交付一節）、PASS 的審核、.feature、src、已 commit，結果檔比所有改過的檔新。
function New-DcProject([string]$spec = ($DcSpecBody + $DcDelivery), [string]$feature = $DcFeature, [string]$review = $DcReviewPass,
                       [string[]]$tests = @('未出貨的訂單可以取消', '已出貨的訂單不能取消'), [switch]$NoGit) {
    Remove-DcProject
    $script:DcDeliveryPath = $DcScript
    $script:DcReviewVersion = $null
    Write-DcFile 'bdd-docs/cancel-order/spec.md' $spec
    if ($feature) { Write-DcFile 'tests/Features/CancelOrder.feature' $feature }
    Write-DcFile 'src/Orders/CancelService.cs' 'class CancelService {}'
    if (-not $NoGit) {
        Push-Location $DcRoot
        try {
            git init -q 2>$null; git add -A 2>$null
            git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m base 2>$null
        } finally { Pop-Location }
    }
    if ($review) {
        $complete = Register-DcReview $review
        Assert-Equal 0 $complete.exit "complete: $($complete.json | ConvertTo-Json -Compress)"
    }
    Write-DcFile 'TestResults/run.trx' (New-DcTrx $tests)
}

function Invoke-Dc([hashtable]$extra = @{}, [switch]$NoResults) {
    Push-Location $DcRoot
    try {
        $p = @{ FeatureId = 'cancel-order'; Json = $true }
        if (-not $NoResults) { $p['TestResults'] = 'TestResults/run.trx' }
        foreach ($k in $extra.Keys) { $p[$k] = $extra[$k] }
        $r = Invoke-Script $script:DcDeliveryPath -Params $p
        $r | Add-Member -NotePropertyName json -NotePropertyValue $(try { $r.stdout | ConvertFrom-Json } catch { $null })
        $r | Add-Member -NotePropertyName codes -NotePropertyValue @($r.json.problems | ForEach-Object { $_.code })
        return $r
    } finally { Pop-Location }
}

Describe-Suite 'delivery-check / 交付得出去的那一份要綠' {

    It-Should '審核 PASS、gherkin-check 通過、交付一節寫了殘留風險 → exit 0' {
        New-DcProject
        try {
            $r = Invoke-Dc
            Assert-Equal 0 $r.exit "stdout: $($r.stdout) stderr: $($r.stderr)"
            Assert-Equal 'PASS' $r.json.review.verdict
            Assert-True $r.json.gherkin.passed
        } finally { Remove-DcProject }
    }

    It-Should '不帶 -Json：一行 OK，附「外部來源只用替身驗過」的提醒（那一項這支看不到）' {
        New-DcProject
        try {
            Push-Location $DcRoot
            try { $r = Invoke-Script $DcScript -Params @{ FeatureId = 'cancel-order'; TestResults = 'TestResults/run.trx' } } finally { Pop-Location }
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            Assert-Match '\[delivery-check\] OK' $r.stdout
            Assert-Match '替身' $r.stdout
        } finally { Remove-DcProject }
    }

    It-Should '沒有 .feature 的需求（bug 修復、沒有行為變更）不要求結果檔' {
        New-DcProject -spec "# cancel-order —— 修好取消按鈕`n`n回歸測試：tests/CancelTests.cs::已出貨不能取消`n$DcDelivery" -feature ''
        try {
            $r = Invoke-Dc -NoResults
            Assert-Equal 0 $r.exit "stdout: $($r.stdout)"
            Assert-True (-not $r.json.gherkin.applicable)
        } finally { Remove-DcProject }
    }

    It-Should '不是 git repo 也找得到 .feature' {
        New-DcProject -NoGit
        try {
            $r = Invoke-Dc
            Assert-Equal 0 $r.exit "stdout: $($r.stdout)"
            Assert-Equal 1 @($r.json.gherkin.features).Count
        } finally { Remove-DcProject }
    }
}

Describe-Suite 'delivery-check / 交付一節' {

    It-Should '沒有「## 交付」一節 → 紅' {
        New-DcProject -spec $DcSpecBody
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            Assert-True ('no-delivery-section' -in $r.codes) "codes: $($r.codes -join ',')"
        } finally { Remove-DcProject }
    }

    It-Should '最後那一節沒寫殘留風險 → 紅（「無」也要寫出來）' {
        New-DcProject -spec ($DcSpecBody + "`n## 交付 —— 2026-10-29`n`n- 怎麼驗的：dotnet test`n")
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            Assert-True ('delivery-no-risk-line' -in $r.codes) "codes: $($r.codes -join ',')"
        } finally { Remove-DcProject }
    }

    It-Should '@manual 的 scenario 沒寫進交付 → 紅；寫了「待人工驗證」→ 綠' {
        New-DcProject -feature ($DcFeature -replace '@regression', '@manual') -tests @('未出貨的訂單可以取消')
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit "stdout: $($r.stdout)"
            Assert-True ('delivery-missing-risk' -in $r.codes)
            Assert-Match '已出貨的訂單不能取消' (@($r.json.delivery.missing) -join ' ')

            Write-DcFile 'bdd-docs/cancel-order/spec.md' ($DcSpecBody + ($DcDelivery -replace '殘留風險：無', "殘留風險：`n  - 待人工驗證：已出貨的訂單不能取消"))
            $r = Invoke-Dc
            Assert-Equal 0 $r.exit "寫了還是紅；stdout: $($r.stdout)"
        } finally { Remove-DcProject }
    }

    It-Should '舊快照可保留，進行中需求須重新登記程式碼審查' {
        New-DcProject -review ''
        try {
            $legacy = $DcReviewFail -replace '\[R-1\] ', ''
            Write-DcFile 'bdd-docs/cancel-order/review.md' $legacy
            Write-DcFile 'bdd-docs/cancel-order/reviews/20261029-010000.md' $legacy
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            Assert-True ('review-evidence-required' -in $r.codes)
            Assert-Equal 0 (Register-DcReview $DcReviewPass).exit
            Assert-Equal 0 (Invoke-Dc).exit
            Assert-True (Test-Path -LiteralPath (Join-Path $DcRoot 'bdd-docs/cancel-order/reviews/20261029-010000.md'))
        } finally { Remove-DcProject }
    }

    It-Should '前幾次迭代的交付已經列過的，不必再列一次' {
        $spec = $DcSpecBody + "`n## 交付 —— 2026-10-01`n`n- 殘留風險：待人工驗證：已出貨的訂單不能取消`n`n## 迭代 2 —— 加退款`n" + $DcDelivery
        New-DcProject -spec $spec -feature ($DcFeature -replace '@regression', '@manual') -tests @('未出貨的訂單可以取消')
        try {
            $r = Invoke-Dc @{ Json = $true }
            Assert-True ('delivery-missing-risk' -notin $r.codes) "前一次交付列過的又被要求一次；codes: $($r.codes -join ',')"
        } finally { Remove-DcProject }
    }

    It-Should '八項未修必修的收據列前五項和其餘數量' {
        $lf = [string][char]10
        $lines = (1..8 | ForEach-Object { "$_. [必修] [R-$_] src/Orders/CancelService.cs:$_ —— 問題 $_" }) -join $lf
        New-DcProject -review ("VERDICT: FAIL" + $lf + '## 發現' + $lf + $lines)
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            $p = @($r.json.problems | Where-Object code -eq 'delivery-missing-risk')[0]
            Assert-Equal 5 @($p.items).Count
            Assert-Equal 3 $p.omitted
            Assert-Equal 8 @($r.json.delivery.missing).Count
        } finally { Remove-DcProject }
    }
}

Describe-Suite 'delivery-check / 審核' {

    It-Should '沒有 review.md → 紅（⑤ 沒跑過）' {
        New-DcProject -review ''
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            Assert-True ('no-review' -in $r.codes)
        } finally { Remove-DcProject }
    }

    It-Should '同檔兩項必修各列 ID，前次交付與本次單項決定都擋住' {
        $lf = [string][char]10
        $noFeatureSpec = '# cancel-order' + $lf
        $sameFile = $DcReviewFail + $lf + '2. [必修] [R-2] src/Orders/CancelService.cs:21 —— 取消按鈕未停用'
        New-DcProject -spec ($noFeatureSpec + $DcDelivery) -feature '' -review $sameFile
        try {
            $r = Invoke-Dc -NoResults
            Assert-Equal 2 $r.exit
            Assert-Equal 2 @($r.json.delivery.missing).Count
            Assert-Match 'R-1' ($r.json.delivery.missing -join ' ')
            Assert-Match 'R-2' ($r.json.delivery.missing -join ' ')

            $prior = @'

## 交付 —— 2026-10-01
- 殘留風險：舊的 CancelService.cs 問題
- [R-1] 上次的決定

'@
            Write-DcFile 'bdd-docs/cancel-order/spec.md' ($noFeatureSpec + $prior + $DcDelivery)
            $r = Invoke-Dc -NoResults
            Assert-Equal 2 $r.exit
            Assert-Equal 2 @($r.json.delivery.missing).Count

            $version = $script:DcReviewVersion
            $risk = @"

## 風險決議

- accept-risk: $version R-1 | 決議 A，接受已知風險

## 交付 —— 2026-10-29

- review-version: $version
- 殘留風險：
  - [R-1] 使用者接受風險 A
"@
            Write-DcFile 'bdd-docs/cancel-order/spec.md' ($noFeatureSpec + $risk)
            $r = Invoke-Dc -NoResults
            Assert-Equal 2 $r.exit
            Assert-Equal 1 @($r.json.delivery.missing).Count
            Assert-Match 'R-2' $r.json.delivery.missing[0]

            $accepted = $risk.Replace('## 交付', "- accept-risk: $version R-2 | 決議 B，接受已知風險" + $lf + $lf + '## 交付')
            Write-DcFile 'bdd-docs/cancel-order/spec.md' ($noFeatureSpec + $accepted + $lf + '  - [R-2] 使用者接受風險 B')
            $r = Invoke-Dc -NoResults
            Assert-Equal 0 $r.exit "stdout: $($r.stdout)"
            Assert-Equal 'FAIL' $r.json.review.verdict
            Assert-Equal $version $r.json.review.version
        } finally { Remove-DcProject }
    }

    It-Should '規格審查 PASS 仍須有當前程式碼審查' {
        New-DcProject -review ''
        try {
            Assert-Equal 0 (Register-DcReview $DcReviewPass 'spec').exit
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            Assert-True (('no-review' -in $r.codes) -or ('review-evidence-required' -in $r.codes))
        } finally { Remove-DcProject }
    }

    It-Should '無 feature 時，追加交付保留審查，改受審程式則阻擋' {
        $body = '# cancel-order' + [string][char]10
        New-DcProject -spec ($body + $DcDelivery) -feature ''
        try {
            Write-DcFile 'bdd-docs/cancel-order/spec.md' ($body + $DcDelivery + [string][char]10 + '- 已補交付說明')
            $r = Invoke-Dc -NoResults
            Assert-Equal 0 $r.exit "stdout: $($r.stdout)"
            Assert-Equal $script:DcReviewVersion $r.json.review.version

            Write-DcFile 'src/Orders/CancelService.cs' 'class CancelService { bool CanCancel = true; }'
            $r = Invoke-Dc -NoResults
            Assert-Equal 2 $r.exit
            Assert-True ('review-stale' -in $r.codes) $r.stdout
            Assert-True (-not $r.json.gherkin.applicable)
        } finally { Remove-DcProject }
    }

    It-Should 'PASS 留有必修或 FAIL 缺必修時，完成審查與交付都擋住' {
        foreach ($report in @($DcReviewFail.Replace('VERDICT: FAIL', 'VERDICT: PASS'), 'VERDICT: FAIL')) {
            New-DcProject -review ''
            try {
                $complete = Register-DcReview $report
                Assert-Equal 2 $complete.exit "complete: $($complete.json | ConvertTo-Json -Compress)"
                $r = Invoke-Dc
                Assert-Equal 2 $r.exit
                Assert-True (-not $r.json.passed)
                Assert-True (@($r.codes | Where-Object { $_ -match 'review' }).Count -gt 0)
            } finally { Remove-DcProject }
        }
    }
}

Describe-Suite 'delivery-check / 驗收條件' {

    It-Should '有 .feature 卻沒給結果檔 → 紅' {
        New-DcProject
        try {
            $r = Invoke-Dc -NoResults
            Assert-Equal 2 $r.exit
            Assert-True ('no-test-results' -in $r.codes)
        } finally { Remove-DcProject }
    }

    It-Should '最後一輪修正之後沒重跑測試（結果檔比改過的檔舊）→ 紅' {
        New-DcProject
        try {
            (Get-Item (Join-Path $DcRoot 'TestResults/run.trx')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
            Write-DcFile 'src/Orders/CancelService.cs' 'class CancelService { /* 修正輪改過 */ }'
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit 'implementer 當時的綠燈被當成現在的'
            Assert-True ('gherkin' -in $r.codes)
            Assert-Match '結果檔比這些改過的檔舊' (@(@($r.json.problems | Where-Object code -eq 'gherkin')[0].items) -join ' ')
        } finally { Remove-DcProject }
    }

    It-Should '有一條 scenario 沒有測試 → 紅' {
        New-DcProject -tests @('未出貨的訂單可以取消')
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            Assert-Match '找不到這條 scenario 的測試：已出貨的訂單不能取消' (@(@($r.json.problems | Where-Object code -eq 'gherkin')[0].items) -join ' ')
        } finally { Remove-DcProject }
    }

    It-Should 'spec 有 Gherkin、repo 裡卻找不到那個 feature-id 的 .feature → 紅' {
        New-DcProject -feature ($DcFeature -replace 'feature-id: cancel-order', 'feature-id: cancel-order-v2')
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            Assert-True ('feature-not-found' -in $r.codes) "codes: $($r.codes -join ',')"
        } finally { Remove-DcProject }
    }

    It-Should '給的結果檔不存在 → 紅，不是當成沒給' {
        New-DcProject
        try {
            $r = Invoke-Dc @{ TestResults = 'TestResults/nope.trx' }
            Assert-Equal 2 $r.exit
            Assert-True ('test-results-missing' -in $r.codes)
        } finally { Remove-DcProject }
    }
}

Describe-Suite 'delivery-check / 輸入錯誤' {

    It-Should 'feature-id 不合法（../）或找不到 spec.md → exit 1' {
        New-DcProject
        try {
            Assert-Equal 1 (Invoke-Dc @{ FeatureId = '../cancel-order' }).exit
            Assert-Equal 1 (Invoke-Dc @{ FeatureId = 'no-such-feature' }).exit
        } finally { Remove-DcProject }
    }
}

Describe-Suite 'delivery-check / 前後端分成兩個 repo、工作流裝在外層' {

    It-Should '.feature 在巢狀 repo（workspace/frontend）裡 → 找得到，照樣綠' {
        # 根目錄的 git ls-files 不會走進巢狀 repo：以前這裡永遠是 feature-not-found，⑥ 交不出去。
        New-DcProject -NoGit -review ''
        Remove-Item -LiteralPath (Join-Path $DcRoot 'tests/Features/CancelOrder.feature')
        Write-DcFile 'frontend/tests/Features/CancelOrder.feature' $DcFeature
        # 巢狀的先建：反過來的話，根目錄的 repo 會把 frontend/ 的檔當成自己的追蹤進去。
        foreach ($d in @((Join-Path $DcRoot 'frontend'), $DcRoot)) {
            git -C $d init -q 2>$null; git -C $d add -A 2>$null
            git -C $d -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m base 2>$null
        }
        Assert-Equal 0 (Register-DcReview $DcReviewPass -scope @('src/Orders/CancelService.cs', 'frontend/tests/Features/CancelOrder.feature')).exit
        Write-DcFile 'TestResults/run.trx' (New-DcTrx @('未出貨的訂單可以取消', '已出貨的訂單不能取消'))
        try {
            $r = Invoke-Dc
            Assert-True ('feature-not-found' -notin $r.codes) "巢狀 repo 裡的 .feature 沒找到：$($r.stdout)"
            Assert-Equal 0 $r.exit "stdout: $($r.stdout)"
        } finally { Remove-DcProject }
    }
}

Describe-Suite 'delivery-check / 寫檔時那兩道 gate 交付前再跑一次（hooks 跑不起來時這是最後一道）' {

    # 公司政策只允許管理員部署的 hooks 時，dlp-gate／guideline-gate 寫檔時一次都沒跑 —— 下面每一種以前都直接交付出去。

    It-Should 'bdd-docs 的產出有殘留的敏感資料 → 紅，只列類別與行號' {
        New-DcProject
        Write-DcFile 'bdd-docs/cancel-order/current-state.md' "# 現況`n`n連線：Server=db01;Initial Catalog=Orders;User Id=sa;`n"
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit "殘留沒被擋：$($r.stdout)"
            Assert-True ('dlp-residual' -in $r.codes) "codes: $($r.codes -join ',')"
            $items = @(@($r.json.problems | Where-Object code -eq 'dlp-residual')[0].items) -join ' '
            Assert-Match 'current-state\.md' $items
            Assert-True ($items -notmatch 'db01') "收據把敏感值本身印出來了：$items"
            Assert-Equal 'failed' $r.json.gates.dlp
        } finally { Remove-DcProject }
    }

    It-Should '這次改過的檔違反 block 規則 → 紅；沒改過的舊檔裡的違規不算' {
        New-DcProject
        Write-DcFile 'guidelines/rules.json' '{ "rules": [ { "id": "no-nolock", "applies-to": ["**/*.sql"], "pattern": "(?i)NOLOCK", "severity": "block", "message": "禁止 NOLOCK", "fix": "改用快照隔離" } ] }'
        Write-DcFile 'db/Old.sql' "SELECT Id FROM T WITH (NOLOCK)`n"
        Push-Location $DcRoot
        try { git add -A 2>$null; git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m old 2>$null } finally { Pop-Location }
        Write-DcFile 'db/New.sql' "SELECT Id FROM Orders WITH (NOLOCK)`n"   # 這次新增、還沒 commit
        Write-DcFile 'TestResults/run.trx' (New-DcTrx @('未出貨的訂單可以取消', '已出貨的訂單不能取消'))
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit "block 規則的違規被交付出去了：$($r.stdout)"
            Assert-True ('guideline-block' -in $r.codes) "codes: $($r.codes -join ',')"
            $items = @(@($r.json.problems | Where-Object code -eq 'guideline-block')[0].items) -join ' '
            Assert-Match 'db/New\.sql:1 —— no-nolock' $items
            Assert-True ($items -notmatch 'Old\.sql') "沒改過的舊檔被算進來了：$items"
            Remove-Item (Join-Path $DcRoot 'db/New.sql')
            $r = Invoke-Dc
            Assert-Equal 0 $r.exit "只剩舊檔的違規時應該綠：$($r.stdout)"
        } finally { Remove-DcProject }
    }

    It-Should '前後端兩個 repo：巢狀 repo 裡改過的檔也掃' {
        New-DcProject -NoGit
        Write-DcFile 'guidelines/rules.json' '{ "rules": [ { "id": "no-nolock", "applies-to": ["**/*.sql"], "pattern": "(?i)NOLOCK", "severity": "block", "message": "禁止 NOLOCK", "fix": "改用快照隔離" } ] }'
        Write-DcFile 'backend/db/Base.sql' "SELECT 1`n"
        $be = Join-Path $DcRoot 'backend'
        git -C $be init -q 2>$null; git -C $be add -A 2>$null; git -C $be -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m base 2>$null
        Write-DcFile 'backend/db/New.sql' "SELECT Id FROM Orders WITH (NOLOCK)`n"
        Write-DcFile 'TestResults/run.trx' (New-DcTrx @('未出貨的訂單可以取消', '已出貨的訂單不能取消'))
        try {
            $r = Invoke-Dc
            Assert-True ('guideline-block' -in $r.codes) "巢狀 repo 的改動沒被掃到：$($r.stdout)"
            Assert-Match 'backend/db/New\.sql' (@(@($r.json.problems | Where-Object code -eq 'guideline-block')[0].items) -join ' ')
        } finally { Remove-DcProject }
    }

    It-Should '乾淨的時候 OK 那一行講兩道 gate 的結果（不是 git 時講明規範沒掃）' {
        New-DcProject -NoGit
        try {
            Push-Location $DcRoot
            try { $r = Invoke-Script $DcScript -Params @{ FeatureId = 'cancel-order'; TestResults = 'TestResults/run.trx' } } finally { Pop-Location }
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            Assert-Match '殘留掃描：通過' $r.stdout
            Assert-Match '規範：不是 git' $r.stdout
        } finally { Remove-DcProject }
    }

    It-Should '啟用的殘留掃描程式缺失，文字和 JSON 都判定阻擋' {
        New-DcProject -spec ('# cancel-order' + [string][char]10 + $DcDelivery) -feature ''
        try {
            Use-DcDeliveryTools -omit @('dlp-residual-scan.ps1')
            $r = Invoke-Dc -NoResults
            Assert-Equal 2 $r.exit
            Assert-True (-not $r.json.passed)
            Assert-Equal 'error' $r.json.gates.dlp
            Assert-True ('dlp-check-error' -in $r.codes)

            $r = Invoke-Dc @{ Json = $false } -NoResults
            Assert-Equal 2 $r.exit
            Assert-Match '殘留掃描：執行錯誤' $r.stderr
            Assert-True ($r.stdout -notmatch '\[delivery-check\] OK')
        } finally { Remove-DcProject }
    }

    It-Should '設定停用掃描和檢查時可以交付，並回報 disabled' {
        New-DcProject -spec ('# cancel-order' + [string][char]10 + $DcDelivery) -feature ''
        try {
            Use-DcDeliveryTools -omit @('dlp-residual-scan.ps1', 'guideline-gate.ps1')
            Write-DcFile 'bdd-docs/.dlp-disabled' ''
            Write-DcFile 'guidelines/.gate-disabled' ''
            $r = Invoke-Dc -NoResults
            Assert-Equal 0 $r.exit "stdout: $($r.stdout) stderr: $($r.stderr)"
            Assert-Equal 'disabled' $r.json.gates.dlp
            Assert-Equal 'disabled' $r.json.gates.guideline
        } finally { Remove-DcProject }
    }

    It-Should '掃描回傳空白、破損 JSON 或缺欄位時會阻擋' {
        $lf = [string][char]10
        $cases = @(
            @{ name = 'dlp-residual-scan.ps1'; gate = 'dlp'; body = 'param([string]$Path)' + $lf + 'exit 0' },
            @{ name = 'dlp-residual-scan.ps1'; gate = 'dlp'; body = 'param([string]$Path)' + $lf + "Write-Output '{'" + $lf + 'exit 0' },
            @{ name = 'guideline-gate.ps1'; gate = 'guideline'; body = 'param($Path, [switch]$Strict, [switch]$Json, $MaxReport)' + $lf + 'Write-Output ''{"passed":true}''' + $lf + 'exit 0' }
        )
        foreach ($case in $cases) {
            New-DcProject -spec ('# cancel-order' + $lf + $DcDelivery) -feature ''
            try {
                Write-DcFile 'db/New.sql' 'SELECT 2'
                Write-DcFile 'guidelines/rules.json' '{"rules":[{"id":"test-rule","pattern":"DROP"}]}'
                $stubs = @{}
                $stubs[$case.name] = $case.body
                Use-DcDeliveryTools -stubs $stubs
                $r = Invoke-Dc -NoResults
                Assert-Equal 2 $r.exit
                Assert-Equal 'error' $r.json.gates.($case.gate)
                Assert-True ("$($case.gate)-check-error" -in $r.codes)
            } finally { Remove-DcProject }
        }
    }

    It-Should '啟用的規則檔載入失敗和未設定規則分別回報 error 和 not-applicable' {
        New-DcProject -spec ('# cancel-order' + [string][char]10 + $DcDelivery) -feature ''
        try {
            Write-DcFile 'db/New.sql' 'SELECT 2'
            Use-DcDeliveryTools -omit @('guideline-gate.ps1')
            $r = Invoke-Dc -NoResults
            Assert-Equal 0 $r.exit "stdout: $($r.stdout) stderr: $($r.stderr)"
            Assert-Equal 'not-applicable' $r.json.gates.guideline
            Assert-Equal 'no-rules' $r.json.gate_reasons.guideline

            $script:DcDeliveryPath = $DcScript
            Write-DcFile 'guidelines/rules.json' '{ malformed'
            $r = Invoke-Dc -NoResults
            Assert-Equal 2 $r.exit
            Assert-Equal 'error' $r.json.gates.guideline
            Assert-True ('guideline-check-error' -in $r.codes)
        } finally { Remove-DcProject }
    }
}

Describe-Suite 'delivery-check / UI 驗收方式（gherkin-check 第 6 項帶上來）' {

    It-Should '驗收層 UI 沒寫驗收方式 → gherkin 問題裡指名「驗收方式」、修法指回 ③；補上且每個 project 都過 → 綠' {
        $ui = $DcSpecBody -replace '驗收層：application service', '驗收層：UI（瀏覽器）'
        $pw = "`n驗收方式：playwright｜chromium｜1280x800｜後端：替身（依 openapi.yaml）`n"
        $junit = '<testsuites id="" name=""><testsuite name="cancel.feature.spec.js" hostname="chromium" tests="2" skipped="0">' +
                 '<testcase name="取消訂單 › 未出貨的訂單可以取消" /><testcase name="取消訂單 › 已出貨的訂單不能取消" /></testsuite></testsuites>'
        try {
            New-DcProject -spec ($ui + $DcDelivery)
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit "沒寫驗收方式卻交付得出去：$($r.stdout)"
            $g = @($r.json.problems | Where-Object code -eq 'gherkin')[0]
            Assert-Match '驗收方式：驗收層是 UI' (@($g.items) -join '|')
            Assert-Match '回 ③' $g.fix

            New-DcProject -spec ($ui + $pw + $DcDelivery)
            Write-DcFile 'TestResults/junit.xml' $junit
            (Get-Item (Join-Path $DcRoot 'TestResults/junit.xml')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(1)
            $r = Invoke-Dc @{ TestResults = 'TestResults/junit.xml' }
            Assert-Equal 0 $r.exit "stdout: $($r.stdout) stderr: $($r.stderr)"

            Write-DcFile 'TestResults/junit.xml' ($junit -replace 'hostname="chromium"', 'hostname="firefox"')
            (Get-Item (Join-Path $DcRoot 'TestResults/junit.xml')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(1)
            $r = Invoke-Dc @{ TestResults = 'TestResults/junit.xml' }
            Assert-Equal 2 $r.exit "沒在 chromium 跑卻交付得出去：$($r.stdout)"
            $g = @($r.json.problems | Where-Object code -eq 'gherkin')[0]
            Assert-Match '沒有在驗收方式宣告的 project 通過：未出貨的訂單可以取消（chromium）' (@($g.items) -join '|')
        } finally { Remove-DcProject }
    }
}
