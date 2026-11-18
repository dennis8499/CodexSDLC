# test-commit-check.ps1
# commit-check 是 Codex hooks 跑不起來時（組織政策只允許管理員部署的 hooks）寫檔那三道唯一的機械補位。
# 最危險的失效是「該紅的時候綠」：掃錯了檔（工作區而不是這次要 commit 的）、前後端各一個 repo 時路徑對不上、
# CI 模式取不到分支改過的檔 —— 每一種都不會報錯，只會安靜地什麼都沒查。

$CcScript = (Resolve-Path '.codex/scripts/commit-check.ps1').Path
$CcRoot   = Join-Path ([IO.Path]::GetTempPath()) 'codex-commit-check-tests'
$CcUtf8   = [Text.UTF8Encoding]::new($false)
$CcRules  = '{ "rules": [ { "id": "no-nolock", "severity": "block", "files": ["**/*.sql"], "pattern": "(?i)WITH\\s*\\(\\s*NOLOCK", "message": "禁止 NOLOCK", "fix": "拿掉 NOLOCK" } ] }'

function Write-CcFile([string]$rel, [string]$text) {
    $p = Join-Path $CcRoot $rel
    New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($p, $text, $CcUtf8)
}

function Invoke-CcGit([string]$dir, [string[]]$gitArgs) {
    $null = & git -C (Join-Path $CcRoot $dir) -c user.email=t@t -c user.name=t -c commit.gpgsign=false @gitArgs 2>&1
}

# 一個已經有一次 commit 的專案（工作流的根目錄就是 repo 的根）。
function New-CcProject {
    Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-CcFile 'guidelines/rules.json' $CcRules
    Write-CcFile 'src/ok.sql' "SELECT Id FROM T`n"
    Invoke-CcGit '.' @('init', '-q')
    Invoke-CcGit '.' @('add', '-A')
    Invoke-CcGit '.' @('commit', '-q', '-m', 'base')
}

function Invoke-Cc([hashtable]$extra = @{}) {
    Push-Location $CcRoot
    try {
        $p = @{ Json = $true; NoBuild = $true }
        foreach ($k in $extra.Keys) { $p[$k] = $extra[$k] }
        $r = Invoke-Script $CcScript -Params $p
        $r | Add-Member -NotePropertyName json -NotePropertyValue $(try { $r.stdout | ConvertFrom-Json } catch { $null })
        $r | Add-Member -NotePropertyName codes -NotePropertyValue @($r.json.problems | ForEach-Object { $_.code })
        return $r
    } finally { Pop-Location }
}

