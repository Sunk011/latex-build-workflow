#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Ask', 'Skip')][string]$CommitMode = 'Ask',
    [switch]$CleanOnly,
    [switch]$NoSyncTeX
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/latex-common.ps1"
. "$PSScriptRoot/hooks/before-build.ps1"

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$configFile = Join-Path $root 'latex-build.json'
if (-not (Test-Path -LiteralPath $configFile)) { throw 'Missing latex-build.json. Run install.ps1 first.' }
$config = Get-Content -Raw -LiteralPath $configFile | ConvertFrom-Json
$source = Assert-ThesisChildPath $root (Join-Path $root $config.rootFile)
if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or [IO.Path]::GetExtension($source) -ne '.tex') {
    throw 'rootFile must point to an existing .tex file inside this repository.'
}
$job = [IO.Path]::GetFileNameWithoutExtension($source)
$prefix = [string]$config.pdfPrefix
if ([string]::IsNullOrWhiteSpace($prefix) -or $prefix.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw 'pdfPrefix must be a valid nonempty filename prefix.'
}
$work = Assert-ThesisChildPath $root (Join-Path $root '.build/latex')
$output = Assert-ThesisChildPath $root (Join-Path $root 'pdf')
$buildRoot = Assert-ThesisChildPath $root (Join-Path $root '.build')
$lock = $null
$writer = $null
$oldLocale = @{}
$oldPath = $env:PATH

function Remove-LegacyAuxiliaryFiles {
    # Only this job's known generated files, never arbitrary *.ist or *.bib files.
    $extensions = @('aux','log','acn','acr','alg','glo','gls','glg','ist','lof','lot','loe','lol','nlo','nls','nlg','ilg','idx','ind','thm','toc','out','bbl','blg','bcf','run.xml','fls','fdb_latexmk','xdv','synctex.gz','synctex(busy)')
    foreach ($ext in $extensions) {
        $name = "$job.$ext"
        $file = Assert-ThesisChildPath $root (Join-Path $root $name)
        if (Test-Path -LiteralPath $file) {
            $tracked = Invoke-ThesisGit $root @('ls-files', '--error-unmatch', '--', $name) -AllowFailure
            if ($tracked.ExitCode -ne 0) { Remove-Item -LiteralPath $file -Force }
        }
    }
}

