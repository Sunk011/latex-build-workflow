#requires -Version 7.0
Set-StrictMode -Version Latest

function Invoke-ThesisGit {
    param([string]$Root, [string[]]$Arguments, [switch]$AllowFailure)
    $start = [Diagnostics.ProcessStartInfo]::new('git')
    $start.WorkingDirectory = $Root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($arg in @('-c', 'core.quotepath=false') + $Arguments) { $start.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $result = [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
        if ($result.ExitCode -ne 0 -and -not $AllowFailure) { throw "git $($Arguments[0]) failed: $($result.Err)" }
        return $result
    } finally { $process.Dispose() }
}

function Get-ThesisChanges {
    param([string]$Root)
    $result = Invoke-ThesisGit $Root @('status', '--porcelain=v1', '-z', '--untracked-files=all')
    $entries = $result.Out.Split([char]0)
    for ($i = 0; $i -lt $entries.Length; $i++) {
        if ($entries[$i].Length -lt 4) { continue }
        $status = $entries[$i].Substring(0, 2)
        $path = $entries[$i].Substring(3)
        $paths = @($path)
        if ($status -match '[RC]') { $i++; $paths += $entries[$i] }
        if ($path -match '^(pdf|\.build)/') { continue }
        [pscustomobject]@{ Status = $status; Path = $path; Paths = $paths; Label = "$status  $path" }
    }
}

function Assert-ThesisChildPath {
    param([string]$Root, [string]$Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing operation outside project: $full"
    }
    $current = $full
    while ($current.Length -gt $rootFull.Length) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -Force -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing linked build/output path: $current"
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    return $full
}

function Remove-ThesisBuildTree {
    param([string]$Root, [string]$Path)
    $full = Assert-ThesisChildPath $Root $Path
    if (Test-Path -LiteralPath $full) {
        $links = @(Get-ChildItem -Force -Recurse -LiteralPath $full | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($links.Count) { throw "Refusing cleanup of a directory containing links: $full" }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

function Save-ThesisCommit {
    param([string]$Root, [string[]]$Paths, [string]$Message)
    if (-not $Paths.Count -or [string]::IsNullOrWhiteSpace($Message)) { throw 'Select files and enter a commit message.' }
    $tempIndex = Join-Path ([IO.Path]::GetTempPath()) ('thesis-index-' + [guid]::NewGuid().ToString('N'))
    $previousIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $tempIndex
        $head = Invoke-ThesisGit $Root @('rev-parse', '--verify', 'HEAD') -AllowFailure
        if ($head.ExitCode -eq 0) { $null = Invoke-ThesisGit $Root @('read-tree', 'HEAD') }
        else { $null = Invoke-ThesisGit $Root @('read-tree', '--empty') }
        $literalPaths = @($Paths | ForEach-Object { ':(literal)' + $_ })
        $null = Invoke-ThesisGit $Root (@('add', '-A', '--') + $literalPaths)
        $diff = Invoke-ThesisGit $Root @('diff', '--cached', '--quiet') -AllowFailure
        if ($diff.ExitCode -eq 0) { Write-Host 'Selected files contain no changes to commit.'; return }
        if ($diff.ExitCode -ne 1) { throw $diff.Err }
        $result = Invoke-ThesisGit $Root @('commit', '-m', $Message)
        Write-Host $result.Out.Trim()
    } finally {
        $env:GIT_INDEX_FILE = $previousIndex
        foreach ($file in @($tempIndex, "$tempIndex.lock")) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
    }
    $null = Invoke-ThesisGit $Root (@('reset', '--quiet', 'HEAD', '--') + $literalPaths)
}
