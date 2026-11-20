# commit-check.ps1
# commit 前（git pre-commit）或 CI 裡，把寫檔那三道 gate 對「這次要進版控的檔」再跑一次：
#   - 殘留掃描（dlp-gate）：bdd-docs/ 底下的檔
#   - 規範的 block 規則（guideline-gate）：其餘的檔
#   - build（build-check）：有 production 程式碼的話，不去抖
#
# 為什麼要有它（v4.30.0）：組織政策只允許管理員部署的 hooks（requirements.toml 的 allow_managed_hooks_only）、
# 管理員又不部署 sdlc.ps1 managed-hooks 的時候，Codex 裡沒有任何一條 hook 會跑 —— 寫檔當下沒有人擋。
# 這個政策管的是 Codex，管不到 git：pre-commit 由 git 叫，不靠模型自律。代價是回饋的時間點從「寫檔那一刻」
# 退到「commit 前」，錯的東西會晚一點才被看到。git commit --no-verify 跳得過 —— 要沒人跳得過，在 CI 跑 -Base。
#
# 三種取檔方式：
#   （預設）staged 的檔（git diff --cached）。-Repo 指定是哪一個 repo（pre-commit 帶 git rev-parse --show-toplevel）；
#           工作流裝在上層、前後端各一個 repo 時，hook 在那個 repo 裡被叫，這支在工作流的根目錄跑。
#   -Base <ref>：CI 用，跟 <ref> 的共同祖先比，這個分支改過的檔。
#   -Path：直接指定（測試／手動）。
# 掃的是工作區的檔，不是 stage 的那一份：stage 之後又改了的檔會列出來提醒（內容可能跟 commit 的不同）。
#
# 工作目錄必須是工作流的根目錄（.codex/、bdd-docs/、guidelines/ 所在）—— 三支 gate 的路徑都相對它。
# DLP：只回檔:行、規則 id 與類別，跟三支 gate 同一條安全契約。
#
# Exit: 0 = 可以 commit；2 = 有沒過的項目（訊息附修法）；1 = 不是 git、找不到 -Base 等錯誤。

