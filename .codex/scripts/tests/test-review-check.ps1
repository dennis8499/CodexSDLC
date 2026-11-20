$RcTools = (Resolve-Path '.codex/scripts').Path
$RcFeature = 'approve-order'
$RcDocs = "bdd-docs/$RcFeature"

function Write-RcFile([string]$Root, [string]$Path, [string]$Text) {
    $file = Join-Path $Root $Path
    [void][IO.Directory]::CreateDirectory((Split-Path $file -Parent))
    [IO.File]::WriteAllText($file, $Text)
}

function Invoke-RcTool([string]$Root, [string]$Name, [hashtable]$Arguments) {
    Push-Location $Root
    try {
        $result = & (Join-Path $RcTools "$Name.ps1") -FeatureId $RcFeature -Json @Arguments
        return @{ code = $LASTEXITCODE; data = ($result | ConvertFrom-Json -AsHashtable) }
    } finally { Pop-Location }
}

function New-RcFixture([scriptblock]$Test) {
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $root = Join-Path $temp ('codex-review-fixture-' + [Guid]::NewGuid().ToString('N'))
    try {
        Write-RcFile $root "$RcDocs/spec.md" "# 核准訂單`n`n## 驗收條件`n確認金額後訂單可核准。`n"
        Write-RcFile $root 'backend/api.ps1' 'function Approve-Order { 200 }'
        Write-RcFile $root 'frontend/ui.js' 'export const result = "approved";'
        Write-RcFile $root 'contracts/order.json' '{"version":1}'
        & $Test $root
    } finally {
        $resolved = [IO.Path]::GetFullPath($root)
        if ((Split-Path $resolved -Parent) -eq $temp.TrimEnd('\', '/') -and [IO.Directory]::Exists($resolved)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

function Approve-RcFixture([string]$Root, [string]$Risk = 'general', [string]$SpecReviewId) {
    $arguments = @{ Action = 'Approve'; Risk = $Risk; Scope = @('backend/', 'frontend/'); Contract = @('contracts/order.json') }
    if ($SpecReviewId) { $arguments.SpecReviewId = $SpecReviewId }
    $response = Invoke-RcTool $Root 'review-check' $arguments
    Assert-Equal 0 $response.code $response.data.error
}

function Start-RcReview([string]$Root, [string]$Mode = 'code') {
    $args = @{ Action = 'Start'; Mode = $Mode }
    if ($Mode -eq 'spec') { $args.Contract = @('contracts/order.json') }
    $response = Invoke-RcTool $Root 'review-check' $args
    Assert-Equal 0 $response.code $response.data.error
    return $response.data
}

function Complete-RcReview([string]$Root, $Attempt, [string]$Report) {
    $name = if ($Attempt.mode -eq 'spec') { 'spec-review' } else { 'review' }
    Write-RcFile $Root "$RcDocs/$name.md" "REVIEW-ID: $($Attempt.review_id)`n$Report"
    return (Invoke-RcTool $Root 'review-check' @{ Action = 'Complete'; ReviewId = $Attempt.review_id })
}

function Mark-RcIncomplete([string]$Root) {
    $attempt = Start-RcReview $Root
    $result = Invoke-RcTool $Root 'review-check' @{ Action = 'Complete'; ReviewId = $attempt.review_id; Incomplete = $true }
    Assert-Equal 0 $result.code $result.data.error
    return $attempt.review_id
}

Describe-Suite 'review-check / 版本與延續' {
    It-Should '非 Git 工作區在無法啟動 Git 時仍可登記與交付' {
        New-RcFixture {
            param($root)
            function git { throw 'The sandbox rejected the child process' }
            Approve-RcFixture $root
            $attempt = Start-RcReview $root
            Assert-Equal 0 (Complete-RcReview $root $attempt 'VERDICT: PASS').code
            $specPath = Join-Path $root "$RcDocs/spec.md"
            [IO.File]::AppendAllText($specPath, "
## 交付 —— 2026-11-20
- 殘留風險：無
")
            $result = Invoke-RcTool $root 'delivery-check' @{}
            Assert-Equal 0 $result.code
            Assert-Equal 'no-git' $result.data.gate_reasons.guideline
        }
    }

    It-Should '規格審查綁定同一草案與契約，程式碼審查仍須獨立登記' {
        New-RcFixture {
            param($root)
            $specReview = Start-RcReview $root 'spec'
            Assert-Equal 0 (Complete-RcReview $root $specReview 'VERDICT: PASS').code
            Approve-RcFixture $root 'high' $specReview.review_id
            $delivery = Invoke-RcTool $root 'delivery-check' @{}
            Assert-Equal 2 $delivery.code
            Assert-True (-not $delivery.data.passed)
            Write-RcFile $root 'contracts/order.json' '{"version":2}'
            $wrong = Invoke-RcTool $root 'review-check' @{
                Action = 'Approve'; Risk = 'high'; Scope = @('backend/'); Contract = @('contracts/order.json'); SpecReviewId = $specReview.review_id
            }
            Assert-Equal 2 $wrong.code
            Assert-Match '同一草案與契約版本' $wrong.data.error
        }
    }

    It-Should '審查中途改程式會封存過期嘗試，可從更新的內容重開' {
        New-RcFixture {
            param($root)
            Approve-RcFixture $root
            $old = Start-RcReview $root
            Write-RcFile $root 'backend/api.ps1' 'function Approve-Order { 201 }'
            $done = Complete-RcReview $root $old 'VERDICT: PASS'
            Assert-Equal 2 $done.code
            Assert-Match '受審檔案已變更' $done.data.error
            $new = Start-RcReview $root
            Assert-True ($new.review_id -cne $old.review_id)
            Assert-Equal 0 (Complete-RcReview $root $new 'VERDICT: PASS').code
        }
    }

    It-Should '審查期間契約遺失會封存嘗試，還原契約後可重開' {
        New-RcFixture {
            param($root)
            Approve-RcFixture $root
            $old = Start-RcReview $root
            [IO.File]::Delete((Join-Path $root 'contracts/order.json'))
            Assert-Equal 2 (Complete-RcReview $root $old 'VERDICT: PASS').code
            Write-RcFile $root 'contracts/order.json' '{"version":1}'
            $new = Start-RcReview $root
            Assert-Equal 0 (Complete-RcReview $root $new 'VERDICT: PASS').code
        }
    }

    It-Should '兩個 Git repo 的已提交、未追蹤及刪除檔案一併納入補審' {
        New-RcFixture {
            param($root)
            foreach ($repo in @('backend', 'frontend')) {
                $path = Join-Path $root $repo
                git -C $path init --quiet
                git -C $path add .
                git -C $path -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m baseline
                Assert-Equal 0 $LASTEXITCODE
            }
            Approve-RcFixture $root
            $old = Start-RcReview $root
            Assert-Equal 0 (Complete-RcReview $root $old 'VERDICT: PASS').code
            Write-RcFile $root 'backend/api.ps1' 'function Approve-Order { 201 }'
            git -C (Join-Path $root 'backend') add api.ps1
            git -C (Join-Path $root 'backend') -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m change
            Assert-Equal 0 $LASTEXITCODE
            [IO.File]::Delete((Join-Path $root 'frontend/ui.js'))
            Write-RcFile $root 'frontend/acceptance.js' 'assert(result === "approved");'
            $new = Start-RcReview $root
            Assert-Equal 'backend/api.ps1,frontend/acceptance.js,frontend/ui.js' (($new.changed_files | Sort-Object) -join ',')
        }
    }

    It-Should '同檔兩項必修可改行號及描述，後續仍逐項對帳' {
        New-RcFixture {
            param($root)
            Approve-RcFixture $root
            $first = Start-RcReview $root
            $failed = "VERDICT: FAIL`n1. [必修] [R-1] backend/api.ps1:1 —— 錯誤狀態代碼`n2. [必修] [R-2] backend/api.ps1:1 —— 缺少驗證"
            Assert-Equal 0 (Complete-RcReview $root $first $failed).code
            $second = Start-RcReview $root
            Assert-Equal 'R-1,R-2' (($second.required_ids | Sort-Object) -join ',')
            $changed = "VERDICT: FAIL`n1. [必修] [R-1] backend/api.ps1:8 —— HTTP 回傳了錯誤的狀態"
            $missing = Complete-RcReview $root $second $changed
            Assert-Equal 2 $missing.code
            Assert-Match 'R-2' $missing.data.error
            $closed = "$changed`n`n## 上一輪必修的交代`n- [R-2] 已修 —— 驗證缺欄位的測試通過"
            Assert-Equal 0 (Complete-RcReview $root $second $closed).code
        }
    }

    It-Should '已登記的 FAIL 遺失必修資料時交付拒絕，保留原報告' {
        New-RcFixture {
            param($root)
            Approve-RcFixture $root
            $attempt = Start-RcReview $root
            $report = "VERDICT: FAIL`n1. [必修] [R-1] backend/api.ps1:1 —— 缺少狀態驗證"
            Assert-Equal 0 (Complete-RcReview $root $attempt $report).code
            $statePath = "$RcDocs/reviews/state.json"
            $state = [IO.File]::ReadAllText((Join-Path $root $statePath)) | ConvertFrom-Json -AsHashtable
            $state.reviews[-1].issues = @()
            Write-RcFile $root $statePath ($state | ConvertTo-Json -Depth 20)
            $result = Invoke-RcTool $root 'delivery-check' @{}
            Assert-Equal 2 $result.code
            Assert-True ('review-invalid' -in $result.data.problems.code)
            Assert-Match 'VERDICT: FAIL' ([IO.File]::ReadAllText((Join-Path $root "$RcDocs/review.md")))
        }
    }
}

Describe-Suite 'review-check / 最小審核' {
    It-Should '兩次中斷及當次同意准許一般需求採明示的最小審核' {
        New-RcFixture {
            param($root)
            Approve-RcFixture $root
            $ids = @((Mark-RcIncomplete $root), (Mark-RcIncomplete $root))
            $spec = [IO.File]::ReadAllText((Join-Path $root "$RcDocs/spec.md"))
            $notes = "## 最小審核`n- attempts: $($ids -join ', ')`n- checked: 結果狀態與驗收測試`n- remaining-risk: 未複查其他路徑`n- decision: 本次使用者同意`n"
            $delivery = "## 交付 —— 2026-11-20`n- 經同意採最小審核`n- 殘留風險：未複查其他路徑`n"
            Write-RcFile $root "$RcDocs/spec.md" "$spec`n$notes`n$delivery"
            $attempt = Start-RcReview $root 'minimal'
            Assert-Equal 0 (Complete-RcReview $root $attempt 'VERDICT: PASS').code
            $result = Invoke-RcTool $root 'delivery-check' @{}
            Assert-Equal 0 $result.code ($result.data | ConvertTo-Json -Depth 8 -Compress)
            Assert-Equal 'minimal' $result.data.review.mode
        }
    }

    It-Should '高風險或已有同版本完整 FAIL 時禁止最小審核' {
        foreach ($risk in @('high', 'general')) {
            New-RcFixture {
                param($root)
                Approve-RcFixture $root $risk
                if ($risk -eq 'general') {
                    $fail = Start-RcReview $root
                    $report = "VERDICT: FAIL`n1. [必修] [R-1] backend/api.ps1:1 —— 缺少狀態驗證"
                    Assert-Equal 0 (Complete-RcReview $root $fail $report).code
                }
                $ids = @((Mark-RcIncomplete $root), (Mark-RcIncomplete $root))
                $spec = [IO.File]::ReadAllText((Join-Path $root "$RcDocs/spec.md"))
                Write-RcFile $root "$RcDocs/spec.md" "$spec`n## 最小審核`n- attempts: $($ids -join ', ')`n- checked: 驗收測試`n- remaining-risk: 未覆蓋授權`n- decision: 本次使用者同意"
                $result = Invoke-RcTool $root 'review-check' @{ Action = 'Start'; Mode = 'minimal' }
                Assert-Equal 2 $result.code
                Assert-Match '最小審核' $result.data.error
            }
        }
    }
}
