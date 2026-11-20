# Record step ③ approval and review attempts. delivery-check reads the resulting evidence without writing.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Approve', 'Start', 'Complete')][string]$Action,
    [Parameter(Mandatory)][string]$FeatureId,
    [ValidateSet('spec', 'code', 'minimal')][string]$Mode,
    [ValidateSet('low', 'general', 'high')][string]$Risk,
    [string[]]$Scope,
    [string[]]$Contract,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$SpecReviewId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$ReviewId,
    [string]$DocsRoot = 'bdd-docs',
    [switch]$Incomplete,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/review-state.ps1')

# Keep JSON readable through Windows PowerShell pipelines with a non-UTF-8 console.
if ([Console]::IsOutputRedirected) {
    $writer = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), [Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    [Console]::SetOut($writer)
}

function Format-ReviewResult($Attempt) {
    return @{
        passed = $true; review_id = $Attempt.id; mode = $Attempt.mode
        status = $Attempt.status; iteration = $Attempt.iteration; verdict = $Attempt.verdict
    }
}

function Test-ReviewAttemptCurrent($Attempt, $Spec, $Approval, [string]$Workspace) {
    if ($Attempt.iteration -ne $Spec.iteration -or $Attempt.spec_hash -cne $Spec.hash) { return $false }
    if ($Attempt.mode -eq 'spec') {
        $contracts = @(Get-ReviewContracts $Workspace @($Attempt.contracts | ForEach-Object path))
        return (ConvertTo-ReviewFingerprint $contracts) -ceq $Attempt.contract_hash
    }
    if (-not (Test-ReviewApproval $Workspace $Approval $Spec) -or $Attempt.approval_id -cne $Approval.id) { return $false }
    $files = @(Get-ReviewSourceFiles $Workspace $Approval.scope $Approval.bases)
    return (ConvertTo-ReviewFingerprint $files) -ceq $Attempt.scope_hash
}

