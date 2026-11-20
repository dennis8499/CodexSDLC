# Review reports carry the prose. The ledger keeps the versions and item states needed to validate them.
. (Join-Path $PSScriptRoot 'workspace-repos.ps1')

function Get-ReviewHash([string]$Text) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-ReviewFileHash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-ReviewFeatureDir([string]$WorkspaceRoot, [string]$FeatureId, [string]$DocsRoot = 'bdd-docs') {
    if ($FeatureId -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { throw "無效的 feature-id：$FeatureId" }
    $docs = [IO.Path]::GetFullPath($DocsRoot, $WorkspaceRoot)
    $relative = [IO.Path]::GetRelativePath($WorkspaceRoot, $docs).Replace('\', '/')
    if ($relative -eq '..' -or $relative.StartsWith('../') -or [IO.Path]::IsPathRooted($relative)) { throw '需求文件目錄必須在工作區內' }
    return (Join-Path $docs $FeatureId)
}

function Get-ReviewSections([string]$Text) {
    $parts = [Collections.Generic.List[object]]::new()
    $part = @{ level = 0; title = ''; heading = ''; body = [Collections.Generic.List[string]]::new(); visible = [Collections.Generic.List[string]]::new() }
    $parts.Add($part)
    $fence = ''
    foreach ($line in ($Text -split '\r?\n')) {
        $marker = [regex]::Match($line, '^[ ]{0,3}(\x60{3,}|~{3,})(.*)$')
        if ($marker.Success) {
            $token = $marker.Groups[1].Value
            if (-not $fence) { $fence = $token }
            elseif ($token[0] -eq $fence[0] -and $token.Length -ge $fence.Length -and -not $marker.Groups[2].Value.Trim()) { $fence = '' }
            $part.body.Add($line)
            continue
        }
        if (-not $fence -and $line -match '^(#{1,6})[ \t]+(.+?)\s*$') {
            $part = @{ level = $Matches[1].Length; title = ($Matches[2] -replace '\s+#+$', ''); heading = $line; body = [Collections.Generic.List[string]]::new(); visible = [Collections.Generic.List[string]]::new() }
            $parts.Add($part)
            continue
        }
        $part.body.Add($line)
        if (-not $fence) { $part.visible.Add($line) }
    }
    return $parts.ToArray()
}

function Read-ReviewSpec([string]$FeatureDir) {
    $sections = @(Get-ReviewSections ([IO.File]::ReadAllText((Join-Path $FeatureDir 'spec.md'))))
    $iteration = 1
    $skipLevel = 0
    $content = [Collections.Generic.List[string]]::new()
    foreach ($part in $sections) {
        if ($part.level -eq 2 -and $part.title -match '^迭代\s+([1-9][0-9]*)\b') { $iteration = [int]$Matches[1] }
        if ($skipLevel -and $part.level -gt $skipLevel) { continue }
        $skipLevel = 0
        if ($part.title -match '^(?:交付|修正授權|風險決議|最小審核|切片與沿用)(?:\s|[：:]|$)') {
            $skipLevel = $part.level
            continue
        }
        if ($part.heading) { $content.Add($part.heading) }
        $content.AddRange($part.body)
    }
    return @{ iteration = $iteration; sections = $sections; hash = (Get-ReviewHash (($content -join "`n").Trim())) }
}

function Read-ReviewState([string]$FeatureDir) {
    $path = Join-Path $FeatureDir 'reviews/state.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ schema = 1; approvals = @(); reviews = @() } }
    $state = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -Depth 40 -ErrorAction Stop
    if ($state -isnot [System.Collections.IDictionary] -or $state.schema -ne 1 -or $state.approvals -isnot [array] -or $state.reviews -isnot [array]) {
        throw '審查紀錄的格式無效'
    }
    foreach ($record in $state.reviews) {
        if ($record.id -cnotmatch '^[a-f0-9]{32}$' -or $record.iteration -lt 1 -or $record.mode -notin @('spec', 'code', 'minimal') -or
            $record.status -notin @('started', 'completed', 'incomplete', 'invalidated') -or $record.issues -isnot [array]) {
            throw '審查嘗試的識別、類型或問題紀錄無效'
        }
    }
    return $state
}

function Invoke-WithReviewStateLock([string]$FeatureDir, [scriptblock]$Work) {
    $lockKey = [IO.Path]::GetFullPath($FeatureDir)
    if ($IsWindows) { $lockKey = $lockKey.ToUpperInvariant() }
    $mutex = [Threading.Mutex]::new($false, "CodexSdlcReview-$(Get-ReviewHash $lockKey)")
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw '另一個程序正更新審查紀錄，請重試' }
        & $Work
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Write-ReviewState([string]$FeatureDir, $State) {
    $directory = Join-Path $FeatureDir 'reviews'
    [void][IO.Directory]::CreateDirectory($directory)
    $output = Join-Path $directory 'state.json'
    $temp = Join-Path $directory ('.state-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $text = ($State | ConvertTo-Json -Depth 30) + "`n"
        [IO.File]::WriteAllText($temp, $text, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $output, $true)
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function ConvertTo-ReviewPath([string]$Path) {
    $name = $Path.Replace('\', '/')
    if (-not $name -or [IO.Path]::IsPathRooted($name) -or $name -match '(^|/)\.\.(/|$)|[:\r\n\x00]') {
        throw "審查路徑必須在工作區內：$Path"
    }
    while ($name.StartsWith('./', [StringComparison]::Ordinal) -and $name.Length -gt 2) { $name = $name.Substring(2) }
    if ($name -eq '.') { return './' }
    return $name
}

function Assert-ReviewDirectPath([string]$Path, [string]$WorkspaceRoot, [Collections.Generic.HashSet[string]]$Checked) {
    while ($Path -and $Path -ne $WorkspaceRoot -and $Checked.Add($Path)) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($item.LinkType) { throw '受審檔案與契約須使用工作區內的直接路徑' }
        $Path = Split-Path $Path -Parent
    }
}

function Get-ReviewContracts([string]$WorkspaceRoot, [string[]]$Paths) {
    if (-not $Paths.Count) { return }
    $checked = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @($Paths | ForEach-Object { ConvertTo-ReviewPath $_ } | Sort-Object -CaseSensitive -Unique)) {
        $full = [IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $path))
        Assert-ReviewDirectPath $full $WorkspaceRoot $checked
        @{ path = $path; sha256 = (Get-ReviewFileHash $full) }
    }
}

function ConvertTo-ReviewFingerprint($Entries) {
    return (Get-ReviewHash ((@($Entries | ForEach-Object { "$($_.path)`0$($_.sha256)" }) -join "`n")))
}

function Get-ReviewRepos([string]$WorkspaceRoot, [string[]]$Scope) {
    foreach ($repo in @(Get-WorkspaceRepos $WorkspaceRoot)) {
        foreach ($path in $Scope) {
            if (-not $repo.rel -or $path -eq './' -or $path -eq $repo.rel -or $path.StartsWith("$($repo.rel)/", [StringComparison]::OrdinalIgnoreCase) -or
                ($path.EndsWith('/') -and $repo.rel.StartsWith($path, [StringComparison]::OrdinalIgnoreCase))) {
                $repo
                break
            }
        }
    }
}

function Get-ReviewBases([string]$WorkspaceRoot, [string[]]$Scope) {
    foreach ($repo in @(Get-ReviewRepos $WorkspaceRoot $Scope)) {
        $head = Invoke-GitUtf8 $repo.dir @('rev-parse', '--verify', 'HEAD')
        if (-not $head.ok -and -not (Invoke-GitUtf8 $repo.dir @('symbolic-ref', '--quiet', 'HEAD')).ok) { throw "讀不到 Git 基準：$($repo.rel)" }
        @{ path = $repo.rel; commit = if ($head.ok) { [string]$head.lines[0] } else { '' } }
    }
}

function Get-ReviewGitPaths($Repo, [string[]]$Arguments) {
    $result = Invoke-GitUtf8 $Repo.dir $Arguments
    if (-not $result.ok) { throw "讀取受審 Git 檔案失敗：$($Repo.rel)" }
    return @(($result.lines -join "`n") -split "`0" | Where-Object { $_ })
}

function Get-ReviewDirectoryPaths([string]$Root, [string]$Relative, $Repos) {
    $directory = Join-Path $Root $Relative
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return }
    foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
        if ($item.LinkType -or $item.Name -in $script:RepoScanSkip) { continue }
        $path = [IO.Path]::GetRelativePath($Root, $item.FullName).Replace('\', '/')
        if (Get-RepoOf $Repos $path) { continue }
        if ($item.PSIsContainer) { Get-ReviewDirectoryPaths $Root $path $Repos }
        else { $path }
    }
}

function Get-ReviewSourceFiles([string]$WorkspaceRoot, [string[]]$Scope, $Bases) {
    $repos = @(Get-ReviewRepos $WorkspaceRoot $Scope)
    if ((@($repos | ForEach-Object { $_.rel }) -join "`n") -cne (@($Bases | ForEach-Object { $_.path }) -join "`n")) {
        throw '受審 Git 倉庫已變更，請重新確認範圍'
    }
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $checked = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $Scope) {
        Assert-ReviewDirectPath ([IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $path)).TrimEnd('\', '/')) $WorkspaceRoot $checked
        if (-not $path.EndsWith('/')) { [void]$paths.Add($path); continue }
        if (-not (Get-RepoOf $repos $path.TrimEnd('/'))) {
            foreach ($found in @(Get-ReviewDirectoryPaths $WorkspaceRoot $path $repos)) { [void]$paths.Add($found) }
        }
    }
    foreach ($repo in $repos) {
        $base = $Bases | Where-Object { $_.path -ceq $repo.rel } | Select-Object -First 1
        $names = @(Get-ReviewGitPaths $repo @('ls-files', '-z', '--cached', '--others', '--exclude-standard'))
        if ($base.commit) {
            $names += @(Get-ReviewGitPaths $repo @('diff', '--relative', '--name-only', '-z', '--no-renames', $base.commit, '--'))
        }
        foreach ($name in $names) {
            $path = if ($repo.rel) { "$($repo.rel)/$name" } else { $name }
            if ((Get-RepoOf $repos $path).repo.rel -cne $repo.rel) { continue }
            foreach ($prefix in $Scope) {
                if ($prefix.EndsWith('/') -and ($prefix -eq './' -or $path.StartsWith($prefix, [StringComparison]::Ordinal))) {
                    if ((($path -split '/') | Select-Object -SkipLast 1 | Where-Object { $_ -in $script:RepoScanSkip }).Count) { break }
                    [void]$paths.Add($path)
                    break
                }
            }
        }
    }
    foreach ($path in @($paths | Sort-Object -CaseSensitive)) {
        $full = [IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $path))
        Assert-ReviewDirectPath $full $WorkspaceRoot $checked
        $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue -ErrorVariable fileErrors
        if (@($fileErrors | Where-Object CategoryInfo -ne $null | Where-Object { $_.CategoryInfo.Category -ne 'ObjectNotFound' }).Count) {
            throw "無法讀取受審檔案：$path"
        }
        if ($item -and ($item.PSIsContainer -or $item.LinkType)) { throw "受審範圍需要直接指向檔案：$path" }
        @{ path = $path; sha256 = if ($item) { Get-ReviewFileHash $full } else { 'missing' } }
    }
}

