#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetPath,
    [string]$MainFile,
    [string]$PdfPrefix,
    [switch]$ShellEscape,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/template/.latex-workflow/latex-common.ps1"
$target = (Resolve-Path -LiteralPath $TargetPath).Path.TrimEnd('\','/')
$gitRoot = (Invoke-ThesisGit $target @('rev-parse','--show-toplevel')).Out.Trim()
if ([IO.Path]::GetFullPath($gitRoot) -ne $target) { throw 'TargetPath must be the root of an existing Git repository.' }
if ($target -eq [IO.Path]::GetFullPath($PSScriptRoot)) { throw 'Install into a LaTeX project, not this configuration repository.' }

function Read-JsonMap([string]$RelativePath) {
    $path = Assert-ThesisChildPath $target (Join-Path $target $RelativePath)
    if (Test-Path -LiteralPath $path) { return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable }
    return @{}
}
function Merge-Map($Destination, $Source) {
    foreach ($key in $Source.Keys) {
        if ($Destination[$key] -is [Collections.IDictionary] -and $Source[$key] -is [Collections.IDictionary]) {
            Merge-Map $Destination[$key] $Source[$key]
        } else { $Destination[$key] = $Source[$key] }
    }
}
function To-JsonText($Value) { return ($Value | ConvertTo-Json -Depth 50) + "`n" }

$config = Read-JsonMap 'latex-build.json'
$defaults = @{ rootFile = 'main.tex'; pdfPrefix = '论文'; shellEscape = $false; keepSynctex = $true }
foreach ($key in $defaults.Keys) { if (-not $config.Contains($key)) { $config[$key] = $defaults[$key] } }
if ($PSBoundParameters.ContainsKey('MainFile')) { $config.rootFile = $MainFile.Replace('\','/') }
if ($PSBoundParameters.ContainsKey('PdfPrefix')) { $config.pdfPrefix = $PdfPrefix }
if ($PSBoundParameters.ContainsKey('ShellEscape')) { $config.shellEscape = [bool]$ShellEscape }
$main = Assert-ThesisChildPath $target (Join-Path $target $config.rootFile)
if (-not (Test-Path -LiteralPath $main -PathType Leaf) -or [IO.Path]::GetExtension($main) -ne '.tex') {
    throw 'MainFile must be an existing .tex file inside the target repository.'
}
if ([string]::IsNullOrWhiteSpace($config.pdfPrefix) -or $config.pdfPrefix.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw 'PdfPrefix must be a valid filename prefix.'
}

# Prepare and validate everything before modifying the target.
$planned = [ordered]@{}
$runtime = Join-Path $PSScriptRoot 'template/.latex-workflow'
foreach ($file in Get-ChildItem -LiteralPath $runtime -File -Recurse -Force) {
    $relative = '.latex-workflow/' + [IO.Path]::GetRelativePath($runtime, $file.FullName).Replace('\','/')
    $destination = Assert-ThesisChildPath $target (Join-Path $target $relative)
    $content = [IO.File]::ReadAllText($file.FullName)
    if ((Test-Path -LiteralPath $destination) -and [IO.File]::ReadAllText($destination) -ne $content -and -not $Force) {
        throw "Existing runtime differs: $relative. Review it, then rerun with -Force to back up and replace."
    }
    $planned[$relative] = $content
}
$settings = Read-JsonMap '.vscode/settings.json'
$incoming = Get-Content -Raw -LiteralPath "$PSScriptRoot/template/.vscode/settings.json" | ConvertFrom-Json -AsHashtable
Merge-Map $settings $incoming
$planned['.vscode/settings.json'] = To-JsonText $settings
$tasks = Read-JsonMap '.vscode/tasks.json'
$incomingTasks = Get-Content -Raw -LiteralPath "$PSScriptRoot/template/.vscode/tasks.json" | ConvertFrom-Json -AsHashtable
$existingTasks = @($tasks['tasks'] | Where-Object { $_ -and $_['detail'] -ne 'Managed by latex-build-workflow' })
$hasDefault = @($existingTasks | Where-Object { $_['group'] -is [Collections.IDictionary] -and $_['group']['kind'] -eq 'build' -and $_['group']['isDefault'] }).Count -gt 0
foreach ($task in $incomingTasks.tasks) { if ($hasDefault -and $task['group'] -is [Collections.IDictionary]) { $task.group.isDefault = $false } }
$tasks.version = '2.0.0'
$tasks.tasks = @($existingTasks) + @($incomingTasks.tasks)
$planned['.vscode/tasks.json'] = To-JsonText $tasks
$extensions = Read-JsonMap '.vscode/extensions.json'
$extensions.recommendations = @(@($extensions['recommendations']) + 'james-yu.latex-workshop' | Where-Object { $_ } | Select-Object -Unique)
$planned['.vscode/extensions.json'] = To-JsonText $extensions
$planned['latex-build.json'] = To-JsonText $config
$planned['.latex-workflow/VERSION'] = (Get-Content -Raw -LiteralPath "$PSScriptRoot/VERSION").Trim() + "`n"
$ignorePath = Assert-ThesisChildPath $target (Join-Path $target '.gitignore')
$ignore = if (Test-Path -LiteralPath $ignorePath) { [IO.File]::ReadAllText($ignorePath) } else { '' }
$marker = '# latex-build-workflow outputs and reusable configuration'
if (-not $ignore.Contains($marker)) {
    $ignore += "`n$marker`n/.build/`n/pdf/`n!/.latex-workflow/`n!/.latex-workflow/**`n!/latex-build.json`n!/.vscode/`n!/.vscode/settings.json`n!/.vscode/tasks.json`n!/.vscode/extensions.json`n"
}
$planned['.gitignore'] = $ignore
foreach ($relative in $planned.Keys) { $null = Assert-ThesisChildPath $target (Join-Path $target $relative) }

$backup = Join-Path $target ('.build/latex-workflow-backups/' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = Assert-ThesisChildPath $target $backup
$changed = 0
foreach ($relative in $planned.Keys) {
    $path = Join-Path $target $relative
    if ((Test-Path -LiteralPath $path) -and [IO.File]::ReadAllText($path) -eq $planned[$relative]) { continue }
    if (Test-Path -LiteralPath $path) {
        $backupFile = Join-Path $backup $relative
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $backupFile)
        Copy-Item -LiteralPath $path -Destination $backupFile
    }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $path)
    [IO.File]::WriteAllText($path, $planned[$relative], [Text.UTF8Encoding]::new($false))
    $changed++
}
Write-Host "Installed latex-build-workflow in: $target"
Write-Host "Main file: $($config.rootFile); PDF prefix: $($config.pdfPrefix); files changed: $changed"
if (Test-Path -LiteralPath $backup) { Write-Host "Backups: $backup" }
if ($hasDefault) { Write-Host 'Existing default build task preserved. Select the LaTeX Workflow task explicitly or use Ctrl+Alt+B.' }
Write-Host 'Build: pwsh -NoProfile -STA -File ./.latex-workflow/build.ps1'