try {
    $null = New-Item -ItemType Directory -Force -Path $buildRoot
    try { $lock = [IO.File]::Open((Join-Path $buildRoot 'build.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw 'Another thesis build/cleanup is running. Wait for it to finish.' }
    if ($CleanOnly) {
        Remove-ThesisBuildTree $root $work
        Remove-LegacyAuxiliaryFiles
        Write-Host 'Auxiliary files cleaned; PDFs and published SyncTeX retained.'
        exit 0
    }
    foreach ($tool in @('git', 'latexmk', 'xelatex', 'bibtex', 'makeindex', 'makeglossaries')) {
        $null = Get-Command $tool -ErrorAction Stop
    }
    $repo = (Invoke-ThesisGit $root @('rev-parse', '--show-toplevel')).Out.Trim()
    if ([IO.Path]::GetFullPath($repo) -ne $root) { throw 'Expected the thesis directory to be the Git repository root.' }
    if (-not (Invoke-ThesisBeforeBuild -Root $root -Mode $CommitMode)) { Write-Host 'Build cancelled.'; exit 2 }
    $head = Invoke-ThesisGit $root @('rev-parse', '--short=7', 'HEAD') -AllowFailure
    $revision = if ($head.ExitCode -eq 0) { $head.Out.Trim() } else { 'unborn' }
    $dirty = @(Get-ThesisChanges $root).Count -gt 0
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    Remove-LegacyAuxiliaryFiles
    Remove-ThesisBuildTree $root $work
    $null = New-Item -ItemType Directory -Force -Path $work
    $writer = [IO.StreamWriter]::new((Join-Path $work 'build.log'), $false, [Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    foreach ($key in @('LC_ALL', 'LC_CTYPE', 'LANG')) {
        $oldLocale[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, 'C', 'Process')
    }
    # Use the selected TeX Live installation's bundled Perl.
    $texBin = Split-Path (Get-Command xelatex).Source
    $env:PATH = $texBin + [IO.Path]::PathSeparator + $env:PATH
    $texRoot = [IO.Path]::GetFullPath((Join-Path $texBin '../..'))
    $perl = Join-Path $texRoot 'tlpkg/tlperl/bin/perl.exe'
    $latexmk = Join-Path $texRoot 'texmf-dist/scripts/latexmk/latexmk.pl'
    $arguments = @('-norc', '-r', '.latex-workflow/latexmkrc', '-xelatex', '-outdir=.build/latex')
    if ($config.shellEscape) { $arguments += '-shell-escape' }
    $arguments += [IO.Path]::GetRelativePath($root, $source).Replace('\', '/')
    Push-Location -LiteralPath $root
    try {
        Write-Host "Building $job.tex (XeLaTeX + BibTeX + glossaries + nomenclature)..."
        if ((Test-Path -LiteralPath $perl) -and (Test-Path -LiteralPath $latexmk)) {
            & $perl $latexmk @arguments 2>&1 | ForEach-Object { $line = $_.ToString(); Write-Host $line; $writer.WriteLine($line) }
        } else {
            & latexmk @arguments 2>&1 | ForEach-Object { $line = $_.ToString(); Write-Host $line; $writer.WriteLine($line) }
        }
        $code = $LASTEXITCODE
    } finally { Pop-Location; $writer.Dispose(); $writer = $null }
    if ($code -ne 0) { throw "LaTeX failed (exit $code). See .build/latex/build.log and $job.log." }
    $pdf = Join-Path $work "$job.pdf"
    if (-not (Test-Path -LiteralPath $pdf) -or (Get-Item -LiteralPath $pdf).Length -lt 100) { throw 'Compiler produced no valid PDF.' }
    $dirty = $dirty -or (@(Get-ThesisChanges $root).Count -gt 0)
    $afterHead = Invoke-ThesisGit $root @('rev-parse', '--short=7', 'HEAD') -AllowFailure
    if ($afterHead.ExitCode -eq 0 -and $afterHead.Out.Trim() -ne $revision) { $dirty = $true }
    $suffix = if ($dirty) { '_dirty' } else { '' }
    $stem = "${prefix}_${stamp}_${revision}${suffix}"
    $null = New-Item -ItemType Directory -Force -Path $output
    $archive = Join-Path $output "$stem.pdf"
    $number = 1
    while (Test-Path -LiteralPath $archive) { $archive = Join-Path $output ("${stem}_$number.pdf"); $number++ }
    [IO.File]::Copy($pdf, $archive, $false)
    $latest = Assert-ThesisChildPath $root (Join-Path $output "$job.pdf")
    $pending = Assert-ThesisChildPath $root (Join-Path $output "$job.pending.pdf")
    Copy-Item -LiteralPath $pdf -Destination $pending -Force
    [IO.File]::Move($pending, $latest, $true)
    $sync = Join-Path $work "$job.synctex.gz"
    $publishedSync = Assert-ThesisChildPath $root (Join-Path $output "$job.synctex.gz")
    if ($config.keepSynctex -and -not $NoSyncTeX -and (Test-Path -LiteralPath $sync)) { Copy-Item -LiteralPath $sync -Destination $publishedSync -Force }
    elseif (Test-Path -LiteralPath $publishedSync) { Remove-Item -LiteralPath $publishedSync -Force }
    Remove-ThesisBuildTree $root $work
    Write-Host "Latest PDF: $latest"
    Write-Host "Archived PDF: $archive"
    Write-Host 'Build succeeded. Auxiliary files removed.'
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
} finally {
    if ($writer) { $writer.Dispose() }
    if ($lock) { $lock.Dispose() }
    $env:PATH = $oldPath
    foreach ($key in $oldLocale.Keys) { [Environment]::SetEnvironmentVariable($key, $oldLocale[$key], 'Process') }
}
