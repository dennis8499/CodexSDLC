# dlp-gate.ps1
# PostToolUse 縱深防禦：對寫入 bdd-docs/** 的 artifact 執行殘留掃描。
# 審查完成及必修對帳由 review-check 管理。此 hook 負責掃描及更新心跳。
#
# 短路條件：存在 `bdd-docs/.dlp-disabled` 時整條掃描鏈路跳過。
# 這是**專案層級**的宣告（v4.0.0 起；v3 是 run 層級，而 v4 沒有 run）。
# 中途發現敏感資料 → 刪掉該檔並重跑全量掃描，見 runbooks/dlp-masking.md。
#
# 兩條 Codex 行為決定了這支腳本的輸出形狀（0.154.0 實測，見版本檔 v48-enforcement）：
#   - **阻斷**：exit 2 ＋ stderr。Codex 把 stderr 當成回饋交給模型。
#   - **不阻斷但要喊**：exit 0 的 stderr 會被**整段丟掉**（不進模型、不進 UI）。所以 hook 在叫
#     （payload 帶 hook_event_name）時，同一句話另外寫成 stdout 上的 additionalContext JSON。
#
# 另有 -Path／-Json 給手動執行與 VS Code extension 用（Problems 面板）。-Json 的 stdout 就是結果本身。
#
# Exit: 0 = 通過或不適用／停用；2 = 偵測到殘留或掃描失敗。

[CmdletBinding()]
param(
    [switch]$Managed,                                   # managed hooks（管理員部署在專案外）：沒裝工作流的專案一律放行
    [string]$Payload,
    [string[]]$Path,                                    # 直接指定檔案，跳過 payload 解析
    [string]$ScanScript = (Join-Path $PSScriptRoot 'dlp-residual-scan.ps1'),   # 跟這支放在一起（managed hooks 時不在專案裡）
    [string]$DisableMarker,
    [switch]$Json,
    [string]$DocsRoot = 'bdd-docs'
)

