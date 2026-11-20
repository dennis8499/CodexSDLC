# delivery-check.ps1
# ⑥ 交付前的唯讀檢查。核對本次程式碼審查、Gherkin 和交付殘留風險，
# 並重跑敏感資料掃描及團隊規範檢查。輸出只含結論、位置與有界的修正提示。
# Exit: 0 = 可以交付；2 = 有阻擋項目；1 = feature-id 或 spec.md 入口無效。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FeatureId,
    [string[]]$TestResults = @(),        # implementer 最後一次回報的結果檔（全套測試的 TRX 或 JUnit XML）
    [string]$DocsRoot = 'bdd-docs',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# ---- 標準 I/O：被程式呼叫時一律 UTF-8 ----
# 同一段在每一支會被程式呼叫的腳本裡各有一份（清單由 test-hook-payload.ps1 守住）。
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
if ([Console]::IsOutputRedirected) { $w = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetOut($w) }
if ([Console]::IsErrorRedirected)  { $w = [IO.StreamWriter]::new([Console]::OpenStandardError(),  $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetError($w) }
function Read-StdinUtf8 {
    if ([Console]::IsInputRedirected) { return [IO.StreamReader]::new([Console]::OpenStandardInput(), $Utf8NoBom).ReadToEnd() }
    return [Console]::In.ReadToEnd()
}

. (Join-Path $PSScriptRoot 'lib/workspace-repos.ps1')
. (Join-Path $PSScriptRoot 'lib/source-files.ps1')

$MaxItems = 5   # 每一項問題最多列幾筆，其餘只給數量（收據要有界；全文在各自的檔或 gherkin-check 裡）

function Fail-Hard([string]$msg) {
    if ($Json) { [pscustomobject]@{ passed = $false; feature_id = $FeatureId; error = $msg } | ConvertTo-Json -Compress }
    else { [Console]::Error.WriteLine("[delivery-check] $msg") }
    exit 1
}

function NormId([string]$s) { return ($s -replace '[^\p{L}\p{N}]', '').ToLowerInvariant() }

# 首行 `# feature-id: {id}` 的 .feature（判法跟 gherkin-check 找 spec 的那一條相同：第一個 feature-id 行）。
# 單一 repo 用 git（照 .gitignore 篩）；工作區底下有好幾個 repo、或根目錄不是 repo 時逐檔走 —— 根目錄的 git 看不進
# 巢狀 repo，前後端分成兩個 repo 時 .feature 全在裡面，會一個都找不到（lib/workspace-repos.ps1）。
function Get-FeatureFiles([string]$id) {
    $cands = @()
    $here = (Get-Location).Path
    $listed = if (Test-SingleRepo @(Get-WorkspaceRepos $here)) { Invoke-GitUtf8 $here @('ls-files', '--cached', '--others', '--exclude-standard', '--', '*.feature') } else { $null }
    if ($listed -and $listed.ok) {
        $cands = @($listed.lines)
    } else {
        $cands = @(Select-WorkspaceFiles -Files (Get-WorkspaceFiles -Root $here -ExcludeDirs @('.git', 'node_modules', 'bin', 'obj', 'target', 'build', 'out', 'dist', '.features-gen')) -Patterns '*.feature' |
            ForEach-Object { Get-WorkspaceRelPath $here $_.FullName })
    }
    $docs = ($DocsRoot -replace '\\', '/').Trim('/')
    $hit = @()
    foreach ($c in $cands) {
        $rel = $c -replace '\\', '/'
        if ($rel -like "$docs/*" -or -not (Test-Path -LiteralPath $rel -PathType Leaf)) { continue }
        $m = [regex]::Match([IO.File]::ReadAllText((Resolve-Path -LiteralPath $rel).Path), '(?m)^\s*#\s*feature-id:\s*([A-Za-z0-9._-]+)')
        if ($m.Success -and $m.Groups[1].Value -ceq $id) { $hit += $rel }
    }
    return $hit
}

$problems = [Collections.Generic.List[object]]::new()
function Add-Problem([string]$code, [string]$detail, [string]$fix, [string[]]$items = @()) {
    $items = @($items | Where-Object { $_ })
    $problems.Add([pscustomobject]@{
        code = $code; detail = $detail; fix = $fix
        items = @($items | Select-Object -First $MaxItems); omitted = [Math]::Max(0, $items.Count - $MaxItems)
    })
}

if ($FeatureId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { Fail-Hard "feature-id「$FeatureId」不合法 —— 是 bdd-docs/ 底下那個目錄名" }
$specRel = "$(($DocsRoot -replace '\\', '/').TrimEnd('/'))/$FeatureId/spec.md"
if (-not (Test-Path -LiteralPath $specRel -PathType Leaf)) { Fail-Hard "找不到 $specRel" }
$specPath = (Resolve-Path -LiteralPath $specRel).Path
$featureDir = Split-Path $specPath -Parent
$workspaceRoot = (Get-Location).Path
$specText = [IO.File]::ReadAllText($specPath) -replace '\r\n', [string][char]10

# ---- 1. 審核 ----
$reviewRel = (Join-Path (Split-Path $specRel -Parent) 'review.md') -replace '\\', '/'
$review = $null
try {
    . (Join-Path $PSScriptRoot 'lib/review-state.ps1')
    $review = Get-ReviewDeliveryEvidence -WorkspaceRoot $workspaceRoot -FeatureDir $featureDir
    $reviewProblems = @($review.problems | Where-Object { $_ })
    if (-not $reviewProblems.Count -and
        ($review.mode -notin @('code', 'minimal') -or $review.verdict -notin @('PASS', 'FAIL') -or -not $review.version)) {
        throw 'Incomplete review result'
    }
    foreach ($p in $reviewProblems) {
        Add-Problem $p.code $p.detail $p.fix @($p.items)
    }
} catch {
    Add-Problem 'review-evidence-error' '無法讀回或核對審查證據' '確認 review-check 與其依賴已安裝，修正紀錄後再跑交付檢查'
}
$verdict = $review.verdict
# ---- 2. 驗收條件（gherkin-check） ----
$features = @(Get-FeatureFiles $FeatureId)
$manual = @()
$gherkin = [ordered]@{ applicable = $false; features = $features; passed = $null }
$specHasGherkin = $specText -match '(?m)^```gherkin'
if (-not $features.Count) {
    if ($specHasGherkin) {
        Add-Problem 'feature-not-found' "spec.md 有 Gherkin 區塊，但 repo 裡找不到首行 # feature-id: $FeatureId 的 .feature" '請 implementer 把 Gherkin 區塊落成 .feature（放在測試樹、首行保留 # feature-id:），或確認它在 git 看得到的位置'
    }
} else {
    $gherkin.applicable = $true
    $missingResults = @($TestResults | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if (-not $TestResults.Count) {
        Add-Problem 'no-test-results' '.feature 存在，但沒有給結果檔 —— 判不出每條 scenario 有沒有通過、是不是現在這份程式碼跑的' '帶 implementer 最後一次回報的全套測試結果檔：-TestResults {TRX 或 JUnit XML 的 path}'
    } elseif ($missingResults.Count) {
        Add-Problem 'test-results-missing' '給的結果檔不存在' '確認 path；不在了就請 implementer 重跑全套測試' $missingResults
    }
    $useResults = if ($TestResults.Count -and -not $missingResults.Count) { $TestResults } else { @() }
    $gcOut = & (Join-Path $PSScriptRoot 'gherkin-check.ps1') -Feature $features -TestResults $useResults -DocsRoot $DocsRoot -Json
    $gc = $null
    try { $gc = ($gcOut | Out-String) | ConvertFrom-Json } catch { }
    if (-not $gc) {
        Add-Problem 'gherkin-check-error' 'gherkin-check 沒有回結果' "自己跑一次看訊息：pwsh -NoProfile -File .codex/scripts/gherkin-check.ps1 -Feature $($features -join ',')"
    } else {
        $labels = [ordered]@{
            error                        = '跑不起來'
            missing_scenarios            = 'spec 的 scenario 不在 .feature 裡'
            missing_steps                = '步驟沒有逐字照抄'
            removed_scenarios            = '既有的 scenario 被刪了'
            removed_steps                = '既有 step 的措辭被改了'
            skipped_scenarios            = 'scenario 被標成略過'
            scenarios_without_test       = '結果檔裡找不到這條 scenario 的測試'
            scenarios_not_passed         = '這條 scenario 的測試沒有全部通過'
            prior_scenarios_without_test = '前幾次迭代的 scenario 找不到測試'
            prior_scenarios_not_passed   = '前幾次迭代的 scenario 沒有全部通過'
            stale_results_newer          = '結果檔比這些改過的檔舊'
            ui_method_problems           = '驗收方式'
            ui_projects_missing          = '沒有在驗收方式宣告的 project 通過'
            ui_method_mismatch           = '不是驗收方式宣告的工具跑的'
        }
        $items = @()
        foreach ($r in @($gc.results)) {
            $manual += @($r.manual_scenarios | Where-Object { $_ })
            foreach ($k in $labels.Keys) {
                foreach ($v in @($r.$k | Where-Object { $_ })) {
                    $txt = if ($v -is [string]) { $v } elseif ($v.scenario -and $v.step) { "$($v.scenario)：$($v.step)" } elseif ($v.scenario -and $v.detail) { "$($v.scenario)（$($v.detail)）" } elseif ($v.scenario) { $v.scenario } else { [string]$v }
                    $items += "$($labels[$k])：$txt"
                }
            }
            if ($r.skipped_tests -gt 0) { $items += "測試結果裡有 $($r.skipped_tests) 個 skipped" }
        }
        $gherkin.passed = [bool]$gc.passed
        if (-not $gc.passed) {
            $cmd = "pwsh -NoProfile -File .codex/scripts/gherkin-check.ps1 -Feature $($features -join ',')$(if ($useResults.Count) { " -TestResults $($useResults -join ',')" })"
            Add-Problem 'gherkin' 'gherkin-check 沒過' "驗收方式沒寫或寫不完整 → 回 ③ 在驗收層底下補「驗收方式」、跟使用者確認；結果檔過期 → 請 implementer 重跑全套測試、給新的結果檔；其餘是實作的問題 → 交回 implementer（mode: fix）。全文：$cmd" $items
        }
    }
}
$manual = @($manual | Select-Object -Unique)
$gherkin.manual = $manual

# ---- 3. 交付一節 ----
$sections = @([regex]::Matches($specText, '(?ms)^##[ \t]*交付[^\n]*\n(.*?)(?=^##\s|\z)') | ForEach-Object { $_.Groups[1].Value })
$allDelivery = $sections -join "`n"
$deliveryNorm = NormId $allDelivery
$required = @()
foreach ($s in $manual) {
    $required += [pscustomobject]@{ text = "待人工驗證：$s"; ok = ([bool]$deliveryNorm -and $deliveryNorm.Contains((NormId $s))) }
}
$required += @($review.risks | Where-Object { $_ })
$missing = @($required | Where-Object { -not $_.ok })

if (-not $sections.Count) {
    Add-Problem 'no-delivery-section' 'spec.md 沒有「## 交付 —— {日期}」一節' '在 spec.md 尾端寫「## 交付 —— {日期}」：怎麼驗的（指令、結果）與殘留風險（沒有寫「無」）'
} elseif ($sections[-1] -notmatch '殘留風險|剩餘風險') {
    Add-Problem 'delivery-no-risk-line' '最後那一節「交付」沒有寫殘留風險' '補一行「殘留風險：」，逐項列出；沒有就寫「殘留風險：無」'
}
if ($missing.Count) {
    Add-Problem 'delivery-missing-risk' '本次交付缺少殘留風險的逐項處置' '在本次交付列出審查版本與問題 ID，待人工驗證以 scenario 標題列出' @($missing | ForEach-Object { $_.text })
}
# ---- 4. 寫檔時的 gates ----
function Invoke-DeliveryGate([string]$name, [hashtable]$parameters) {
    try {
        $global:LASTEXITCODE = -1
        $raw = & (Join-Path $PSScriptRoot $name) @parameters 2>$null
        $gateExit = $LASTEXITCODE
        $result = ($raw | Out-String) | ConvertFrom-Json -NoEnumerate
        if ($result -is [pscustomobject] -and $result.passed -is [bool] -and
            $gateExit -eq $(if ($result.passed) { 0 } else { 2 })) {
            return $result
        }
    } catch { }
    return $null
}

$gates = [ordered]@{ dlp = 'not-applicable'; guideline = 'not-applicable' }
$gateReasons = [ordered]@{ dlp = 'no-targets'; guideline = 'no-targets' }
$docsFull = Split-Path $featureDir -Parent
$docsRel = [IO.Path]::GetRelativePath($workspaceRoot, $docsFull).Replace('\', '/')
if (Test-Path -LiteralPath (Join-Path $docsFull '.dlp-disabled') -PathType Leaf) {
    $gates.dlp = 'disabled'
    $gateReasons.dlp = '.dlp-disabled'
} else {
    try {
        $dlpTargets = @(Get-ChildItem -LiteralPath $featureDir -Recurse -File -ErrorAction Stop |
            ForEach-Object { [IO.Path]::GetRelativePath($workspaceRoot, $_.FullName).Replace('\', '/') })
        $mapPath = Join-Path $docsFull 'project-map.md'
        if (Test-Path -LiteralPath $mapPath -PathType Leaf) { $dlpTargets += "$docsRel/project-map.md" }
        if ($dlpTargets.Count) {
            $dlp = Invoke-DeliveryGate 'dlp-gate.ps1' @{ Path = $dlpTargets; DocsRoot = $docsFull; Json = $true }
            if (-not $dlp -or $dlp.disabled -ne $false -or $dlp.status -notin @('passed', 'failed') -or
                $dlp.passed -ne ($dlp.status -eq 'passed') -or $dlp.scanned -isnot [array] -or
                @($dlpTargets | Where-Object { $_ -notin $dlp.scanned }).Count -or
                $dlp.findings -isnot [array] -or $dlp.passed -ne ($dlp.findings.Count -eq 0)) {
                throw 'Incomplete DLP result'
            }
            $gates.dlp = $dlp.status
            $gateReasons.dlp = $null
            if (-not $dlp.passed) {
                Add-Problem 'dlp-residual' '需求產出有殘留的敏感資料樣式（只列類別與行號）' '遮蔽後重產，再跑交付檢查' @(
                    $dlp.findings | ForEach-Object {
                        $types = @($_.categories | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.type } })
                        "$($_.file)：$($types -join '、')（行 $($_.lines -join ',')）"
                    }
                )
            }
        }
    } catch {
        $gates.dlp = 'error'
        $gateReasons.dlp = 'scan-error'
        Add-Problem 'dlp-check-error' '必要的殘留掃描執行錯誤或結果不完整' '確認 dlp-gate.ps1、dlp-residual-scan.ps1 與產出可讀後重跑'
    }
}

if (Test-Path -LiteralPath 'guidelines/.gate-disabled' -PathType Leaf) {
    $gates.guideline = 'disabled'
    $gateReasons.guideline = '.gate-disabled'
} else {
    try {
        $repos = @(Get-WorkspaceRepos $workspaceRoot)
        if (-not $repos.Count) {
            if (Test-Path -LiteralPath '.git') { throw 'Git checkout cannot be read' }
            $gateReasons.guideline = 'no-git'
        }
        $changed = @()
        foreach ($repo in $repos) {
            $topResult = Invoke-GitUtf8 $repo.dir @('rev-parse', '--show-toplevel')
            if (-not $topResult.ok -or -not $topResult.lines.Count) { throw 'Git checkout cannot be read' }
            $top = $topResult.lines[0]
            $unstaged = Invoke-GitUtf8 $top @('diff', '--name-only', '--')
            $staged = Invoke-GitUtf8 $top @('diff', '--cached', '--name-only', '--')
            $untracked = Invoke-GitUtf8 $top @('ls-files', '--others', '--exclude-standard')
            if (-not ($unstaged.ok -and $staged.ok -and $untracked.ok)) { throw 'Git changes cannot be read' }
            foreach ($file in @($unstaged.lines + $staged.lines + $untracked.lines)) {
                $changed += [IO.Path]::GetRelativePath($workspaceRoot, (Join-Path $top $file)).Replace('\', '/')
            }
        }
        $changed = @($changed | Select-Object -Unique | Where-Object {
            -not $_.StartsWith("$docsRel/") -and -not $_.StartsWith('../') -and (Test-Path -LiteralPath $_ -PathType Leaf)
        })
        if ($changed.Count -and -not (Test-Path -LiteralPath 'guidelines/rules.json')) {
            $gateReasons.guideline = 'no-rules'
        } elseif ($changed.Count) {
            $gl = Invoke-DeliveryGate 'guideline-gate.ps1' @{ Path = $changed; Strict = $true; Json = $true; MaxReport = 50 }
            if (-not $gl -or $gl.status -notin @('scanned', 'no-rules', 'no-targets') -or
                $gl.problems -isnot [array] -or $gl.problems.Count -or
                ($gl.block_count -isnot [long] -and $gl.block_count -isnot [int]) -or
                $gl.block_count -lt 0 -or $gl.passed -ne ($gl.block_count -eq 0) -or
                $gl.hits -isnot [array] -or $gl.files -isnot [array] -or $gl.scanned_files -ne $gl.files.Count -or
                ($gl.status -eq 'scanned' -and -not $gl.scanned_files)) {
                throw 'Incomplete guideline result'
            }
            if ($gl.status -eq 'scanned') {
                $gates.guideline = if ($gl.passed) { 'passed' } else { 'failed' }
                $gateReasons.guideline = $null
                if (-not $gl.passed) {
                    Add-Problem 'guideline-block' "改過的檔違反團隊規範的 block 規則（$($gl.block_count) 處）" '交回 implementer 依規則修正' @(
                        $gl.hits | Where-Object severity -eq 'block' | ForEach-Object { "$($_.file):$($_.line) —— $($_.rule)" }
                    )
                }
            } else {
                if (-not $gl.passed) { throw 'Inconsistent guideline result' }
                $gateReasons.guideline = $gl.status
            }
        }
    } catch {
        $gates.guideline = 'error'
        $gateReasons.guideline = 'scan-error'
        Add-Problem 'guideline-check-error' '必要的團隊規範檢查執行錯誤或結果不完整' '確認 Git、guideline-gate.ps1 與 guidelines/rules.json 後重跑'
    }
}

$passed = $problems.Count -eq 0
$reminder ='「外部來源只用替身驗過」只在 implementer 的回傳裡，這支看不到 —— 有的話確認已寫進交付。'

$gateLabels = @{
    'passed' = '通過'
    'not-applicable' = '不適用'
    'disabled' = '按設定停用'
    'failed' = '規則未通過'
    'error' = '執行錯誤'
}
$dl = "殘留掃描：$($gateLabels[$gates.dlp])"
$gl = switch ($gateReasons.guideline) {
    'no-git' { '規範：不是 git（不適用）' }
    'no-rules' { '規範：沒有 rules.json 或適用規則（不適用）' }
    default { "規範：$($gateLabels[$gates.guideline])" }
}

if ($Json) {
    [pscustomobject]@{
        passed     = $passed
        feature_id = $FeatureId
        spec       = $specRel
        review     = [pscustomobject]@{ path = $reviewRel; verdict = $verdict; mode = $review.mode; version = $review.version }
        gherkin    = [pscustomobject]$gherkin
        delivery   = [pscustomobject]@{ sections = $sections.Count; required = @($required | ForEach-Object { $_.text }); missing = @($missing | ForEach-Object { $_.text }) }
        gates      = [pscustomobject]$gates
        gate_reasons = [pscustomobject]$gateReasons
        problems   = @($problems)
        reminder   = $reminder
    } | ConvertTo-Json -Depth 6 -Compress
} elseif ($passed) {
    $g = if ($gherkin.applicable) { "gherkin-check 通過（$($features.Count) 個 .feature$(if ($manual.Count) { "，$($manual.Count) 條 @manual" })）" } else { '沒有 .feature（不適用）' }
    $v = if ($review.mode -eq 'minimal') { '經同意採最小審核' } elseif ($verdict -eq 'FAIL') { '審核 FAIL（逐項接受風險）' } else { '審核 PASS' }
    "[delivery-check] OK — $FeatureId：$v、$g、交付一節列了 $($required.Count) 項要列的殘留風險；$dl、$gl。"
    "  ! $reminder"
} else {
    [Console]::Error.WriteLine("[delivery-check] $FeatureId：$($problems.Count) 項沒過，先處理再交付：")
    [Console]::Error.WriteLine("  $dl；$gl。")
    foreach ($p in $problems) {
        [Console]::Error.WriteLine("  - $($p.code)：$($p.detail)")
        foreach ($i in $p.items) { [Console]::Error.WriteLine("      $i") }
        if ($p.omitted) { [Console]::Error.WriteLine("      …還有 $($p.omitted) 項") }
        [Console]::Error.WriteLine("    fix: $($p.fix)")
    }
}
exit $(if ($passed) { 0 } else { 2 })
