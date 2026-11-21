#requires -Version 7.0
# Integration checks use disposable repositories; never commit in the thesis repo.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/../template/.latex-workflow/latex-common.ps1"
. "$PSScriptRoot/../template/.latex-workflow/hooks/before-build.ps1"
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('thesis-workflow-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
function Assert-Check([bool]$Condition, [string]$Description) {
    if (-not $Condition) { throw "FAIL: $Description" }
    Write-Host "PASS: $Description"
}
try {
    $null = Invoke-ThesisGit $fixture @('init', '-q')
    foreach ($pair in @(@('user.name','Workflow Test'), @('user.email','workflow@example.invalid'), @('commit.gpgsign','false'), @('core.autocrlf','false'))) {
        $null = Invoke-ThesisGit $fixture @('config', $pair[0], $pair[1])
    }
    Set-Content -LiteralPath (Join-Path $fixture 'selected.tex') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $fixture 'unrelated.tex') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $fixture 'rename.tex') -Value 'rename'
    Set-Content -LiteralPath (Join-Path $fixture 'delete.tex') -Value 'delete'
    Set-Content -LiteralPath (Join-Path $fixture '.gitignore') -Value @('/pdf/','/.build/')
    $null = Invoke-ThesisGit $fixture @('add', '.')
    $null = Invoke-ThesisGit $fixture @('commit', '-qm', 'Initial fixture')
    Assert-Check (@(Get-ThesisChanges $fixture).Count -eq 0) 'Clean working tree'
    Assert-Check (Invoke-ThesisBeforeBuild $fixture Ask) 'Clean tree skips prompt'
    Set-Content -LiteralPath (Join-Path $fixture 'selected.tex') -Value 'selected edit'
    Set-Content -LiteralPath (Join-Path $fixture 'unrelated.tex') -Value 'unrelated staged edit'
    $null = Invoke-ThesisGit $fixture @('add', 'unrelated.tex')
    $stagingBefore = (Invoke-ThesisGit $fixture @('diff', '--cached', '--binary')).Out
    $special = '新增 [1] 文件.tex'
    Set-Content -LiteralPath (Join-Path $fixture $special) -Value 'unicode filename'
    $null = Invoke-ThesisGit $fixture @('mv', 'rename.tex', 'renamed.tex')
    Remove-Item -LiteralPath (Join-Path $fixture 'delete.tex')
    $changes = @(Get-ThesisChanges $fixture)
    Assert-Check ($changes.Path -contains $special) 'UTF-8 and bracket filenames'
    $rename = @($changes | Where-Object Status -Match R)[0]
    Assert-Check ($rename.Paths -contains 'rename.tex' -and $rename.Paths -contains 'renamed.tex') 'Rename parser includes both paths'
    Assert-Check (Invoke-ThesisBeforeBuild $fixture Skip) 'Skip mode does not show prompt'
    $hook = Join-Path $fixture '.git/hooks/pre-commit'
    [IO.File]::WriteAllText($hook, "#!/bin/sh`nprintf 'hook ran' > .build-hook-marker`n", [Text.UTF8Encoding]::new($false))
    $selected = @('selected.tex', $special, 'rename.tex', 'renamed.tex', 'delete.tex')
    Save-ThesisCommit $fixture $selected 'test: selected files only'
    Assert-Check (Test-Path -LiteralPath (Join-Path $fixture '.build-hook-marker')) 'Native pre-commit hook ran'
    Remove-Item -LiteralPath (Join-Path $fixture '.build-hook-marker')
    $after = @(Get-ThesisChanges $fixture)
    Assert-Check ($after.Count -eq 1 -and $after[0].Path -eq 'unrelated.tex' -and $after[0].Status -eq 'M ') 'Only unselected staging remains'
    Assert-Check ((Invoke-ThesisGit $fixture @('diff', '--cached', '--binary')).Out -eq $stagingBefore) 'Unrelated staged content preserved'
    [IO.File]::WriteAllText($hook, "#!/bin/sh`nexit 1`n", [Text.UTF8Encoding]::new($false))
    Set-Content -LiteralPath (Join-Path $fixture 'selected.tex') -Value 'rejected change'
    $headBefore = (Invoke-ThesisGit $fixture @('rev-parse', 'HEAD')).Out
    $failed = $false
    try { Save-ThesisCommit $fixture @('selected.tex') 'Must be rejected' } catch { $failed = $true }
    Assert-Check $failed 'Hook rejection stops commit'
    Assert-Check ((Invoke-ThesisGit $fixture @('rev-parse', 'HEAD')).Out -eq $headBefore) 'Rejected commit leaves HEAD unchanged'
    Assert-Check ((Invoke-ThesisGit $fixture @('diff', '--cached', '--binary')).Out -eq $stagingBefore) 'Rejected commit preserves index'
    Remove-Item -LiteralPath $hook

    # Install into a project with existing JSONC settings, tasks, and latexmkrc.
    $vscode = Join-Path $fixture '.vscode'
    $null = New-Item -ItemType Directory -Path $vscode
    Set-Content -LiteralPath (Join-Path $vscode 'settings.json') -Value '{"editor.fontSize":19, /* existing */ "files.exclude":{"keep-me":true},}'
    Set-Content -LiteralPath (Join-Path $vscode 'tasks.json') -Value '{"version":"2.0.0","tasks":[{"label":"existing","type":"shell","command":"echo","group":{"kind":"build","isDefault":true}}]}'
    Set-Content -LiteralPath (Join-Path $fixture '.latexmkrc') -Value '# Existing custom rules must survive installation.'
    $source = Join-Path $fixture 'paper.tex'
    Set-Content -LiteralPath $source -Value '\documentclass{article}\begin{document}Build fixture.\end{document}'
    $installer = Join-Path $PSScriptRoot '../install.ps1'
    & pwsh -NoProfile -File $installer -TargetPath $fixture -MainFile paper.tex -PdfPrefix 我的文档
    Assert-Check ($LASTEXITCODE -eq 0) 'Installer succeeds on an existing project'
    $settings = Get-Content -Raw -LiteralPath (Join-Path $vscode 'settings.json') | ConvertFrom-Json -AsHashtable
    Assert-Check ($settings['editor.fontSize'] -eq 19 -and $settings['files.exclude']['keep-me']) 'JSONC settings merged without losing unrelated values'
    $tasks = Get-Content -Raw -LiteralPath (Join-Path $vscode 'tasks.json') | ConvertFrom-Json
    Assert-Check ($tasks.tasks.Count -eq 4 -and $tasks.tasks[0].group.isDefault) 'Unrelated default task preserved'
    Assert-Check ((Get-Content -Raw -LiteralPath (Join-Path $fixture '.latexmkrc')).Contains('Existing custom rules')) 'Existing project latexmkrc preserved'
    Assert-Check (@(Get-ChildItem -LiteralPath (Join-Path $fixture '.build/latex-workflow-backups') -Directory).Count -gt 0) 'Installation backs up changed files'
    $runner = Join-Path $fixture '.latex-workflow/build.ps1'
    & pwsh -NoProfile -File $installer -TargetPath $fixture
    Assert-Check ($LASTEXITCODE -eq 0) 'Repeated installation succeeds without Force when runtime is unchanged'
    $config = Get-Content -Raw -LiteralPath (Join-Path $fixture 'latex-build.json') | ConvertFrom-Json
    Assert-Check ($config.rootFile -eq 'paper.tex' -and $config.pdfPrefix -eq '我的文档') 'Update preserves project-specific configuration'
    Add-Content -LiteralPath $runner -Value '# Local customization'
    $settingsHash = (Get-FileHash -LiteralPath (Join-Path $vscode 'settings.json')).Hash
    $runLog = Join-Path $fixture 'test-run.log'
    & pwsh -NoProfile -File $installer -TargetPath $fixture *> $runLog
    Assert-Check ($LASTEXITCODE -ne 0) 'Installer refuses to overwrite customized runtime without Force'
    Assert-Check ((Get-FileHash -LiteralPath (Join-Path $vscode 'settings.json')).Hash -eq $settingsHash) 'Refusal leaves settings untouched'
    & pwsh -NoProfile -File $installer -TargetPath $fixture -Force
    Assert-Check ($LASTEXITCODE -eq 0) 'Force update succeeds with backups'
    # Exercise successful publication, replacement, no-SyncTeX, and error handling.
    & pwsh -NoProfile -File $runner -CommitMode Skip *> $runLog
    if ($LASTEXITCODE -ne 0) { throw (Get-Content -Raw -LiteralPath $runLog) }
    $latest = Join-Path $fixture 'pdf/paper.pdf'
    Assert-Check (Test-Path -LiteralPath $latest) 'Successful build publishes PDF'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $fixture '.build/latex'))) 'Successful build removes intermediate directory'
    Assert-Check (Test-Path -LiteralPath (Join-Path $fixture 'pdf/paper.synctex.gz')) 'SyncTeX retained by default'
    & pwsh -NoProfile -File $runner -CommitMode Skip -NoSyncTeX *> $runLog
    if ($LASTEXITCODE -ne 0) { throw (Get-Content -Raw -LiteralPath $runLog) }
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'pdf/paper.synctex.gz'))) 'Repeat build replaces latest and supports NoSyncTeX'
    $archives = @(Get-ChildItem -LiteralPath (Join-Path $fixture 'pdf') -Filter '*_dirty*.pdf')
    Assert-Check ($archives.Count -eq 2) 'Historical PDFs retained and dirty tagged'
    $hashBefore = (Get-FileHash -LiteralPath $latest).Hash
    Set-Content -LiteralPath $source -Value '\documentclass{article}\begin{document}\IntentionalFailure\end{document}'
    & pwsh -NoProfile -File $runner -CommitMode Skip *> $runLog
    Assert-Check ($LASTEXITCODE -ne 0) 'Broken TeX returns nonzero exit'
    Assert-Check ((Get-FileHash -LiteralPath $latest).Hash -eq $hashBefore) 'Failed build preserves previous PDF'
    Assert-Check (Test-Path -LiteralPath (Join-Path $fixture '.build/latex/build.log')) 'Failed build retains diagnostic log'
    & pwsh -NoProfile -File $runner -CleanOnly *> $runLog
    Assert-Check ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $fixture '.build/latex'))) 'Clean-only removes failed build artifacts'
    Assert-Check ((Get-FileHash -LiteralPath $latest).Hash -eq $hashBefore) 'Clean-only preserves PDF'
    Write-Host 'All workflow integration checks passed.'
} finally {
    # Resolve and check the disposable target before recursive removal.
    Remove-ThesisBuildTree ([IO.Path]::GetTempPath()) $fixture
}
