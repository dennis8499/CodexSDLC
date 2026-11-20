# Shared by the hook and the explicit self-check path. Only the dispatch path
# writes a registration. A receipt survives changes to the review or its approval.

function Get-FixField([string]$Prompt, [string]$Name) {
    $key = [regex]::Escape($Name)
    foreach ($match in [regex]::Matches($Prompt, "(?im)^[ \t]*(?:[-*][ \t]*)?$($key)[ \t]*:[ \t]*([^\r\n]*)")) {
        $match.Groups[1].Value.Trim()
    }
}

function Get-FixApproval([string]$SpecPath, [string]$FeatureId, [string]$Iteration) {
    foreach ($section in @(Get-ReviewSections ([IO.File]::ReadAllText($SpecPath)) | Where-Object { $_.level -eq 2 -and $_.title -ceq '修正授權' })) {
        $block = [regex]::Match(($section.body -join "`n"), '(?s)^\s*(?<fence>[\x60]{3,}|~{3,})json[ \t]*\n(?<json>.+)\n\k<fence>[ \t]*\s*$')
        if (-not $block.Success) { continue }
        try {
            $approval = $block.Groups['json'].Value | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($approval -is [System.Collections.IDictionary] -and
                $approval.feature_id -ceq $FeatureId -and [string]$approval.iteration -ceq $Iteration) {
                $approval
            }
        } catch {
            # Invalid Markdown metadata can't authorize a dispatch.
        }
    }
}

function Get-FixLedgerPath([string]$WorkspaceRoot, [string]$FeatureId) {
    Join-Path (Get-ReviewFeatureDir $WorkspaceRoot $FeatureId) 'reviews/fix-dispatches.json'
}

function Read-FixLedger([string]$Path, [string]$FeatureId) {
    try {
        # Allow an atomic replacement while a preview holds a reader on Windows.
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    } catch [IO.FileNotFoundException] {
        return @{ schema_version = 1; feature_id = $FeatureId; iterations = @{} }
    } catch [IO.DirectoryNotFoundException] {
        return @{ schema_version = 1; feature_id = $FeatureId; iterations = @{} }
    }
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
    try {
        $data = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($data.schema_version -ne 1 -or $data.feature_id -cne $FeatureId -or
            $data.iterations -isnot [System.Collections.IDictionary]) { throw 'Invalid fix dispatch ledger.' }
        return $data
    } finally { $reader.Dispose() }
}

function Write-FixLedger([string]$Path, $Ledger) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $staged = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($staged, ($Ledger | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($staged, $Path, $true)
    } finally {
        if ([IO.File]::Exists($staged)) { [IO.File]::Delete($staged) }
    }
}

function New-FixProblem([string]$Rule, [string]$Detail, [string]$Fix) {
    [pscustomobject]@{ rule = $Rule; detail = $Detail; fix = $Fix }
}

function Get-FixReceiptOutput($Receipt) {
    $attempt = $Receipt.attempts[-1]
    [pscustomobject]@{
        receipt_id = $Receipt.receipt_id
        attempt_id = $attempt.attempt_id
        status     = $attempt.status
        session_id = $attempt.session_id
        turn_id    = $attempt.turn_id
        tool_use_id = $attempt.tool_use_id
    }
}

function Get-StuckFixIds($NormalRounds, [int]$Round, [string[]]$IssueIds) {
    if ($Round -le 2) { return }
    $previous = @($NormalRounds | Where-Object { $_.round -eq $Round - 1 })
    $earlier = @($NormalRounds | Where-Object { $_.round -eq $Round - 2 })
    if ($previous.Count -eq 1 -and $earlier.Count -eq 1) {
        $IssueIds | Where-Object { $_ -cin $previous[0].issue_ids -and $_ -cin $earlier[0].issue_ids }
    }
}

function Test-SameFixIds([string[]]$Left, [string[]]$Right) {
    return $Left.Count -eq $Right.Count -and @($Left | Where-Object { $_ -cnotin $Right }).Count -eq 0
}

