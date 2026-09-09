#Requires -Version 7.0
<#
.SYNOPSIS
    Promotion helper for the SkyMob apt channel (https://apt.skymob.app).

.DESCRIPTION
    Drives the manual side of the release flow: inspect what is published,
    pull a candidate build for testing, and open the pull request that puts a
    version on the channel.

    The boundary this keeps: SkyMobDev/iot-edge cuts releases and knows nothing
    about the channel; this public repository decides what customers receive.
    stable.list is that decision, and every function here reads or edits it.

    The .deb files are downloaded here and committed to this repository, so the
    only thing that ever crosses from private to public is a person running
    these commands with their own GitHub access. CI holds no credential for
    iot-edge and cannot reach it.

    Requires the GitHub CLI, authenticated with read access to the (private)
    iot-edge repository.

.EXAMPLE
    Import-Module .\Promote.psm1 -Force

    Get-AptChannel                                  # every package: published vs. upstream
    Get-AptChannel      -Package skprinter          # just the one
    Save-AptCandidate   -Package skbridge -Version 0.1.41        # .deb to test with
    New-AptPromotion    -Package skbridge -Version 0.1.41        # branch + commit
    New-AptPromotion    -Package skbridge -Version 0.1.41 -Push  # ...and open the PR
    Test-AptChannel                                 # what the live channel serves
    Remove-AptPromotion -Package skbridge -Version 0.1.41 -Push  # roll it back off
#>

$script:RepoRoot      = $PSScriptRoot
$script:ChannelFile   = Join-Path $PSScriptRoot 'stable.list'
$script:Upstream      = 'SkyMobDev/iot-edge'
$script:ChannelUrl    = 'https://apt.skymob.app'
$script:Suite         = 'stable'
$script:Architectures = @('amd64', 'arm64')

# Upstream tags are named for the project that builds them, which is not always
# the Debian package that project produces. SKPrinter.Appliance tags as
# skprinter-appliance and installs as skprinter — and skprinter-v* is a
# different product, the Windows SKPrinter, whose releases carry no .deb at all.
# Every lookup that reaches for a release goes through Get-ReleaseTag, so the
# two names are only related here.
$script:ReleaseTagPrefix = [ordered]@{
    skbridge  = 'skbridge'
    skprinter = 'skprinter-appliance'
}

# The index is re-signed weekly, so anything older than this means at least one
# cycle was missed. GitHub neither retries nor backfills a dropped schedule.
$script:MaxSignedAgeDays = 10

function Get-AptChannel {
    <#
    .SYNOPSIS
        Lists every upstream release of a package and whether it is published.
        With no -Package, reports on every package the channel knows about.
    #>
    [CmdletBinding()]
    param([string]$Package)

    if (-not $Package) {
        return @($script:ReleaseTagPrefix.Keys | ForEach-Object { Get-AptChannel -Package $_ })
    }

    $prefix = Get-ReleaseTagPrefix -Package $Package
    $published = @(Read-ChannelFile | Where-Object Package -EQ $Package).Version

    $tags = gh release list --repo $script:Upstream --limit 100 --json tagName `
        --jq ".[].tagName | select(startswith(`"$prefix-v`"))" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh release list failed: $tags" }

    @($tags) |
        ForEach-Object { $_ -replace "^$prefix-v", '' } |
        Sort-Object -Descending -Property @{ Expression = { ConvertTo-SortableVersion $_ } }, @{ Expression = { $_ } } |
        ForEach-Object {
            [pscustomobject]@{
                Package = $Package
                Version = $_
                Status  = if ($published -contains $_) { 'published' } else { 'available' }
            }
        }
}