try {
    $workspace = (Get-Location).Path
    $directory = Get-ReviewFeatureDir $workspace $FeatureId $DocsRoot
    if (-not (Test-Path -LiteralPath (Join-Path $directory 'spec.md') -PathType Leaf)) { throw '找不到本次需求的 spec.md' }
    $result = Invoke-WithReviewStateLock $directory {
        $state = Read-ReviewState $directory
        $spec = Read-ReviewSpec $directory
        $approval = Get-ReviewApproval $state $spec
        switch ($Action) {
            'Approve' {
                if (-not $Scope.Count -or -not $Risk) { throw '登記核准時須提供 -Scope 及 -Risk' }
                $scopePaths = @($Scope | ForEach-Object { ConvertTo-ReviewPath $_ } | Sort-Object -CaseSensitive -Unique)
                $contracts = @(Get-ReviewContracts $workspace $Contract)
                $contractHash = ConvertTo-ReviewFingerprint $contracts
                if ($SpecReviewId) {
                    $record = Get-ReviewLatest $state @('spec') $spec.iteration
                    $report = Get-ReviewReportPath $directory 'spec'
                    if (-not $record -or $record.id -cne $SpecReviewId -or $record.verdict -ne 'PASS' -or
                        $record.spec_hash -cne $spec.hash -or $record.contract_hash -cne $contractHash -or
                        -not (Test-Path -LiteralPath $report -PathType Leaf) -or (Get-ReviewFileHash $report) -cne $record.report_hash) {
                        throw '規格核准須引用同一草案與契約版本的規格審查 PASS'
                    }
                }
                if ($approval -and $approval.spec_hash -ceq $spec.hash -and $approval.contract_hash -ceq $contractHash -and
                    $approval.risk -eq $Risk -and $approval.spec_review_id -eq $SpecReviewId -and
                    ($approval.scope -join "`n") -ceq ($scopePaths -join "`n")) {
                    return @{ passed = $true; approval_id = $approval.id; iteration = $spec.iteration }
                }
                $bases = @(Get-ReviewBases $workspace $scopePaths)
                foreach ($base in $bases) {
                    $original = $approval.bases | Where-Object path -ceq $base.path | Select-Object -First 1
                    if ($original) { $base.commit = $original.commit }
                }
                $id = [Guid]::NewGuid().ToString('N')
                $state.approvals += @{
                    id = $id; iteration = $spec.iteration; spec_hash = $spec.hash; risk = $Risk
                    scope = $scopePaths; bases = $bases; contracts = $contracts; contract_hash = $contractHash
                    spec_review_id = $SpecReviewId
                }
                Write-ReviewState $directory $state
                return @{ passed = $true; approval_id = $id; iteration = $spec.iteration }
            }
            'Start' {
                if (-not $Mode) { throw '開始審查時須提供 -Mode' }
                $attempt = @{
                    id = [Guid]::NewGuid().ToString('N'); mode = $Mode; iteration = $spec.iteration; status = 'started'
                    spec_hash = $spec.hash; issues = @()
                }
                $families = if ($Mode -eq 'spec') { @('spec') } else { @('code', 'minimal') }
                $pending = $state.reviews | Where-Object {
                    $_.iteration -eq $spec.iteration -and $_.mode -in $families -and $_.status -eq 'started'
                } | Select-Object -Last 1
                if ($pending) { throw "先完成或標記原嘗試中斷：$($pending.id)" }
                $previous = Get-ReviewLatest $state $families
                if ($Mode -eq 'spec') {
                    $attempt.contracts = @(Get-ReviewContracts $workspace $Contract)
                    $attempt.contract_hash = ConvertTo-ReviewFingerprint $attempt.contracts
                } else {
                    if (-not (Test-ReviewApproval $workspace $approval $spec)) { throw '請先登記本次核准的規格及契約版本' }
                    $attempt.approval_id = $approval.id
                    $attempt.files = @(Get-ReviewSourceFiles $workspace $approval.scope $approval.bases)
                    $attempt.scope_hash = ConvertTo-ReviewFingerprint $attempt.files
                    if ($Mode -eq 'minimal') {
                        if (-not (Test-MinimalReview $state $spec $approval $attempt)) {
                            throw '最小審核須有相同版本的兩次連續未完成紀錄、適用風險及使用者同意'
                        }
                        $attempt.minimal_hash = Get-ReviewHash (Get-MinimalReviewNotes $spec)
                    }
                }
                $state.reviews += $attempt
                Write-ReviewState $directory $state
                $response = Format-ReviewResult $attempt
                $response.issue_ids = @($state.reviews | ForEach-Object { $_.issues } | ForEach-Object id | Sort-Object -Unique)
                $response.required_ids = @($previous.issues | Where-Object state -in @('open', 'accepted') | ForEach-Object id)
                $response.changed_files = @(Get-ReviewDiff $previous.files $attempt.files)
                return $response
            }
            'Complete' {
                if (-not $ReviewId) { throw '完成審查時須提供 -ReviewId' }
                $attempt = $state.reviews | Where-Object id -ceq $ReviewId | Select-Object -Last 1
                if (-not $attempt) { throw '找不到本次審查的開始紀錄' }
                if ($attempt.status -ne 'started') {
                    if (($attempt.status -eq 'incomplete' -and $Incomplete) -or
                        ($attempt.status -eq 'completed' -and -not $Incomplete)) { return (Format-ReviewResult $attempt) }
                    throw '審查紀錄已封存'
                }
                $current = $false
                try { $current = Test-ReviewAttemptCurrent $attempt $spec $approval $workspace } catch { }
                if (-not $current) {
                    $attempt.status = 'invalidated'
                    Write-ReviewState $directory $state
                    throw '審查期間的規格、契約或受審檔案已變更，請重新審查'
                }
                $report = Get-ReviewReportPath $directory $attempt.mode
                if ($Incomplete) {
                    if (Test-Path -LiteralPath $report -PathType Leaf) {
                        $lines = @(Get-ReviewSections ([IO.File]::ReadAllText($report)) | ForEach-Object { $_.visible })
                        if (@($lines | Where-Object { $_ -cmatch "^\s*REVIEW-ID\s*:\s*$ReviewId\s*$" }).Count -and
                            @($lines | Where-Object { $_ -cmatch '^\s*VERDICT\s*:\s*(PASS|FAIL)\s*$' }).Count) {
                            throw '本次報告已有正式判定，請直接完成或修正報告'
                        }
                    }
                    $attempt.status = 'incomplete'
                } else {
                    if ($attempt.mode -eq 'spec') {
                        $families = @('spec')
                    } else {
                        if ($attempt.mode -eq 'minimal' -and -not (Test-MinimalReview $state $spec $approval $attempt)) { throw '最小審核證據不足' }
                        $families = @('code', 'minimal')
                    }
                    $previous = Get-ReviewLatest $state $families
                    $ids = @($state.reviews | ForEach-Object { $_.issues } | ForEach-Object id | Sort-Object -Unique)
                    $hash = Get-ReviewFileHash $report
                    $findings = Read-ReviewReport ([IO.File]::ReadAllText($report)) $spec $attempt $previous $ids
                    if ((Get-ReviewFileHash $report) -cne $hash) { throw '審查報告在登記期間變更，請重試' }
                    $attempt.issues = $findings.issues
                    $attempt.verdict = $findings.verdict
                    $attempt.report_hash = $hash
                    $attempt.status = 'completed'
                }
                Write-ReviewState $directory $state
                return (Format-ReviewResult $attempt)
            }
        }
    }
} catch {
    $result = @{ passed = $false; error = $_.Exception.Message }
}

if ($Json) { $result | ConvertTo-Json -Depth 12 -Compress }
elseif ($result.passed) {
    $value = if ($result.review_id) { $result.review_id } else { $result.approval_id }
    "[review-check] $Action $FeatureId — $value"
    if ($result.changed_files.Count) { $result.changed_files | ForEach-Object { "  $_" } }
} else { [Console]::Error.WriteLine("[review-check] $($result.error)") }
exit $(if ($result.passed) { 0 } else { 2 })