# Registration callers hold the review state lock for this feature. Preview can
# read the last complete ledger between atomic replacements.
function Test-FixRoundState {
    param(
        [string]$WorkspaceRoot, [string]$FeatureId, [int]$Round, [int]$Maximum, [string]$MaximumSource,
        [string]$Prompt, [bool]$Register, $HookPayload
    )
    $result = @{ problem = $null; receipt = $null; legacy = $false }
    $showLimit = "round=$Round > 上限 $Maximum（$MaximumSource）"
    $limitAction = '停止修正迴圈，以 Codex user confirmation 交回使用者裁定（接受現版本／核准最後一輪／暫停）'
    if ($Round -gt ($Maximum + 1)) {
        $result.problem = New-FixProblem 'review-loop-exceeded' $showLimit $limitAction
        return $result
    }

    $path = Get-FixLedgerPath $WorkspaceRoot $FeatureId
    $extra = $Round -eq ($Maximum + 1)
    $fixContext = Get-ReviewFixContext -WorkspaceRoot $WorkspaceRoot -FeatureId $FeatureId
    $iteration = [string]$fixContext.iteration
    if ($iteration -notmatch '^[1-9][0-9]*$') { throw 'Invalid review iteration.' }
    $ledger = Read-FixLedger $path $FeatureId
    $rounds = $ledger.iterations[$iteration]
    if ($null -eq $rounds) { $rounds = @{ normal = @(); extra = $null } }
    elseif ($rounds.normal -isnot [array]) { throw 'Invalid normal round records.' }
    $existing = $rounds.extra
    if ($existing) {
        $result.receipt = Get-FixReceiptOutput $existing
        if (-not $extra -or $result.receipt.status -cne 'not-sent') {
            $result.problem = New-FixProblem 'review-extra-used' "本迭代已有額外輪次收據 $($existing.receipt_id)（$($result.receipt.status)）" '對照執行端的原任務與收據，確認是否送出'
            return $result
        }
    }
    if (-not $fixContext.is_current_failure) {
        if ($extra) { $result.problem = New-FixProblem 'review-loop-exceeded' "$showLimit，缺少本迭代最新的已完成 FAIL 審查" $limitAction }
        elseif ($fixContext.review_id -or [IO.File]::Exists($path) -or [IO.File]::Exists((Join-Path ([IO.Path]::GetDirectoryName($path)) 'state.json'))) {
            $result.problem = New-FixProblem 'review-fix-evidence' '目前沒有可修正的當前程式碼審查 FAIL' '先完成並登記當前程式碼審查'
        } else { $result.legacy = $true }
        return $result
    }

    $openIds = @($fixContext.open_ids)
    $issueFields = @(Get-FixField $Prompt 'issue-ids')
    $issueIds = if ($issueFields.Count -eq 0 -and -not $extra) { @($openIds) }
                elseif ($issueFields.Count -eq 1) { @($issueFields[0].Split(',') | ForEach-Object { $_.Trim() }) }
                else { @() }
    $issueIds = @($issueIds)
    if ($issueIds.Count -eq 0 -or @($issueIds | Where-Object { $_ -cnotin $openIds }).Count -gt 0 -or
        @($issueIds | Sort-Object -CaseSensitive -Unique).Count -ne $issueIds.Count) {
        $result.problem = New-FixProblem 'review-fix-issue-ids' 'issue-ids 須為目前待修 ID，且每項只列一次' '在 handoff 的 issue-ids 填寫本輪要修正的 ID，以逗號分隔'
        return $result
    }
    if ($extra) {
        $specReferences = @(Get-FixField $Prompt 'spec')
        $expectedSpec = "bdd-docs/$FeatureId/spec.md"
        $specPath = $fixContext.spec_path
        $declaredPath = $null
        if ($specReferences.Count -eq 1) {
            try { $declaredPath = [IO.Path]::GetFullPath($specReferences[0].Trim([char]96), $WorkspaceRoot) } catch { }
        }
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not [string]::Equals($declaredPath, $specPath, $comparison)) {
            $result.problem = New-FixProblem 'review-fix-spec-ref' '額外輪次須引用當前需求的規格' "在 handoff 寫 spec: $expectedSpec"
            return $result
        }
        $approvals = @(Get-FixApproval $specPath $FeatureId $iteration)
        $approval = $approvals | Select-Object -Last 1
        if (-not $approval -or $approval.review_id -cne $fixContext.review_id -or
            ($approval.round -isnot [int] -and $approval.round -isnot [long]) -or $approval.round -ne $Round -or
            $approval.issue_ids -isnot [array] -or @($approval.issue_ids | Where-Object { $_ -cnotin $openIds }).Count -gt 0 -or
            @($issueIds | Where-Object { $_ -cnotin $approval.issue_ids }).Count -gt 0 -or
            $approval.decision -isnot [string] -or [string]::IsNullOrWhiteSpace($approval.decision)) {
            $result.problem = New-FixProblem 'review-loop-exceeded' "$showLimit，沒有適用於本次審查與問題 ID 的使用者授權" $limitAction
            return $result
        }
    }

    if ($extra) {
        if ($existing) {
            if ($existing.review_id -cne $fixContext.review_id -or $existing.round -ne $Round -or
                -not (Test-SameFixIds $issueIds $existing.issue_ids)) {
                $result.problem = New-FixProblem 'review-extra-used' "額外輪次必須符合原收據 $($existing.receipt_id) 的審查及必修範圍" '依原授權與收據重試'
                return $result
            }
        } else {
            $spent = @($rounds.normal | Where-Object { $_.round -ge 1 -and $_.round -le $Maximum })
            if ($spent.Count -ne $Maximum -or @($spent.review_id | Sort-Object -CaseSensitive -Unique).Count -ne $Maximum -or
                $fixContext.review_id -cin $spent.review_id) {
                $result.problem = New-FixProblem 'review-loop-not-exhausted' "正常修正輪尚未完整登記，或缺少第 $Maximum 輪後的新 FAIL 審查" '依序完成正常修正與重新審查'
                return $result
            }
        }
        if ($Register) {
            if (-not $existing) {
                $existing = @{
                    receipt_id = [guid]::NewGuid().ToString('N')
                    issue_ids  = @($issueIds)
                    round      = $Round
                    review_id  = $fixContext.review_id
                    attempts   = @()
                }
            }
            $existing.attempts += @{
                attempt_id = [guid]::NewGuid().ToString('N')
                status = 'pending'
                registered_at = [datetime]::UtcNow.ToString('o')
                session_id = [string]$HookPayload.session_id
                turn_id = [string]$HookPayload.turn_id
                tool_use_id = [string]$HookPayload.tool_use_id
            }
            $rounds.extra = $existing
            $result.receipt = Get-FixReceiptOutput $existing
        }
    } else {
        $prior = $rounds.normal | Where-Object { $_.round -eq $Round }
        # Retrying a normal round on the same evidence keeps its existing entry.
        if ($prior -and $Round -eq $rounds.normal.Count -and $prior.review_id -ceq $fixContext.review_id -and
            (Test-SameFixIds $issueIds $prior.issue_ids)) { return $result }
        if ($prior -or $Round -ne ($rounds.normal.Count + 1) -or $fixContext.review_id -cin $rounds.normal.review_id) {
            $result.problem = New-FixProblem 'review-round-sequence' "本迭代下一個正常修正輪為 $($rounds.normal.Count + 1)，每輪須對應新的 FAIL 審查" '核對已登記輪次並完成重審，再用相符的 round 委派'
            return $result
        }
        $stuck = @(Get-StuckFixIds $rounds.normal $Round $issueIds)
        if ($stuck.Count -and (Get-FixField $Prompt 'stuck-approved') -cne 'yes') {
            $result.problem = New-FixProblem 'review-item-stuck' "修了兩輪仍待修：$($stuck -join '、')" '交回使用者裁定；同意繼續才在 handoff 加 stuck-approved: yes'
            return $result
        }
        if ($Register) { $rounds.normal += @{ round = $Round; review_id = $fixContext.review_id; issue_ids = @($issueIds) } }
    }
    if ($Register) {
        $ledger.iterations[$iteration] = $rounds
        Write-FixLedger $path $ledger
    }
    return $result
}