function Save-AptCandidate {
    <#
    .SYNOPSIS
        Downloads a release's .deb files so they can be tested before promotion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Package,
        [string]$Path = (Join-Path $script:RepoRoot 'candidates')
    )

    Assert-ReleaseAssets -Package $Package -Version $Version
    $tag = Get-ReleaseTag -Package $Package -Version $Version

    $dest = Join-Path $Path "$Package-$Version"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    gh release download $tag --repo $script:Upstream `
        --pattern "${Package}_${Version}_*.deb" --dir $dest --clobber 2>&1 | Write-Verbose
    if ($LASTEXITCODE -ne 0) { throw "gh release download failed for $tag" }

    Write-Host "==> $Package $Version" -ForegroundColor Cyan
    Get-ChildItem -LiteralPath $dest -Filter '*.deb' |
        ForEach-Object { Write-Host "    $($_.Name)  ($([math]::Round($_.Length / 1MB, 1)) MB)" }
    Write-Host "    on a Debian 13 VM: sudo apt install ./${Package}_${Version}_amd64.deb" -ForegroundColor DarkGray
}

function New-AptPromotion {
    <#
    .SYNOPSIS
        Puts a version on the channel: edits stable.list on a branch, and with
        -Push opens the pull request whose merge publishes it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Package,

        # Versions of this package kept in the pool. Two is the minimum that
        # leaves a site somewhere to go back to: apt can only downgrade to a
        # version the pool still carries.
        [int]$Keep = 2,

        [switch]$Push
    )

    Assert-CleanMain
    Assert-ReleaseAssets -Package $Package -Version $Version

    $entries = Read-ChannelFile
    if ($entries | Where-Object { $_.Package -eq $Package -and $_.Version -eq $Version }) {
        throw "$Package $Version is already on the channel"
    }

    $existing = @($entries | Where-Object Package -EQ $Package)
    $promoted = @(
        [pscustomobject]@{ Package = $Package; Version = $Version }
        $existing
    ) | Select-Object -First $Keep
    $dropped = @($entries | Where-Object Package -EQ $Package | Where-Object {
            $_.Version -notin $promoted.Version
        }).Version
    $updated = @($promoted) + @($entries | Where-Object Package -NE $Package)

    Write-Host "==> promoting $Package $Version" -ForegroundColor Cyan
    Write-Host "    channel becomes: $(($promoted | ForEach-Object { $_.Version }) -join ', ')"
    if ($dropped) { Write-Host "    leaving the pool: $($dropped -join ', ')" -ForegroundColor DarkGray }

    $target = "promote/$Package-$Version"
    if (-not $PSCmdlet.ShouldProcess($script:ChannelFile, "promote $Package $Version on branch $target")) {
        return
    }

    $subject = "feat: promove $Package $Version para o canal stable"
    $body = if ($existing) {
        "Sites em Debian 13 passam a receber $Package $Version por ``apt upgrade``."
    }
    else {
        # Nothing to upgrade from on the first promotion: the package only
        # becomes installable once this is published.
        "Primeira versão de $Package no canal. Sites em Debian 13 passam a " +
        "poder instalá-lo com ``apt install $Package``."
    }
    if ($dropped) { $body += "`n`nSai do pool: $($dropped -join ', ')." }
    Submit-ChannelChange -Entries $updated -Branch $target -Subject $subject -Body $body -Push:$Push
}

function Remove-AptPromotion {
    <#
    .SYNOPSIS
        Takes a version off the channel, leaving the pool serving the previous one.

    .DESCRIPTION
        The rollback counterpart of New-AptPromotion. Reverting the promotion
        commit only works while nothing else has touched the manifest since;
        this edits the current state instead, so it works at any distance from
        the promotion.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Package,
        [switch]$Push
    )

    Assert-CleanMain

    $entries = Read-ChannelFile
    if (-not ($entries | Where-Object { $_.Package -eq $Package -and $_.Version -eq $Version })) {
        throw "$Package $Version is not on the channel"
    }

    $updated = @($entries | Where-Object { -not ($_.Package -eq $Package -and $_.Version -eq $Version) })
    $remaining = @($updated | Where-Object Package -EQ $Package).Version
    # An empty channel is worse than a bad version: `apt install` stops
    # resolving at all, including on machines that never took the bad one.
    if (-not $remaining) { throw "that is the only $Package version on the channel; promote a replacement first" }

    Write-Host "==> withdrawing $Package $Version" -ForegroundColor Cyan
    Write-Host "    channel becomes: $($remaining -join ', ')"

    $target = "withdraw/$Package-$Version"
    if (-not $PSCmdlet.ShouldProcess($script:ChannelFile, "withdraw $Package $Version on branch $target")) {
        return
    }

    $fallback = ($remaining | Sort-Object -Descending -Property @{ Expression = { ConvertTo-SortableVersion $_ } })[0]
    $subject = "revert: retira $Package $Version do canal stable"
    $body = "O canal volta a servir $Package $fallback. " +
    "Sites que já atualizaram voltam com ``apt install $Package=$fallback``."
    Submit-ChannelChange -Entries $updated -Branch $target -Subject $subject -Body $body -Push:$Push
}

function Test-AptChannel {
    <#
    .SYNOPSIS
        Reports what the live channel serves and how long its index stays valid.
        Returns $true when the index is fresh and carries every promoted version.
    #>
    [CmdletBinding()]
    param([string]$Url = $script:ChannelUrl)

    $healthy = $true

    $inRelease = Get-TextResource "$Url/dists/$($script:Suite)/InRelease"
    Write-Host "==> $Url ($($script:Suite))" -ForegroundColor Cyan

    # Age is the early signal. Valid-Until only trips once re-signing has been
    # broken for most of the window, by which point the schedule has usually
    # been dead for months; a stale signing date says so within days.
    $signedAge = ([datetime]::UtcNow - (ConvertFrom-ReleaseDate (Read-ReleaseField $inRelease 'Date'))).TotalDays
    $stale = $signedAge -gt $script:MaxSignedAgeDays
    Write-Host "    signed:      $([math]::Round($signedAge, 1)) days ago" `
        -ForegroundColor $(if ($stale) { 'Red' } else { 'DarkGray' })
    if ($stale) {
        Write-Warning ("last signed $([math]::Round($signedAge, 1)) days ago — the weekly publish " +
            "workflow has missed a cycle. Check that it is not disabled (GitHub turns off " +
            "schedules after 60 days of repository inactivity).")
        $healthy = $false
    }

    $validUntil = Read-ReleaseField $inRelease 'Valid-Until'
    $remaining = ((ConvertFrom-ReleaseDate $validUntil) - [datetime]::UtcNow).TotalDays
    $colour = if ($remaining -lt 14) { 'Red' } else { 'DarkGray' }
    Write-Host "    valid until: $validUntil ($([math]::Round($remaining, 1)) days)" -ForegroundColor $colour
    if ($remaining -lt 14) {
        Write-Warning "index expires in under two weeks — publish now or apt update starts failing everywhere."
        $healthy = $false
    }

    $promoted = Read-ChannelFile
    foreach ($arch in $script:Architectures) {
        $packages = Get-TextResource "$Url/dists/$($script:Suite)/main/binary-$arch/Packages"
        $served = @($packages -split '\r?\n\r?\n' | Where-Object { $_.Trim() } | ForEach-Object {
                [pscustomobject]@{
                    Package = Read-ReleaseField $_ 'Package'
                    Version = Read-ReleaseField $_ 'Version'
                }
            })
        Write-Host "    $arch : $(($served | ForEach-Object { "$($_.Package) $($_.Version)" }) -join ', ')"

        foreach ($entry in $promoted) {
            $match = $served | Where-Object { $_.Package -eq $entry.Package -and $_.Version -eq $entry.Version }
            if (-not $match) {
                Write-Warning "$($entry.Package) $($entry.Version) is in stable.list but absent from $arch — publish not run since the last promotion?"
                $healthy = $false
            }
        }
    }

    return $healthy
}