function Get-ReviewDiff($Before, $After) {
    $prior = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Before) { $prior[$entry.path] = $entry.sha256 }
    foreach ($entry in $After) {
        if (-not $prior.ContainsKey($entry.path) -or $prior[$entry.path] -cne $entry.sha256) { $entry.path }
        [void]$prior.Remove($entry.path)
    }
    $prior.Keys | Sort-Object -CaseSensitive
}

function Read-ReviewFindings([string]$Text) {
    $pattern = '^\s*[0-9]+\.\s*\[(必修|建議)\]\s*(?:\[(R-[1-9][0-9]*)\]\s*)?(.+?)\s+——\s+(.+?)\s*$'
    foreach ($section in @(Get-ReviewSections $Text)) {
        for ($index = 0; $index -lt $section.visible.Count; $index++) {
            $match = [regex]::Match($section.visible[$index], $pattern)
            if (-not $match.Success) { continue }
            $location = $match.Groups[3].Value.Trim().Trim([char]96, '{', '}')
            $failure = $null
            if ($index + 1 -lt $section.visible.Count -and $section.visible[$index + 1] -match '^\s+會怎麼壞[:：]\s*(.+)$') { $failure = $Matches[1] }
            @{
                severity = $match.Groups[1].Value
                id = $match.Groups[2].Value
                historical = ($section.title -eq '歷史發現')
                location = $location
                file = ($location -replace '(:[0-9]+(-[0-9]+)?)+$', '')
                problem = $match.Groups[4].Value
                failure = $failure
            }
        }
    }
}