function Set-FixDispatchStatus {
    param(
        [string]$WorkspaceRoot, [string]$FeatureId, [string]$ReceiptId, [string]$AttemptId,
        [string]$Status, [string]$Evidence
    )
    $path = Get-FixLedgerPath $WorkspaceRoot $FeatureId
    if (-not [IO.File]::Exists($path)) { throw '找不到修正輪收據。' }
    Invoke-WithReviewStateLock (Get-ReviewFeatureDir $WorkspaceRoot $FeatureId) {
        $ledger = Read-FixLedger $path $FeatureId
        $receipt = $ledger.iterations.Values.extra | Where-Object { $_.receipt_id -ceq $ReceiptId } | Select-Object -First 1
        if (-not $receipt) { throw '找不到修正輪收據。' }
        $attempt = $receipt.attempts[-1]
        if ($attempt.attempt_id -cne $AttemptId -or $attempt.status -cne 'pending') { throw '收據與待確認的委派嘗試不符。' }
        $attempt.status = if ($Status -eq 'Sent') { 'sent' } else { 'not-sent' }
        $attempt.evidence = $Evidence
        $attempt.confirmed_at = [datetime]::UtcNow.ToString('o')
        Write-FixLedger $path $ledger
        Get-FixReceiptOutput $receipt
    }
}