function Assert-CleanMain {
    $status = git -C $script:RepoRoot status --porcelain
    if ($status) { throw "working tree is dirty; commit or stash first" }

    $branch = git -C $script:RepoRoot branch --show-current
    if ($branch -ne 'main') { throw "run this from main, not '$branch'" }
}

function Submit-ChannelChange {
    param(
        [Parameter(Mandatory)][pscustomobject[]]$Entries,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,
        [switch]$Push
    )

    # --no-track: main is the base, not the upstream — the branch pushes to its
    # own remote ref.
    git -C $script:RepoRoot switch --create $Branch --no-track
    if ($LASTEXITCODE -ne 0) { throw "git switch failed" }

    Write-ChannelFile -Entries $Entries
    Sync-Pool -Entries $Entries
    # --all so the withdrawn version's .deb files are staged as deletions.
    git -C $script:RepoRoot add --all stable.list pool
    if ($LASTEXITCODE -ne 0) { throw "git add failed" }

    git -C $script:RepoRoot commit -m $Subject -m $Body
    if ($LASTEXITCODE -ne 0) { throw "git commit failed" }
    Write-Host "Committed on $Branch" -ForegroundColor Green

    if (-not $Push) {
        Write-Host "When ready: re-run with -Push, or push $Branch and open the PR yourself" -ForegroundColor DarkGray
        return
    }

    git -C $script:RepoRoot push --set-upstream origin $Branch
    if ($LASTEXITCODE -ne 0) { throw "git push failed" }

    Push-Location $script:RepoRoot
    try {
        gh pr create --base main --head $Branch --title $Subject --body $Body
        if ($LASTEXITCODE -ne 0) { throw "gh pr create failed" }
    }
    finally { Pop-Location }

    Write-Host "Merging that PR publishes the channel. Squash with the commit subject as the title." -ForegroundColor Green
}