function Get-ReviewDecisions($Spec, [string]$ReviewId) {
    foreach ($part in @($Spec.sections | Where-Object { $_.title -eq '風險決議' })) {
        foreach ($line in $part.visible) {
            if ($line -cmatch '^\s*-\s*accept-risk:\s+([a-f0-9]{32})\s+(R-[1-9][0-9]*)\s*\|\s*(\S.*?)\s*$' -and $Matches[1] -ceq $ReviewId) {
                @{ id = $Matches[2]; evidence = $Matches[3] }
            }
        }
    }
}

function Get-ReviewLatest($State, [string[]]$Modes, [int]$Iteration = 0) {
    return ($State.reviews | Where-Object { $_.status -eq 'completed' -and $_.mode -in $Modes -and (-not $Iteration -or $_.iteration -eq $Iteration) } | Select-Object -Last 1)
}

function Get-ReviewApproval($State, $Spec) {
    return ($State.approvals | Where-Object { $_.iteration -eq $Spec.iteration } | Select-Object -Last 1)
}

function Get-ReviewReportPath([string]$FeatureDir, [string]$Mode) {
    $report = if ($Mode -eq 'spec') { 'spec-review.md' } else { 'review.md' }
    return (Join-Path $FeatureDir $report)
}

function Read-ReviewReport([string]$Text, $Spec, $Attempt, $Previous, [string[]]$ReservedIds) {
    $sections = @(Get-ReviewSections $Text)
    $lines = @($sections | Where-Object title -ne '歷史發現' | ForEach-Object { $_.visible })
    $results = @($lines | Where-Object { $_ -cmatch '^\s*VERDICT\s*:\s*(PASS|FAIL)\s*$' })
    $ids = @($lines | Where-Object { $_ -cmatch '^\s*REVIEW-ID\s*:\s*[a-f0-9]{32}\s*$' })
    if ($results.Count -ne 1 -or $ids.Count -ne 1 -or ($ids[0] -replace '^\s*REVIEW-ID\s*:\s*', '').Trim() -cne $Attempt.id) {
        throw '審查報告須填本次 REVIEW-ID 及唯一的 VERDICT'
    }
    $result = ($results[0] -replace '^\s*VERDICT\s*:\s*', '').Trim()
    $open = @(Read-ReviewFindings $Text | Where-Object { $_.severity -eq '必修' -and -not $_.historical })
    $declaredOpen = @($lines | Where-Object { $_ -match '^\s*[0-9]+\.\s*\[必修\]' })
    if ($open.Count -ne $declaredOpen.Count -or @($open | Where-Object { -not $_.id }).Count -or
        @($open | Group-Object id | Where-Object Count -gt 1).Count) { throw '每一項必修須有唯一的 R-數字 ID，並依審查格式寫出問題' }
    if (($result -eq 'PASS' -and $open.Count) -or ($result -eq 'FAIL' -and -not $open.Count)) {
        throw '審查結論與待修項目矛盾'
    }
    if ($Attempt.mode -eq 'minimal' -and $result -ne 'PASS') { throw '最小審核仍有待修，請修正或完成獨立程式碼審查' }
    $priorItems = @()
    if ($Previous) { $priorItems = @($Previous.issues | Where-Object state -in @('open', 'accepted')) }
    $decisions = if ($Previous) { @(Get-ReviewDecisions $Spec $Previous.id) } else { @() }
    $items = [ordered]@{}
    foreach ($finding in $open) {
        if ($finding.id -in $ReservedIds -and $finding.id -notin $priorItems.id) { throw "必修 ID 已用於歷史發現：$($finding.id)" }
        $items[$finding.id] = @{ id = $finding.id; state = 'open' }
    }
    foreach ($previousSection in @($sections | Where-Object { $_.title -eq '上一輪必修的交代' })) {
        foreach ($line in $previousSection.visible) {
            if ($line -notmatch '^\s*[-*]\s*(?:\[(R-[1-9][0-9]*)\])') { continue }
            if ($line -cnotmatch '^\s*[-*]\s+\[(R-[1-9][0-9]*)\]\s+(已修|接受不修)\s+——\s+(\S.*?)\s*$') { throw '必修處置須有 ID、處置及證據' }
            $id = $Matches[1]
            $disposition = $Matches[2]
            $item = $priorItems | Where-Object id -ceq $id | Select-Object -First 1
            if (-not $item -or $items.Contains($id)) { throw "必修處置重複或沒有上一輪項目：$id" }
            if ($disposition -eq '接受不修' -and $item.state -ne 'accepted' -and @($decisions | Where-Object id -ceq $id).Count -ne 1) {
                throw "缺少使用者接受風險的決定：$id"
            }
            $items[$id] = @{ id = $id; state = if ($disposition -eq '已修') { 'fixed' } else { 'accepted' } }
        }
    }
    foreach ($item in $priorItems) {
        if (-not $items.Contains($item.id)) { throw "上一輪的必修缺少逐項處置：$($item.id)" }
    }
    return @{ verdict = $result; issues = @($items.Values) }
}