[CmdletBinding()]
param(
    [string]$Repo,                   # staged 模式：哪一個 repo（預設 = 工作目錄所在的 repo）
    [string]$Base,                   # CI 模式：跟這個 ref 的共同祖先比
    [string[]]$Path = @(),           # 直接指定檔案（相對工作目錄）
    [switch]$NoBuild,                # 不跑 build（只掃描）
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

$MaxItems = 5   # 每一項問題最多列幾筆，其餘只給數量
$here = (Get-Location).Path
$docsPrefix = ($DocsRoot -replace '\\', '/').Trim('/') + '/'

function Fail-Hard([string]$msg) {
    if ($Json) { [pscustomobject]@{ passed = $false; error = $msg } | ConvertTo-Json -Compress }
    else { [Console]::Error.WriteLine("[commit-check] $msg") }
    exit 1
}

$problems = [Collections.Generic.List[object]]::new()
$notices = [Collections.Generic.List[string]]::new()
function Add-Problem([string]$code, [string]$detail, [string]$fix, [string[]]$items = @()) {
    $items = @($items | Where-Object { $_ })
    $problems.Add([pscustomobject]@{
        code = $code; detail = $detail; fix = $fix
        items = @($items | Select-Object -First $MaxItems); omitted = [Math]::Max(0, $items.Count - $MaxItems)
    })
}

function ConvertTo-HereRel([string]$top, [string]$name) {
    return ([IO.Path]::GetRelativePath($here, (Join-Path $top $name)) -replace '\\', '/')
}

# ---- 這次要進版控的檔 ----
$mode = 'path'
$unstaged = @()
if ($Path.Count) {
    $files = @($Path | ForEach-Object { ($_ -replace '\\', '/') -replace '^\./', '' })
} else {
    $repoDir = if ($Repo) { $Repo } else { $here }
    $top = @((Invoke-GitUtf8 $repoDir @('rev-parse', '--show-toplevel')).lines) | Select-Object -First 1
    if (-not $top) { Fail-Hard "$repoDir 不是 git repo —— 判不出這次要 commit 哪些檔" }
    if ($Base) {
        $mode = 'base'
        $mb = Invoke-GitUtf8 $top @('merge-base', $Base, 'HEAD')
        if (-not $mb.ok -or -not $mb.lines.Count) { Fail-Hard "找不到 $Base 跟 HEAD 的共同祖先 —— ref 不存在，或 CI 的 clone 太淺（把 fetch-depth 設成 0）" }
        $names = @((Invoke-GitUtf8 $top @('diff', '--name-only', '--diff-filter=ACMR', $mb.lines[0], 'HEAD')).lines)
    } else {
        $mode = 'staged'
        $names = @((Invoke-GitUtf8 $top @('diff', '--cached', '--name-only', '--diff-filter=ACMR')).lines)
        $dirty = @((Invoke-GitUtf8 $top @('diff', '--name-only')).lines)
        $unstaged = @($names | Where-Object { $_ -in $dirty } | ForEach-Object { ConvertTo-HereRel $top $_ })
    }
    # 工作流根目錄以外的檔（工作流裝在 repo 的子目錄時）不歸它管。
    $files = @($names | ForEach-Object { ConvertTo-HereRel $top $_ } | Where-Object { -not $_.StartsWith('../') -and $_ -ne '..' })
}
$files = @($files | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique)
$docFiles = @($files | Where-Object { $_.StartsWith($docsPrefix, [StringComparison]::OrdinalIgnoreCase) })
$codeFiles = @($files | Where-Object { -not $_.StartsWith($docsPrefix, [StringComparison]::OrdinalIgnoreCase) })
if ($unstaged.Count) {
    $notices.Add("這幾個檔 stage 之後又改過 —— 掃的是工作區的內容，commit 的是 stage 的那一份：$(@($unstaged | Select-Object -First $MaxItems) -join '、')$(if ($unstaged.Count -gt $MaxItems) { " …還有 $($unstaged.Count - $MaxItems) 個" })")
}

# gate 在同一個行程裡跑（-Json 的 stdout 就是結果）。它們給手動執行的人看的 stderr 這裡不要 —— 結論由這支統一講。
# stderr 被重導向時 gate 會自己換掉 Console.Error（標準 I/O 段），那時多出來的幾行照樣出去，不影響結果。
function Invoke-Gate([string]$script, [hashtable]$params) {
    $prevErr = [Console]::Error
    [Console]::SetError([IO.StringWriter]::new())
    try { return ((& (Join-Path $PSScriptRoot $script) @params 2>$null | Out-String) | ConvertFrom-Json) }
    catch { return $null }
    finally { [Console]::SetError($prevErr) }
}

$gates = [ordered]@{ dlp = 'none'; guideline = 'none'; build = 'none' }

# ---- 1. 殘留掃描 ----
if ($docFiles.Count) {
    $dlp = Invoke-Gate 'dlp-gate.ps1' @{ Path = $docFiles; Json = $true }
    if (-not $dlp -or $dlp.status -eq 'error') { $gates.dlp = 'error'; $notices.Add('殘留掃描執行失敗（dlp-gate）。可單獨執行查看原因：pwsh -NoProfile -File .codex/scripts/dlp-gate.ps1 -Path <檔>') }
    elseif ($dlp.disabled) { $gates.dlp = 'disabled'; $notices.Add("殘留掃描已被 $DocsRoot/.dlp-disabled 關閉 —— 這次沒掃 $($docFiles.Count) 個 $DocsRoot/ 的檔。") }
    elseif ($dlp.passed) { $gates.dlp = 'passed' }
    else {
        $gates.dlp = 'failed'
        Add-Problem 'dlp-residual' "$DocsRoot/ 的檔有殘留的敏感資料樣式（只列類別與行號）" '刪掉那個檔，遮蔽後重產（敏感值換成占位符；DB 結果只留結構與筆數），再 git add' @($dlp.findings | ForEach-Object { "$($_.file)：$(@($_.categories | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.type } }) -join '、')（行 $(@($_.lines) -join ',')）" })
    }
}

# ---- 2. 規範的 block 規則 ----
if ($codeFiles.Count) {
    $gl = Invoke-Gate 'guideline-gate.ps1' @{ Path = $codeFiles; Json = $true; MaxReport = 50 }
    if (-not $gl) { $gates.guideline = 'error'; $notices.Add('規範檢查沒有回結果（guideline-gate）—— 這次沒查；自己跑一次看訊息：pwsh -NoProfile -File .codex/scripts/guideline-gate.ps1 -Path <檔>') }
    else {
        $gates.guideline = switch ($gl.status) { 'scanned' { if ($gl.block_count -gt 0) { 'failed' } else { 'passed' } } default { [string]$gl.status } }
        foreach ($p in @($gl.problems | Where-Object { $_ })) { $notices.Add("guidelines/rules.json：$p") }
        if ($gl.status -eq 'disabled') { $notices.Add('規範檢查已被 guidelines/.gate-disabled 關閉 —— 這次沒查。') }
        if ($gl.block_count -gt 0) {
            Add-Problem 'guideline-block' "違反 guidelines/rules.json 的 block 規則（$($gl.block_count) 處）" '依規則改掉再 git add；規則本身有誤就改 rules.json（或降為 warn）' @($gl.hits | Where-Object severity -eq 'block' | ForEach-Object { "$($_.file):$($_.line) —— $($_.rule)$(if ($_.fix) { "：$($_.fix)" })" })
        }
        if ($gl.warn_count -gt 0) { $notices.Add("規範建議 $($gl.warn_count) 處（不擋）：$(@($gl.hits | Where-Object severity -eq 'warn' | Select-Object -First $MaxItems | ForEach-Object { "$($_.file):$($_.line) $($_.rule)" }) -join '、')") }
    }
}

# ---- 3. build ----
# 另起一支 pwsh：build-check 的輸出（編譯錯誤）要收得回來，而它跟 hook 一樣直接寫 Console。
# 路徑經暫存檔傳 —— 命令列有長度上限，一次 commit 幾百個檔就超過。不去抖：hooks 沒在跑時，時間戳不代表之後沒再改。
if ($NoBuild) { $gates.build = 'skipped' }
elseif ($codeFiles.Count) {
    $list = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllLines($list, [string[]]$codeFiles, $Utf8NoBom)
        $bc = (Join-Path $PSScriptRoot 'build-check.ps1') -replace "'", "''"
        $psi = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
        foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
                         "& '$bc' -Path @(Get-Content -LiteralPath '$($list -replace "'", "''")' -Encoding utf8) -DebounceSeconds 0; exit `$LASTEXITCODE")) { $psi.ArgumentList.Add($a) }
        $psi.WorkingDirectory = $here
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $Utf8NoBom; $psi.StandardErrorEncoding = $Utf8NoBom
        if (-not $Json) { [Console]::Error.WriteLine('[commit-check] build 檢查中…') }
        $proc = [Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync(); $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $buildErr = $errTask.GetAwaiter().GetResult(); $buildOut = $outTask.GetAwaiter().GetResult()
        if ($proc.ExitCode -eq 0) { $gates.build = if ($buildOut -match '(?m)^\[build-check\] built:') { 'passed' } else { 'none' } }
        elseif ($proc.ExitCode -eq 2) {
            $gates.build = 'failed'
            Add-Problem 'build-failed' 'build 或型別檢查沒過' '修好編譯錯誤再 commit' @(($buildErr -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 12)
        } else {
            $gates.build = 'error'
            $notices.Add("build-check 跑不起來（exit $($proc.ExitCode)）—— 這次沒 build：$((($buildErr -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1))")
        }
    } finally { Remove-Item -LiteralPath $list -Force -ErrorAction SilentlyContinue }
}

$passed = $problems.Count -eq 0

if ($Json) {
    [pscustomobject]@{
        passed   = $passed
        mode     = $mode
        files    = @($files)
        unstaged = @($unstaged)
        gates    = [pscustomobject]$gates
        problems = @($problems)
        notices  = @($notices)
    } | ConvertTo-Json -Depth 6 -Compress
    exit $(if ($passed) { 0 } else { 2 })
}

foreach ($n in $notices) { [Console]::Error.WriteLine("[commit-check] ! $n") }
if ($passed) {
    $txt = @()
    $txt += switch ($gates.dlp) { 'passed' { '殘留掃描通過' } 'disabled' { '殘留掃描已關閉' } 'error' { '殘留掃描沒跑成' } default { $null } }
    $txt += switch ($gates.guideline) { 'passed' { '規範通過' } 'no-rules' { '沒有 rules.json' } 'disabled' { '規範已關閉' } 'error' { '規範沒查成' } default { $null } }
    $txt += switch ($gates.build) { 'passed' { 'build 通過' } 'skipped' { 'build 略過（-NoBuild）' } 'error' { 'build 沒跑成' } default { $null } }
    $txt = @($txt | Where-Object { $_ })
    [Console]::Out.WriteLine("[commit-check] OK — $($files.Count) 個檔$(if ($txt.Count) { '：' + ($txt -join '、') })。")
    exit 0
}
[Console]::Error.WriteLine("[commit-check] $($problems.Count) 項沒過，先處理再 commit：")
foreach ($p in $problems) {
    [Console]::Error.WriteLine("  - $($p.code)：$($p.detail)")
    foreach ($i in $p.items) { [Console]::Error.WriteLine("      $i") }
    if ($p.omitted) { [Console]::Error.WriteLine("      …還有 $($p.omitted) 項") }
    [Console]::Error.WriteLine("    fix: $($p.fix)")
}
exit 2