function Get-PoolPath {
    param([Parameter(Mandatory)][string]$Package)

    Join-Path $script:RepoRoot "pool/main/$($Package.Substring(0, 1))/$Package"
}

function Get-ReleaseTagPrefix {
    param([Parameter(Mandatory)][string]$Package)

    $prefix = $script:ReleaseTagPrefix[$Package]
    # Refusing an unmapped package is the point: guessing the prefix from the
    # package name is what would send skprinter to the Windows release line.
    if (-not $prefix) {
        throw ("unknown package '$Package' — add it to `$script:ReleaseTagPrefix " +
            "with the tag prefix iot-edge releases it under (known: " +
            "$($script:ReleaseTagPrefix.Keys -join ', '))")
    }
    return $prefix
}

function Get-ReleaseTag {
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$Version
    )

    "$(Get-ReleaseTagPrefix -Package $Package)-v$Version"
}

function Sync-Pool {
    <#
    .SYNOPSIS
        Makes the committed pool hold exactly the .deb files the manifest names.
    #>
    param([Parameter(Mandatory)][pscustomobject[]]$Entries)

    $wanted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Entries) {
        $dir = Get-PoolPath -Package $entry.Package
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        foreach ($arch in $script:Architectures) {
            $file = "$($entry.Package)_$($entry.Version)_$arch.deb"
            [void]$wanted.Add($file)
            if (Test-Path -LiteralPath (Join-Path $dir $file)) { continue }

            Write-Host "    fetching $file" -ForegroundColor DarkGray
            $tag = Get-ReleaseTag -Package $entry.Package -Version $entry.Version
            gh release download $tag --repo $script:Upstream `
                --pattern $file --dir $dir --clobber 2>&1 | Write-Verbose
            if ($LASTEXITCODE -ne 0) { throw "gh release download failed for $file" }
        }
    }

    $pool = Join-Path $script:RepoRoot 'pool'
    if (-not (Test-Path -LiteralPath $pool)) { return }
    foreach ($stale in Get-ChildItem -LiteralPath $pool -Filter '*.deb' -Recurse -File) {
        if ($wanted.Contains($stale.Name)) { continue }
        Write-Host "    removing $($stale.Name)" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $stale.FullName -Force
    }
}

function Read-ChannelFile {
    $entries = foreach ($line in Get-Content -LiteralPath $script:ChannelFile) {
        $stripped = ($line -replace '#.*', '').Trim()
        if (-not $stripped) { continue }
        $parts = $stripped -split '\s+'
        if ($parts.Count -ne 2) { throw "malformed stable.list entry: '$line'" }
        [pscustomobject]@{ Package = $parts[0]; Version = $parts[1] }
    }
    return @($entries)
}

function Write-ChannelFile {
    param([Parameter(Mandatory)][pscustomobject[]]$Entries)

    $header = [System.Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $script:ChannelFile) {
        if (($line -replace '#.*', '').Trim()) { break }
        $header.Add($line.TrimEnd())
    }
    while ($header.Count -gt 0 -and -not $header[$header.Count - 1]) {
        $header.RemoveAt($header.Count - 1)
    }

    $lines = @($header) + @('') + @($Entries | ForEach-Object { "$($_.Package) $($_.Version)" })
    # LF explicitly: the publish workflow reads this file line by line, and a
    # trailing CR would ride along inside the version into the release tag it
    # builds from it.
    [System.IO.File]::WriteAllText($script:ChannelFile, ($lines -join "`n") + "`n")
}

function Assert-ReleaseAssets {
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$Version
    )

    $tag = Get-ReleaseTag -Package $Package -Version $Version
    $json = gh release view $tag --repo $script:Upstream --json assets 2>&1
    if ($LASTEXITCODE -ne 0) { throw "release '$tag' not found on $($script:Upstream): $json" }

    $names = ($json | ConvertFrom-Json).assets.name
    foreach ($arch in $script:Architectures) {
        $expected = "${Package}_${Version}_$arch.deb"
        if ($names -notcontains $expected) {
            throw "release '$tag' carries no $expected — did the linux publish leg fail?"
        }
    }
}

function Get-TextResource {
    <#
    .SYNOPSIS
        Fetches a repository file as text. Pages serves the index files with a
        binary content type, for which Invoke-WebRequest yields a byte array
        rather than a string.
    #>
    param([Parameter(Mandatory)][string]$Uri)

    $content = (Invoke-WebRequest $Uri).Content
    if ($content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString($content)
    }
    return [string]$content
}

function ConvertFrom-ReleaseDate {
    <#
    .SYNOPSIS
        Parses a Release timestamp as UTC. apt-ftparchive writes Date with a
        numeric offset while the Valid-Until this repository stamps ends in a
        literal "UTC", so both spellings have to parse.
    #>
    param([Parameter(Mandatory)][string]$Value)

    if ($Value.EndsWith(' UTC')) {
        return [datetime]::ParseExact(
            $Value, "ddd, dd MMM yyyy HH:mm:ss 'UTC'",
            [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
            [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    }
    return [datetimeoffset]::Parse($Value, [cultureinfo]::InvariantCulture).UtcDateTime
}

function Read-ReleaseField {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Field
    )

    # Anchored per line: Packages stanzas repeat these names, and an unanchored
    # match would also hit them inside a Description body.
    if ($Text -match "(?m)^$Field`: *(.+?)\s*$") { return $Matches[1] }
    throw "no '$Field' field found"
}

function ConvertTo-SortableVersion {
    param([Parameter(Mandatory)][string]$Version)

    # Sorts on the release part alone; a prerelease suffix would fail the cast,
    # and the secondary string sort orders those among themselves.
    [version](($Version -split '-')[0])
}

Export-ModuleMember -Function Get-AptChannel, Save-AptCandidate, New-AptPromotion,
Remove-AptPromotion, Test-AptChannel, Get-ReleaseTag