function Test-ReviewApproval([string]$WorkspaceRoot, $Approval, $Spec) {
    if (-not $Approval -or $Approval.spec_hash -cne $Spec.hash) { return $false }
    $current = @(Get-ReviewContracts $WorkspaceRoot @($Approval.contracts | ForEach-Object path))
    return (ConvertTo-ReviewFingerprint $current) -ceq $Approval.contract_hash
}

function Test-ReviewEvidence([string]$WorkspaceRoot, [string]$FeatureDir, $State, $Spec, $Approval, $Review) {
    if (-not $Review -or -not (Test-ReviewApproval $WorkspaceRoot $Approval $Spec) -or $Review.approval_id -cne $Approval.id) { return $false }
    $report = Get-ReviewReportPath $FeatureDir $Review.mode
    if (-not (Test-Path -LiteralPath $report -PathType Leaf) -or (Get-ReviewFileHash $report) -cne $Review.report_hash) { return $false }
    $index = [array]::IndexOf($State.reviews, $Review)
    $prior = if ($index -gt 0) { @($State.reviews[0..($index - 1)]) } else { @() }
    $previous = Get-ReviewLatest @{ reviews = $prior } @('code', 'minimal')
    $reserved = @($prior | ForEach-Object { $_.issues } | ForEach-Object id | Sort-Object -Unique)
    $result = Read-ReviewReport ([IO.File]::ReadAllText($report)) $Spec $Review $previous $reserved
    if ($result.verdict -cne $Review.verdict -or
        (@($result.issues | ForEach-Object { "$($_.id):$($_.state)" }) -join ',') -cne
        (@($Review.issues | ForEach-Object { "$($_.id):$($_.state)" }) -join ',')) {
        throw '審查紀錄的判定或逐項結果與原報告不符'
    }
    $files = @(Get-ReviewSourceFiles $WorkspaceRoot $Approval.scope $Approval.bases)
    return (ConvertTo-ReviewFingerprint $files) -ceq $Review.scope_hash
}