Describe-Suite 'commit-check / staged 的檔：該擋的擋、沒 stage 的不管' {

    It-Should 'bdd-docs/ 的檔有 email → exit 2（dlp-residual，列類別與行號、不列原文）' {
        New-CcProject
        try {
            Write-CcFile 'bdd-docs/f/spec.md' "聯絡人：alice@example.com`n"
            Invoke-CcGit '.' @('add', '-A')
            $r = Invoke-Cc
            Assert-Equal 2 $r.exit "stdout: $($r.stdout) stderr: $($r.stderr)"
            Assert-True ('dlp-residual' -in $r.codes)
            Assert-Match 'email' (@($r.json.problems | Where-Object code -eq 'dlp-residual')[0].items -join ' ') '類別沒列出來 —— 人看不出是哪一種'
            Assert-True ($r.stdout -notmatch 'alice@example\.com') '輸出了命中的原文'
        } finally { Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '違反 rules.json 的 block 規則 → exit 2（guideline-block，檔:行）' {
        New-CcProject
        try {
            Write-CcFile 'src/q.sql' "SELECT Id FROM T WITH (NOLOCK)`n"
            Invoke-CcGit '.' @('add', '-A')
            $r = Invoke-Cc
            Assert-Equal 2 $r.exit
            Assert-True ('guideline-block' -in $r.codes)
            Assert-Match 'src/q\.sql:1' (@($r.json.problems)[0].items -join ' ')
        } finally { Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '乾淨的 → exit 0；沒 stage 的違規檔不算（這次不 commit 它）' {
        New-CcProject
        try {
            Write-CcFile 'src/clean.sql' "SELECT Id FROM T`n"
            Invoke-CcGit '.' @('add', 'src/clean.sql')
            Write-CcFile 'src/later.sql' "SELECT Id FROM T WITH (NOLOCK)`n"   # 未追蹤、沒 stage
            $r = Invoke-Cc
            Assert-Equal 0 $r.exit "stdout: $($r.stdout)"
            Assert-Equal 'staged' $r.json.mode
            Assert-True ('src/clean.sql' -in @($r.json.files))
            Assert-True ('src/later.sql' -notin @($r.json.files)) '掃了沒 stage 的檔 —— 擋下的是這次沒要 commit 的東西'
        } finally { Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'stage 之後又改過的檔 → 提醒（掃的是工作區、commit 的是 stage 的那一份）' {
        New-CcProject
        try {
            Write-CcFile 'src/ok.sql' "SELECT Id, Name FROM T`n"
            Invoke-CcGit '.' @('add', 'src/ok.sql')
            Write-CcFile 'src/ok.sql' "SELECT Id, Name, Age FROM T`n"
            $r = Invoke-Cc
            Assert-Equal 0 $r.exit
            Assert-True ('src/ok.sql' -in @($r.json.unstaged))
            Assert-Match 'stage' (@($r.json.notices) -join ' ')
        } finally { Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '刪掉的檔不掃（不存在的檔不是違規，也不能讓它炸掉）' {
        New-CcProject
        try {
            Invoke-CcGit '.' @('rm', '-q', 'src/ok.sql')
            $r = Invoke-Cc
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            Assert-Equal 0 @($r.json.files).Count
        } finally { Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '不帶 -Json：沒過的走 stderr、附 fix；過了一行 OK' {
        New-CcProject
        try {
            Write-CcFile 'src/q.sql' "SELECT Id FROM T WITH (NOLOCK)`n"
            Invoke-CcGit '.' @('add', '-A')
            Push-Location $CcRoot
            try { $r = Invoke-Script $CcScript -Params @{ NoBuild = $true } } finally { Pop-Location }
            Assert-Equal 2 $r.exit
            Assert-Match 'guideline-block' $r.stderr
            Assert-Match 'fix:' $r.stderr
            Invoke-CcGit '.' @('rm', '-q', '--cached', 'src/q.sql')
            Push-Location $CcRoot
            try { $r = Invoke-Script $CcScript -Params @{ NoBuild = $true } } finally { Pop-Location }
            Assert-Equal 0 $r.exit
            Assert-Match '\[commit-check\] OK' $r.stdout
        } finally { Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'commit-check / 前後端各一個 repo、CI 模式' {

    It-Should '工作流裝在上層、repo 在底下：-Repo 指那個 repo，路徑換成相對工作流根目錄（規則與 bdd-docs/ 才對得上）' {
        Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue
        try {
            Write-CcFile 'guidelines/rules.json' $CcRules
            Write-CcFile 'backend/src/q.sql' "SELECT Id FROM T WITH (NOLOCK)`n"
            Invoke-CcGit 'backend' @('init', '-q')
            Invoke-CcGit 'backend' @('add', '-A')
            $r = Invoke-Cc @{ Repo = (Join-Path $CcRoot 'backend') }
            Assert-Equal 2 $r.exit "stdout: $($r.stdout)"
            Assert-True ('backend/src/q.sql' -in @($r.json.files)) "路徑沒換成相對工作流根目錄：$(@($r.json.files) -join ',')"
        } finally { Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '-Base：這個分支改過的檔（已 commit 的也算）；共同祖先之前的不算' {
        New-CcProject
        try {
            Write-CcFile 'src/old.sql' "SELECT Id FROM T WITH (NOLOCK)`n"
            Invoke-CcGit '.' @('add', '-A'); Invoke-CcGit '.' @('commit', '-q', '-m', 'old')
            Invoke-CcGit '.' @('branch', 'main-base')
            Invoke-CcGit '.' @('checkout', '-q', '-b', 'feature')
            Write-CcFile 'src/new.sql' "SELECT Id FROM T WITH (NOLOCK)`n"
            Invoke-CcGit '.' @('add', '-A'); Invoke-CcGit '.' @('commit', '-q', '-m', 'new')
            $r = Invoke-Cc @{ Base = 'main-base' }
            Assert-Equal 2 $r.exit
            Assert-Equal 'base' $r.json.mode
            Assert-True ('src/new.sql' -in @($r.json.files))
            Assert-True ('src/old.sql' -notin @($r.json.files)) '掃到共同祖先之前的檔 —— 既有的違規不是這個分支造成的'
        } finally { Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '-Base 的 ref 不存在 → exit 1，講 fetch-depth（CI 的淺 clone 最常見）' {
        New-CcProject
        try {
            $r = Invoke-Cc @{ Base = 'origin/nope' }
            Assert-Equal 1 $r.exit
            Assert-Match 'fetch-depth' $r.stdout
        } finally { Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '不是 git → exit 1（不能當成「沒有檔要查」而放行）' {
        Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $CcRoot -Force | Out-Null
        try {
            $r = Invoke-Cc
            Assert-Equal 1 $r.exit
        } finally { Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'commit-check / build' {

    It-Should '沒有 production 程式碼 → build 是 none（不能說「通過」）' {
        New-CcProject
        try {
            Write-CcFile 'docs/note.md' "說明`n"
            Invoke-CcGit '.' @('add', '-A')
            $r = Invoke-Cc @{ NoBuild = $false }
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            Assert-Equal 'none' $r.json.gates.build
        } finally { Remove-Item $CcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'build-check -Path：判定跟 hook 的 payload 一樣（測試檔不觸發）' {
        $r = Invoke-Script '.codex/scripts/build-check.ps1' -Params @{ Path = 'src/Orders/OrderService.cs'; WhatIfPaths = $true }
        Assert-Match 'triggering=1' $r.stdout
        $r = Invoke-Script '.codex/scripts/build-check.ps1' -Params @{ Path = 'bdd-docs/f/sample.cs'; WhatIfPaths = $true }
        Assert-Match 'triggering=0' $r.stdout
    }
}