# ---- 標準 I/O：被程式呼叫時一律 UTF-8 ----
# Codex 送進來的 payload 是 UTF-8、也用 UTF-8 解讀 hook 的輸出；Windows 上 [Console] 的編碼卻跟著 console 的
# code page 走（zh-TW 是 cp950；並行的 hook 共用同一個 console，偶爾連輸出端也是）。Codex 0.154.0 實測的後果：
# 一份 743 字、meta 完整的中文 handoff 被解成 1772 字、JSON 解析失敗、抓不到 mode —— **每一次 spawn 都被擋**；
# 阻斷理由的中文到模型手上是亂碼。只在被重導向時才換：人在終端機跑的時候照 console 的 code page 顯示。
# 同一段在每一支會被程式呼叫的腳本裡各有一份（清單由 test-hook-payload.ps1 守住）。
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
if ([Console]::IsOutputRedirected) { $w = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetOut($w) }
if ([Console]::IsErrorRedirected)  { $w = [IO.StreamWriter]::new([Console]::OpenStandardError(),  $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetError($w) }
function Read-StdinUtf8 {
    if ([Console]::IsInputRedirected) { return [IO.StreamReader]::new([Console]::OpenStandardInput(), $Utf8NoBom).ReadToEnd() }
    return [Console]::In.ReadToEnd()
}

# ---- managed hooks：沒裝工作流的專案一律放行 ----
# 公司政策只允許管理員部署的 hooks（requirements.toml 的 allow_managed_hooks_only）時，這支由管理員裝在專案外，
# 這台機器上每一個 Codex session 都會叫它（sdlc.ps1 managed-hooks 產生的指令帶 -Managed）。沒裝工作流的 repo 不歸它管：
# 不放行的話，別的 repo 的委派會被擋、寫檔會被拿去 build。stdin 照樣讀完再走 —— 不讀的話 Codex 寫 payload 可能卡住。
# 四支 hook 各有一份逐字相同的副本（test-hook-payload.ps1 守住）。
if ($Managed -and -not (Test-Path -LiteralPath '.codex/bdd-workflow/bdd-workflow-version.json' -PathType Leaf)) {
    if (-not $Payload) { $null = Read-StdinUtf8 }
    exit 0
}

# ---- hook payload → 這次寫出去的檔 ----
# 三支 PostToolUse gate（dlp-gate／guideline-gate／build-check）各有一份**逐字相同**的副本：
# gate 必須能獨立跑，少複製一支共用檔不該讓三支一起靜默失效。重複由 test-hook-payload.ps1 守住
# （三支的 Read-HookPayload 必須逐字相同）。
#
# 形狀以 Codex 0.154.0 實測為準：
#   apply_patch → tool_input.command 是整份 patch；路徑在 `*** Add File:`／`*** Update File:`／`*** Move to:`，**沒有引號**
#   Bash        → tool_input.command 是 shell 指令；路徑通常帶引號
# 舊版只認引號包住的路徑 —— apply_patch 寫的檔一個都抽不到，而那正是 agent 寫檔的主要途徑。症狀是零。
#
# 只看 tool_input（有的話）：其餘欄位裡的 transcript_path 是一個 .jsonl，那是對話紀錄，不是這次寫的檔。
# patch 內文裡的引號字串是**檔案內容**，不算路徑。
function Read-HookPayload([string]$raw) {
    $result = [pscustomobject]@{ event = ''; paths = @() }
    if (-not $raw) { return $result }
    $texts = @(); $tool = ''
    try {
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($doc -is [pscustomobject] -and $doc.PSObject.Properties['hook_event_name']) { $result.event = [string]$doc.hook_event_name }
        if ($doc -is [pscustomobject] -and $doc.PSObject.Properties['tool_name']) { $tool = [string]$doc.tool_name }
        $scope = if ($doc -is [pscustomobject] -and $doc.PSObject.Properties['tool_input']) { $doc.tool_input } else { $doc }
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue($scope)
        while ($queue.Count -gt 0) {
            $cur = $queue.Dequeue()
            if ($null -eq $cur) { continue }
            if ($cur -is [string]) { $texts += $cur; continue }
            if ($cur -is [ValueType]) { continue }
            if ($cur -is [System.Collections.IEnumerable]) { foreach ($i in $cur) { $queue.Enqueue($i) }; continue }
            foreach ($p in $cur.PSObject.Properties) { $queue.Enqueue($p.Value) }
        }
    } catch { $texts = @($raw) }

    $paths = @(); $mentioned = @()
    foreach ($t in $texts) {
        if ($t -match '(?m)^\*\*\* Begin Patch') {
            foreach ($m in [regex]::Matches($t, '(?m)^\*\*\* (?:Add File|Update File|Move to):[ \t]*(.+?)[ \t]*\r?$')) { $paths += $m.Groups[1].Value }
            continue
        }
        foreach ($m in [regex]::Matches($t, '["'']([^"''\r\n]*?\.[A-Za-z0-9]{1,10})["'']')) { $mentioned += $m.Groups[1].Value }
        foreach ($m in [regex]::Matches($t, '["''](bdd-docs[\\/][^"''\r\n]*)["'']')) { $mentioned += $m.Groups[1].Value }
        foreach ($m in [regex]::Matches($t, '(?<![\w.\\/-])(bdd-docs[\\/][^\s"''`;|&<>(){}]+)')) { $mentioned += $m.Groups[1].Value }
        if ($t -match '^[^"''\r\n*]+\.[A-Za-z0-9]{1,10}$') { $mentioned += $t }
    }
    # shell 指令裡的路徑只是「被提到」：`Get-Content -Path 'legacy/report.sql'`、`rg -n "Status" "x.sql"` 都抽得到，
    # 而那些檔這次沒被寫。不篩的話，讀一個不合新規範的舊檔就收到一句「現在就改掉」—— 唯讀的 agent 被叫去改舊檔。
    # 所以只留這次真的被寫到的：修改或建立時間在 120 秒內（建立時間接得住保留修改時間的 Copy-Item）。
    # 不用 git status：這套流程從不 commit，bdd-docs/ 與上一個需求改過的檔永遠是「已修改／未追蹤」，等於沒篩。
    # patch 標頭本來就是寫的檔，不篩；其他工具（Edit／Write 的 file_path）也是寫，不篩。
    if ($tool -match '^(Bash|shell)$') {
        $now = [DateTime]::UtcNow
        $mentioned = @($mentioned | Where-Object {
            $f = $_.Trim()
            try {
                if (-not [IO.Path]::IsPathRooted($f)) { $f = Join-Path (Get-Location).Path $f }
                if (-not [IO.File]::Exists($f)) { return $false }
                $touched = [IO.File]::GetLastWriteTimeUtc($f)
                $created = [IO.File]::GetCreationTimeUtc($f)
                if ($created -gt $touched) { $touched = $created }
                return (($now - $touched).TotalSeconds -le 120)
            } catch { return $false }
        })
    }
    $result.paths = @(($paths + $mentioned) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    return $result
}

# ---- 心跳：證明 hook 真的有在跑 ----
# 四支 hook（handoff-lint／dlp-gate／guideline-gate／build-check）各有一份**逐字相同**的副本（test-hook-payload.ps1 守住）。
# Codex 沒信任 hooks、hooks.json 改過待重審、或叫不起 pwsh 時，這四支一次都不會跑，而且沒有任何提示 ——
# 看得見那件事的唯一線索是「agent 寫了產出，這裡的檔卻沒跟著變新」。doctor 拿它跟 bdd-docs/ 的產出比（Get-HookHeartbeat）。
# 只在 hook 在叫（payload 帶 hook_event_name）時寫：手動跑、-Path、-Json 都不算數。
# 寫不進去就算了 —— 心跳是證據，不是 gate；為了它讓一次寫檔或委派失敗是本末倒置。
function Write-HookHeartbeat([string]$eventName, [string]$name) {
    if (-not $eventName) { return }
    try {
        $dir = Join-Path (Get-Location).Path 'bdd-docs/.cache/hooks'
        [void][IO.Directory]::CreateDirectory($dir)
        [IO.File]::WriteAllText((Join-Path $dir "$name.last"), "$([DateTime]::UtcNow.ToString('o')) $eventName`n", [Text.UTF8Encoding]::new($false))
    } catch { }
}

# 一律正規化成「相對 cwd、正斜線」—— hook 的 cwd 就是專案根。
function ConvertTo-RelPath([string]$p) {
    $root = (Get-Location).Path
    try { return [IO.Path]::GetRelativePath($root, [IO.Path]::GetFullPath($p.Trim(), $root)).Replace('\', '/') }
    catch { return $null }
}

function Write-HookContext([string]$eventName, [string[]]$lines) {
    if ($Json -or -not $eventName -or -not $lines) { return }
    [Console]::Out.WriteLine((@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = ($lines -join "`n") } } |
                              ConvertTo-Json -Compress -Depth 4))
}

function Write-Result([string]$status, [string[]]$scanned = @(), $findings = @()) {
    if (-not $Json) { return }
    [pscustomobject]@{
        passed   = $status -notin @('failed', 'error')
        disabled = $status -eq 'disabled'
        status   = $status
        scanned  = @($scanned)
        findings = @($findings)
    } | ConvertTo-Json -Depth 6 -Compress
}

$hook = [pscustomobject]@{ event = ''; paths = @() }
if (-not $Path) {
    if (-not $Payload) { $Payload = Read-StdinUtf8 }
    if (-not $Payload) { Write-Result 'not-applicable'; exit 0 }
    $hook = Read-HookPayload $Payload
    Write-HookHeartbeat $hook.event 'dlp-gate'
    $Path = $hook.paths
}

# 標記檔關掉時**每次都喊**（不阻斷，exit 仍是 0）。標記檔通常是某一次為了解卡建的，
# 建完就留在那裡 —— 之後每一個需求都在沒有殘留掃描的情況下寫檔，而畫面上一切正常。
# 靜默地「防護其實沒在生效」比擋錯更糟，這一行是唯一會提醒的東西。
if (-not $DisableMarker) { $DisableMarker = Join-Path $DocsRoot '.dlp-disabled' }
if (Test-Path -LiteralPath $DisableMarker -PathType Leaf) {
    $msg = "[Hook][DLP] 已被 $DisableMarker 關閉 —— 這次沒有掃任何檔。要恢復就刪掉那個標記檔。"
    [Console]::Error.WriteLine($msg)
    Write-HookContext $hook.event @($msg)
    Write-Result 'disabled'
    exit 0
}

$docsPath = ConvertTo-RelPath $DocsRoot
if (-not $docsPath) {
    [Console]::Error.WriteLine('[Hook][DLP] 無法解析產出目錄。')
    Write-Result 'error'
    exit 2
}
$docsPrefix = $docsPath.TrimEnd('/') + '/'
$targets = @($Path | ForEach-Object { ConvertTo-RelPath $_ } |
             Where-Object { $_ -and $_.StartsWith($docsPrefix, [StringComparison]::OrdinalIgnoreCase) } |
             Sort-Object -Unique |
             Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
if (-not $targets.Count) { Write-Result 'not-applicable'; exit 0 }

if (-not (Test-Path -LiteralPath $ScanScript -PathType Leaf)) {
    [Console]::Error.WriteLine('[Hook][DLP] 找不到殘留掃描程式，請修復工作流工具後重跑。')
    Write-Result 'error'
    exit 2
}

# 同一次寫入有多個檔時，各檔都要有可核對的掃描結果。
$scanFull = (Resolve-Path -LiteralPath $ScanScript).Path
$scanned = @()
$findings = @()
$failedToScan = @()
foreach ($p in $targets) {
    try {
        $global:LASTEXITCODE = -1
        $out = & $scanFull -Path $p 2>$null
        $scanExit = $LASTEXITCODE
        $scan = ($out | Out-String) | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
        if ($scan -isnot [pscustomobject] -or $scan.passed -isnot [bool] -or
            ($scan.scanned_chars -isnot [int] -and $scan.scanned_chars -isnot [long]) -or $scan.scanned_chars -lt 0 -or
            ($scan.residual_count -isnot [int] -and $scan.residual_count -isnot [long]) -or $scan.residual_count -lt 0 -or
            $scan.passed -ne ($scan.residual_count -eq 0) -or $scan.categories -isnot [array] -or
            $scanExit -ne $(if ($scan.passed) { 0 } else { 2 })) {
            $failedToScan += $p
            continue
        }
    } catch {
        $failedToScan += $p
        continue
    }

    $scanned += $p
    if (-not $scan.passed) {
        $cats = @($scan.categories)
        $refs = @($scan.line_refs)
        $findings += [pscustomobject]@{ file = $p; categories = $cats; lines = $refs }
        [Console]::Error.WriteLine("[Hook][DLP] Residual sensitive pattern in $($p)：$($cats.type -join '、')（行 $($refs -join ',')）")
    }
}

if ($failedToScan.Count) {
    [Console]::Error.WriteLine("[Hook][DLP] 殘留掃描執行錯誤，請確認工具及檔案可讀後重跑：$($failedToScan -join '、')")
    Write-Result 'error' $scanned $findings
    exit 2
}
if ($findings.Count) { Write-Result 'failed' $scanned $findings; exit 2 }
Write-Result 'passed' $scanned
exit 0