function Get-MinimalReviewNotes($Spec) {
    $section = $Spec.sections | Where-Object { $_.title -eq '最小審核' } | Select-Object -Last 1
    return ($section.visible -join "`n").Trim()
}

function Test-MinimalReview($State, $Spec, $Approval, $Attempt) {
    if ($Approval.risk -notin @('general', 'low')) { return $false }
    $tries = @($State.reviews | Where-Object {
        $_.iteration -eq $Spec.iteration -and $_.mode -eq 'code'
    } | Select-Object -Last 2)
    if ($tries.Count -ne 2 -or @($tries | Where-Object {
        $_.status -ne 'incomplete' -or $_.approval_id -cne $Approval.id -or $_.scope_hash -cne $Attempt.scope_hash
    }).Count) { return $false }
    if (@($State.reviews | Where-Object {
        $_.mode -eq 'code' -and $_.status -eq 'completed' -and $_.verdict -eq 'FAIL' -and
        $_.approval_id -ceq $Approval.id -and $_.scope_hash -ceq $Attempt.scope_hash
    }).Count) { return $false }
    $text = Get-MinimalReviewNotes $Spec
    if (-not $text -or ($Attempt.minimal_hash -and $Attempt.minimal_hash -cne (Get-ReviewHash $text))) { return $false }
    $pair = [regex]::Escape(($tries.id -join ', '))
    return $text -cmatch "(?m)^\s*-\s*attempts:\s+$pair\s*$" -and
        $text -cmatch '(?m)^\s*-\s*checked:\s+\S' -and
        $text -cmatch '(?m)^\s*-\s*remaining-risk:\s+\S' -and
        $text -cmatch '(?m)^\s*-\s*decision:\s+\S'
}