# The legacy history is a hint for ordinary rounds that started before review
# evidence existed. Its filename-only entries cannot authorize an extra round.
function Test-LegacyFixRound {
    param([string]$WorkspaceRoot, [string]$FeatureId, [int]$Round, [string]$Prompt, [bool]$Register)
    $featureDir = Join-Path $WorkspaceRoot "bdd-docs/$FeatureId"
    $reviewPath = Join-Path $featureDir 'review.md'
    if (-not [IO.File]::Exists($reviewPath)) { return }
    try {
        $review = [IO.File]::ReadAllText($reviewPath)
        if ($review -notmatch '(?m)^\s*VERDICT\s*:\s*FAIL\b') { return }
        $files = @([regex]::Matches($review, '(?m)^[ \t]*\d+\.[ \t]+\[必修\][ \t]+(.+?)[ \t]+——[ \t]+') |
            ForEach-Object { $_.Groups[1].Value.Trim().Trim([char]96, '{', '}') -replace '(:\d+(-\d+)?)+$', '' } |
            Select-Object -Unique)
        $path = Join-Path $featureDir 'reviews/fix-rounds.json'
        $rounds = @{}
        if ($Round -gt 1 -and [IO.File]::Exists($path)) {
            $old = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
            foreach ($entry in $old.rounds.PSObject.Properties) {
                if ([int]$entry.Name -lt $Round) { $rounds[[int]$entry.Name] = @($entry.Value) }
            }
        }
        $stuck = @($files | Where-Object { $Round -gt 2 -and $_ -cin $rounds[$Round - 1] -and $_ -cin $rounds[$Round - 2] })
        if ($stuck.Count -and (Get-FixField $Prompt 'stuck-approved') -cne 'yes') {
            return New-FixProblem 'review-item-stuck' "同一個檔的 [必修] 修了兩輪還在：$($stuck -join '、')" '交回使用者裁定；同意繼續才在 handoff 加 stuck-approved: yes'
        }
        if ($Register) {
            $rounds[$Round] = $files
            $ordered = [ordered]@{}
            foreach ($number in ($rounds.Keys | Sort-Object)) { $ordered[[string]$number] = @($rounds[$number]) }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            Write-FixLedger $path ([ordered]@{ 'feature-id' = $FeatureId; rounds = $ordered })
        }
    } catch {
        # Filename history predates the verified ledger. Old workspaces may
        # still finish their normal rounds if this optional hint is unavailable.
    }
}