function Get-ReviewDeliveryEvidence {
    param([string]$WorkspaceRoot, [string]$FeatureDir)
    $out = @{ version = $null; verdict = $null; mode = $null; risks = @(); problems = @() }
    try {
        $state = Read-ReviewState $FeatureDir
        $spec = Read-ReviewSpec $FeatureDir
        $approval = Get-ReviewApproval $state $spec
        $review = Get-ReviewLatest $state @('code', 'minimal') $spec.iteration
        $fix = '請依本次核准範圍完成程式碼審查及登記'
        if (-not $review) {
            $path = Get-ReviewReportPath $FeatureDir 'code'
            $code = if (Test-Path -LiteralPath $path -PathType Leaf) { 'review-evidence-required' } else { 'no-review' }
            $out.problems += @{ code = $code; detail = '缺少本次迭代的程式碼審查證據'; fix = $fix; items = @() }
            return $out
        }
        $out.version = $review.id
        $out.verdict = $review.verdict
        $out.mode = $review.mode
        if (-not (Test-ReviewEvidence $WorkspaceRoot $FeatureDir $state $spec $approval $review)) {
            $items = @()
            if ($approval) {
                $currentFiles = @(Get-ReviewSourceFiles $WorkspaceRoot $approval.scope $approval.bases)
                $items = @(Get-ReviewDiff $review.files $currentFiles)
            }
            $out.problems += @{ code = 'review-stale'; detail = '審查版本與目前規格、報告或受審範圍不符'; fix = $fix; items = $items }
            return $out
        }
        $delivery = $spec.sections | Where-Object { $_.level -eq 2 -and $_.title -match '^交付(?:\s|[：:]|$)' } | Select-Object -Last 1
        $deliveryText = $delivery.visible -join "`n"
        if ($review.mode -eq 'minimal' -and (
            -not (Test-MinimalReview $state $spec $approval $review) -or $deliveryText -notmatch '經同意採最小審核'
        )) {
            $out.problems += @{ code = 'review-exception-invalid'; detail = '最小審核的嘗試、使用者同意或交付說明不足'; fix = '補齊本次紀錄，或完成獨立程式碼審查'; items = @() }
        }
        $decisions = @(Get-ReviewDecisions $spec $review.id)
        $linked = $deliveryText -cmatch "(?m)^\s*-\s*review-version:\s+$($review.id)\s*$"
        foreach ($issue in @($review.issues | Where-Object state -in @('open', 'accepted'))) {
            $id = $issue.id
            $decision = @($decisions | Where-Object id -ceq $id)
            $line = "(?m)^\s*-\s*\[$id\]\s+\S"
            $out.risks += @{ id = $id; text = "[$id] 必修殘留風險，需本次使用者決定及交付紀錄"; ok = ($linked -and $decision.Count -eq 1 -and $deliveryText -cmatch $line) }
        }
    } catch {
        $out.problems += @{ code = 'review-invalid'; detail = '無法核對審查紀錄、規格或受審檔案'; fix = '確認檔案可讀並修正紀錄，再重新審查'; items = @() }
    }
    return $out
}

function Get-ReviewFixContext {
    param([string]$WorkspaceRoot, [string]$FeatureId)
    $featureDir = Get-ReviewFeatureDir $WorkspaceRoot $FeatureId
    $path = Join-Path $featureDir 'spec.md'
    $out = @{ iteration = 1; review_id = $null; open_ids = @(); is_current_failure = $false; spec_path = $path }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $out }
    $spec = Read-ReviewSpec $featureDir
    $state = Read-ReviewState $featureDir
    $out.iteration = $spec.iteration
    $review = Get-ReviewLatest $state @('code', 'minimal') $spec.iteration
    if ($review) {
        $out.review_id = $review.id
        $out.open_ids = @($review.issues | Where-Object state -eq 'open' | ForEach-Object id)
        $out.is_current_failure = $review.mode -eq 'code' -and $review.verdict -eq 'FAIL' -and
            (Test-ReviewEvidence $WorkspaceRoot $featureDir $state $spec (Get-ReviewApproval $state $spec) $review)
    }
    return $out
}
