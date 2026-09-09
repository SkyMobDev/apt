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
    stable.list and beta.list are that decision, and every function here reads
    or edits one of them.

    Two channels, one pool. A site subscribes to stable alone, or to stable and
    beta together, in which case apt takes whichever version is higher and the
    site is a canary. A version normally lands on beta first, soaks, and is then
    moved to stable — Move-AptPromotion does that without downloading anything,
    since the .deb is already in the pool.

    The .deb files are downloaded here and committed to this repository, so the
    only thing that ever crosses from private to public is a person running
    these commands with their own GitHub access. CI holds no credential for
    iot-edge and cannot reach it.

    Requires the GitHub CLI, authenticated with read access to the (private)
    iot-edge repository.

.EXAMPLE
    Import-Module .\Promote.psm1 -Force

    Get-AptChannel                          # every package: which channel, vs. upstream
    Get-AptChannel      -Package skprinter  # just the one

    Save-AptCandidate   -Package skbridge -Version 0.2.0         # .deb to test with
    New-AptPromotion    -Package skbridge -Version 0.2.0 -Channel beta -Push
    #   ...canaries take it, it soaks...
    Move-AptPromotion   -Package skbridge -Version 0.2.0 -Push   # beta -> stable

    Test-AptChannel                                              # what the live channels serve
    Remove-AptPromotion -Package skbridge -Version 0.2.0 -Channel beta -Push
#>

$script:RepoRoot      = $PSScriptRoot
$script:Upstream      = 'SkyMobDev/iot-edge'
$script:ChannelUrl    = 'https://apt.skymob.app'
$script:Architectures = @('amd64', 'arm64')

# Each channel is an apt suite and a manifest of the same name. stable is listed
# first only so reports read in that order; nothing depends on the position.
$script:Channels = @('stable', 'beta')

# stable must never be empty — `apt install` stops resolving entirely, including
# on machines that never took a bad version. beta is allowed to drain to nothing
# between candidates: canaries subscribe to both suites and simply fall through
# to stable, and an empty suite is something apt reads without complaint.
$script:RequiredChannels = @('stable')

# Versions of a package each channel keeps in the pool. apt can only downgrade
# to a version the pool still carries, so this is the depth of a site's retreat.
# stable keeps three: promotions here can skip a long way — 0.1.26 to 0.1.41 was
# fifteen releases — and with two, the only fallback is the version the site is
# leaving, which is no help when that one is the problem. beta keeps one, since
# a canary retreats to stable rather than to an older candidate.
$script:ChannelKeep = @{ stable = 3; beta = 1 }

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
        Lists every upstream release of a package and which channels carry it.
        With no -Package, reports on every package the channel knows about.
    #>
    [CmdletBinding()]
    param([string]$Package)

    if (-not $Package) {
        return @($script:ReleaseTagPrefix.Keys | ForEach-Object { Get-AptChannel -Package $_ })
    }

    $prefix = Get-ReleaseTagPrefix -Package $Package
    $onChannel = @{}
    foreach ($channel in $script:Channels) {
        foreach ($entry in Read-ChannelFile -Channel $channel | Where-Object Package -EQ $Package) {
            $onChannel[$entry.Version] = @($onChannel[$entry.Version]) + $channel |
                Where-Object { $_ }
        }
    }

    # The limit counts releases of every project in iot-edge, not just this
    # package's: skbridge, skprinter, skprinter-appliance, skreceiver and
    # connect all share the tag namespace, so a limit sized for one package
    # would start dropping published versions off the bottom of this report.
    # stderr is kept separate; folded in, a gh warning becomes a bogus version.
    $tags = gh release list --repo $script:Upstream --limit 500 --json tagName `
        --jq ".[].tagName | select(startswith(`"$prefix-v`"))"
    if ($LASTEXITCODE -ne 0) { throw "gh release list failed for $script:Upstream" }

    @($tags) |
        ForEach-Object { $_ -replace "^$prefix-v", '' } |
        Sort-Object -Descending -Property @{ Expression = { ConvertTo-SortableVersion $_ } } |
        ForEach-Object {
            [pscustomobject]@{
                Package = $Package
                Version = $_
                Status  = if ($onChannel.ContainsKey($_)) { $onChannel[$_] -join '+' } else { 'available' }
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
        Puts a version on a channel: edits that channel's manifest on a branch,
        and with -Push opens the pull request whose merge publishes it.

    .DESCRIPTION
        -Channel is required rather than defaulted. The two channels reach very
        different numbers of machines, and a flag you can forget is not the
        thing that should decide which.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][ValidateSet('stable', 'beta')][string]$Channel,

        # Versions of this package this channel keeps in the pool. Defaults per
        # channel: see $script:ChannelKeep. One is the floor: a channel that
        # keeps none of a package is a channel that has just dropped it.
        [ValidateRange(1, 100)][int]$Keep,

        [switch]$Push
    )

    Assert-CleanMain
    Assert-ReleaseAssets -Package $Package -Version $Version
    if (-not $PSBoundParameters.ContainsKey('Keep')) { $Keep = $script:ChannelKeep[$Channel] }

    $entries = Read-ChannelFile -Channel $Channel
    if ($entries | Where-Object { $_.Package -eq $Package -and $_.Version -eq $Version }) {
        throw "$Package $Version is already on $Channel"
    }

    $existing = @($entries | Where-Object Package -EQ $Package)
    $promoted = Select-KeptVersions -Package $Package -Version $Version -Existing $existing -Keep $Keep
    $dropped = @($existing | Where-Object { $_.Version -notin $promoted.Version }).Version
    $updated = @($promoted) + @($entries | Where-Object Package -NE $Package)
    Assert-ChannelKeepsPackage -Channel $Channel -Package $Package -Entries $updated

    Write-Host "==> promoting $Package $Version to $Channel" -ForegroundColor Cyan
    Write-Host "    $Channel becomes: $(($promoted | ForEach-Object { $_.Version }) -join ', ')"
    if ($dropped) { Write-Host "    leaving $Channel : $($dropped -join ', ')" -ForegroundColor DarkGray }

    # apt serves the highest version a suite carries, so promoting below the top
    # publishes the .deb without any site moving to it.
    $isTop = $promoted[0].Version -eq $Version
    if (-not $isTop) {
        Write-Warning ("$Channel already carries $Package $($promoted[0].Version), which is higher — " +
            "no site will move to $Version. It becomes installable by exact version and nothing more.")
    }

    $target = "promote/$Channel-$Package-$Version"
    if (-not $PSCmdlet.ShouldProcess((Get-ChannelFile -Channel $Channel),
            "promote $Package $Version to $Channel on branch $target")) {
        return
    }

    $subject = "feat: promove $Package $Version para o canal $Channel"
    $body = if (-not $isTop) {
        "O canal $Channel já serve $Package $($promoted[0].Version), que é maior, então nenhum " +
        "site muda sozinho: $Version fica instalável por versão exata, com " +
        "``apt install $Package=$Version``."
    }
    elseif ($Channel -eq 'beta') {
        "Sites inscritos no beta passam a receber $Package $Version por ``apt upgrade``. " +
        "O canal stable não muda."
    }
    elseif ($existing) {
        "Sites em Debian 13 passam a receber $Package $Version por ``apt upgrade``."
    }
    else {
        # Nothing to upgrade from on the first promotion: the package only
        # becomes installable once this is published.
        "Primeira versão de $Package no canal. Sites em Debian 13 passam a " +
        "poder instalá-lo com ``apt install $Package``."
    }
    if ($dropped) { $body += "`n`nSai do $Channel : $($dropped -join ', ')." }
    Submit-ChannelChange -Manifests @{ $Channel = $updated } -Branch $target `
        -Subject $subject -Body $body -Push:$Push
}

function Move-AptPromotion {
    <#
    .SYNOPSIS
        Moves a version that has soaked on beta over to stable, without
        downloading anything: the .deb is already in the pool.

    .DESCRIPTION
        The normal end of a candidate's life. It leaves beta as it joins stable,
        because canaries subscribe to both suites and keep receiving it from
        stable — leaving it on both would only pin a second copy in the pool for
        no one's benefit.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Package,
        [ValidateSet('stable', 'beta')][string]$From = 'beta',
        [ValidateSet('stable', 'beta')][string]$To = 'stable',
        [ValidateRange(1, 100)][int]$Keep,
        [switch]$Push
    )

    Assert-CleanMain
    if ($From -eq $To) { throw "-From and -To are both '$From'" }
    if (-not $PSBoundParameters.ContainsKey('Keep')) { $Keep = $script:ChannelKeep[$To] }

    $source = Read-ChannelFile -Channel $From
    if (-not ($source | Where-Object { $_.Package -eq $Package -and $_.Version -eq $Version })) {
        throw "$Package $Version is not on $From"
    }
    $destination = Read-ChannelFile -Channel $To
    if ($destination | Where-Object { $_.Package -eq $Package -and $_.Version -eq $Version }) {
        throw "$Package $Version is already on $To"
    }

    $existing = @($destination | Where-Object Package -EQ $Package)
    $promoted = Select-KeptVersions -Package $Package -Version $Version -Existing $existing -Keep $Keep
    $dropped = @($existing | Where-Object { $_.Version -notin $promoted.Version }).Version

    $sourceUpdated = @($source | Where-Object {
            -not ($_.Package -eq $Package -and $_.Version -eq $Version)
        })
    $destinationUpdated = @($promoted) + @($destination | Where-Object Package -NE $Package)
    # Moving out of a required channel is the one direction that can strand a
    # fleet: it removes the version rather than adding one.
    Assert-ChannelKeepsPackage -Channel $From -Package $Package -Entries $sourceUpdated
    Assert-ChannelKeepsPackage -Channel $To -Package $Package -Entries $destinationUpdated

    Write-Host "==> moving $Package $Version from $From to $To" -ForegroundColor Cyan
    Write-Host "    $To becomes: $(($promoted | ForEach-Object { $_.Version }) -join ', ')"
    $left = @($sourceUpdated | Where-Object Package -EQ $Package).Version
    Write-Host "    $From becomes: $(if ($left) { $left -join ', ' } else { '(empty for this package)' })"
    if ($dropped) { Write-Host "    leaving the pool: $($dropped -join ', ')" -ForegroundColor DarkGray }

    $target = "promote/$To-$Package-$Version"
    if (-not $PSCmdlet.ShouldProcess((Get-ChannelFile -Channel $To),
            "move $Package $Version from $From to $To on branch $target")) {
        return
    }

    $subject = "feat: $Package $Version sai do $From para o $To"
    $body = if ($To -eq 'stable') {
        "Soube-se o bastante no $From. Todos os sites em Debian 13 passam a " +
        "receber $Package $Version por ``apt upgrade``; o .deb já está no pool, " +
        "então nada novo sobe."
    }
    else {
        # stable -> beta: this takes a version away from the fleet rather than
        # giving it to them, so say that instead of the promotion sentence.
        "$Package $Version sai do $From e passa a ser servido só para os canários " +
        "inscritos no $To. Quem está no $From volta para a versão anterior com " +
        "``apt install $Package=<anterior>``; o .deb já está no pool, então nada novo sobe."
    }
    if ($dropped) { $body += "`n`nSai do pool: $($dropped -join ', ')." }
    Submit-ChannelChange -Manifests @{ $From = $sourceUpdated; $To = $destinationUpdated } `
        -Branch $target -Subject $subject -Body $body -Push:$Push
}

function Remove-AptPromotion {
    <#
    .SYNOPSIS
        Takes a version off a channel, leaving it serving the previous one.

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
        [Parameter(Mandatory)][ValidateSet('stable', 'beta')][string]$Channel,
        [switch]$Push
    )

    Assert-CleanMain

    $entries = Read-ChannelFile -Channel $Channel
    if (-not ($entries | Where-Object { $_.Package -eq $Package -and $_.Version -eq $Version })) {
        throw "$Package $Version is not on $Channel"
    }

    $updated = @($entries | Where-Object { -not ($_.Package -eq $Package -and $_.Version -eq $Version) })
    $remaining = @($updated | Where-Object Package -EQ $Package).Version
    # Emptying stable is worse than a bad version: `apt install` stops resolving
    # at all, including on machines that never took the bad one. beta may drain,
    # since a canary subscribes to stable as well and falls through to it.
    if (-not $remaining -and $Channel -in $script:RequiredChannels) {
        throw "that is the only $Package version on $Channel; promote a replacement first"
    }

    Write-Host "==> withdrawing $Package $Version from $Channel" -ForegroundColor Cyan
    Write-Host "    $Channel becomes: $(if ($remaining) { $remaining -join ', ' } else { '(empty for this package)' })"

    $target = "withdraw/$Channel-$Package-$Version"
    if (-not $PSCmdlet.ShouldProcess((Get-ChannelFile -Channel $Channel),
            "withdraw $Package $Version from $Channel on branch $target")) {
        return
    }

    $subject = "revert: retira $Package $Version do canal $Channel"
    $body = if ($remaining) {
        $fallback = @($remaining | Sort-Object -Descending -Property @{ Expression = { ConvertTo-SortableVersion $_ } })[0]
        "O canal volta a servir $Package $fallback. " +
        "Sites que já atualizaram voltam com ``apt install $Package=$fallback``."
    }
    else {
        # Only reachable on beta: stable is guarded above.
        "O $Channel fica sem $Package. Os canários voltam ao que o stable serve, " +
        "com ``apt install $Package=<versão do stable>``."
    }
    Submit-ChannelChange -Manifests @{ $Channel = $updated } -Branch $target `
        -Subject $subject -Body $body -Push:$Push
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
    foreach ($suite in $script:Channels) {
        if (-not (Test-AptSuite -Url $Url -Suite $suite)) { $healthy = $false }
    }
    return $healthy
}

function Test-AptSuite {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Suite
    )

    $healthy = $true

    Write-Host "==> $Url ($Suite)" -ForegroundColor Cyan
    $inRelease = Get-TextResource "$Url/dists/$Suite/InRelease"
    # A suite the workflow has not deployed yet answers 404, which is the state
    # between merging a change and the run finishing — and the state of a
    # brand-new suite until its first publish. That is a report, not a crash.
    if ($null -eq $inRelease) {
        Write-Warning "$Suite is not published at $Url — the workflow has not deployed it (yet)."
        return $false
    }

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
        Write-Warning "$Suite expires in under two weeks — publish now or apt update starts failing everywhere."
        $healthy = $false
    }

    $promoted = Read-ChannelFile -Channel $Suite
    foreach ($arch in $script:Architectures) {
        $packages = Get-TextResource "$Url/dists/$Suite/main/binary-$arch/Packages"
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
                Write-Warning "$($entry.Package) $($entry.Version) is in $Suite.list but absent from $Suite/$arch — publish not run since the last promotion?"
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
        # Channel name -> the entries that channel's manifest should end up
        # holding. A move writes two; everything else writes one.
        [Parameter(Mandatory)][hashtable]$Manifests,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,
        [switch]$Push
    )

    # Parse every manifest before touching anything. Sync-Pool reads them all,
    # so a malformed line in the channel this call is not even editing would
    # otherwise surface halfway through, on a fresh branch, with files already
    # rewritten.
    foreach ($channel in $script:Channels) { $null = Read-ChannelFile -Channel $channel }

    $origin = git -C $script:RepoRoot branch --show-current
    # --no-track: main is the base, not the upstream — the branch pushes to its
    # own remote ref.
    git -C $script:RepoRoot switch --create $Branch --no-track
    if ($LASTEXITCODE -ne 0) { throw "git switch failed" }

    try {
        foreach ($channel in $Manifests.Keys) {
            Write-ChannelFile -Channel $channel -Entries @($Manifests[$channel])
        }
        # After every manifest is written, never per channel: the pool is shared,
        # so a sync run against one channel's entries alone would delete the
        # other's.
        Sync-Pool
        # --all so a withdrawn version's .deb files are staged as deletions.
        git -C $script:RepoRoot add --all $script:Channels.ForEach({ "$_.list" }) pool
        if ($LASTEXITCODE -ne 0) { throw "git add failed" }

        git -C $script:RepoRoot commit -m $Subject -m $Body
        if ($LASTEXITCODE -ne 0) { throw "git commit failed" }
    }
    catch {
        # Assert-CleanMain ran at entry, so everything below is this call's own
        # work and there is nothing of yours here to lose. Leaving it behind
        # would strand the next run on "working tree is dirty".
        Write-Host "Failed; undoing the half-made change" -ForegroundColor Yellow
        git -C $script:RepoRoot reset --quiet
        git -C $script:RepoRoot checkout --quiet -- $script:Channels.ForEach({ "$_.list" }) pool
        git -C $script:RepoRoot clean --quiet -fd -- pool
        git -C $script:RepoRoot switch --quiet --force $origin
        # Only if the switch worked: deleting the branch you are on fails, and
        # the second error would bury the one that brought us here.
        if ($LASTEXITCODE -eq 0) { git -C $script:RepoRoot branch --quiet -D $Branch }
        else { Write-Warning "could not return to '$origin'; you are still on $Branch" }
        throw
    }
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
        Makes the committed pool hold exactly the .deb files the channels name,
        across all of them.

    .DESCRIPTION
        It reads the manifests itself rather than taking entries, because the
        pool is shared between the channels: handed one channel's entries it
        would delete every .deb only the other names.
    #>
    param()

    $entries = @($script:Channels | ForEach-Object { Read-ChannelFile -Channel $_ })

    # Full paths, not names: a .deb filed under the wrong package directory is
    # not the file the index will ask for, so matching on the name alone would
    # leave it in place and hand CI a pool it then rejects.
    $wanted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        $dir = Get-PoolPath -Package $entry.Package
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        foreach ($arch in $script:Architectures) {
            $file = "$($entry.Package)_$($entry.Version)_$arch.deb"
            [void]$wanted.Add([System.IO.Path]::GetFullPath((Join-Path $dir $file)))
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
        if ($wanted.Contains([System.IO.Path]::GetFullPath($stale.FullName))) { continue }
        Write-Host "    removing $($stale.Name)" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $stale.FullName -Force
    }
}

function Select-KeptVersions {
    <#
    .SYNOPSIS
        The versions a channel holds after adding one: the $Keep highest,
        newest first.

    .DESCRIPTION
        Ordered by version rather than by insertion. apt serves the highest
        version a suite carries, so the one that must survive the window is the
        highest — taking the first $Keep of an unordered list can drop exactly
        the version a site would retreat to.

        Ordering has a consequence worth refusing rather than performing: a
        version low enough to fall outside the window would be "added" to a
        manifest that never mentions it. Silently, that turns a promotion into
        nothing and a move into a deletion.
    #>
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$Version,
        [AllowEmptyCollection()][pscustomobject[]]$Existing = @(),
        [Parameter(Mandatory)][int]$Keep
    )

    $kept = @(
        [pscustomobject]@{ Package = $Package; Version = $Version }
        $Existing
    ) |
        Sort-Object -Descending -Property @{ Expression = { ConvertTo-SortableVersion $_.Version } } |
        Select-Object -First $Keep

    if ($Version -notin $kept.Version) {
        throw ("$Package $Version is lower than the $Keep version(s) the channel already keeps " +
            "($(($kept | ForEach-Object { $_.Version }) -join ', ')), so it would drop straight " +
            "back out of the manifest — raise -Keep if you mean to carry it as well")
    }
    return $kept
}

function Assert-ChannelKeepsPackage {
    <#
    .SYNOPSIS
        Refuses an edit that would leave a required channel with no version of
        a package it already carries.

    .DESCRIPTION
        Remove-AptPromotion is not the only way to drop the last version: a
        move out of stable gets there too. The guard belongs to the outcome, so
        every mutation runs it against the manifest it is about to write, even
        where the caller's own arithmetic should already have ruled it out.
    #>
    param(
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$Package,
        [AllowEmptyCollection()][pscustomobject[]]$Entries = @()
    )

    if ($Channel -notin $script:RequiredChannels) { return }
    if (@($Entries | Where-Object Package -EQ $Package)) { return }

    throw ("that would leave $Channel with no $Package at all, and an empty $Channel stops " +
        "``apt install $Package`` resolving on every site — including ones that never took " +
        "the version you are replacing")
}

function Get-ChannelFile {
    param([Parameter(Mandatory)][string]$Channel)

    if ($Channel -notin $script:Channels) {
        throw "unknown channel '$Channel' (known: $($script:Channels -join ', '))"
    }
    Join-Path $script:RepoRoot "$Channel.list"
}

function Read-ChannelFile {
    param([Parameter(Mandatory)][string]$Channel)

    $file = Get-ChannelFile -Channel $Channel
    $entries = foreach ($line in Get-Content -LiteralPath $file) {
        $stripped = ($line -replace '#.*', '').Trim()
        if (-not $stripped) { continue }
        $parts = $stripped -split '\s+'
        if ($parts.Count -ne 2) { throw "malformed $Channel.list entry: '$line'" }
        [pscustomobject]@{ Package = $parts[0]; Version = $parts[1] }
    }
    return @($entries)
}

function Write-ChannelFile {
    param(
        [Parameter(Mandatory)][string]$Channel,
        [AllowEmptyCollection()][pscustomobject[]]$Entries = @()
    )

    $file = Get-ChannelFile -Channel $Channel
    $existing = @(Get-Content -LiteralPath $file)
    $isEntry = { param($line) [bool](($line -replace '#.*', '').Trim()) }

    $header = [System.Collections.Generic.List[string]]::new()
    # The header is the comment block the file opens with, found by its own
    # shape rather than by where the entries happen to be. Position cannot tell
    # header from footer once a manifest empties, and beta empties routinely.
    $i = 0
    while ($i -lt $existing.Count -and $existing[$i] -match '^\s*#') {
        $header.Add($existing[$i].TrimEnd())
        $i++
    }

    # Every other comment is kept, collected below the entries. Notes someone
    # wrote between two entries end up at the foot rather than beside what they
    # were about — moved, which is visible in the diff, instead of deleted.
    $footer = [System.Collections.Generic.List[string]]::new()
    for ($j = $i; $j -lt $existing.Count; $j++) {
        $line = $existing[$j]
        if ((& $isEntry $line) -or -not $line.Trim()) { continue }
        $footer.Add($line.TrimEnd())
    }

    $lines = @($header) + @('') + @($Entries | ForEach-Object { "$($_.Package) $($_.Version)" })
    if ($footer.Count) { $lines += @('') + @($footer) }
    # LF explicitly: the publish workflow reads this file line by line, and a
    # trailing CR would ride along inside the version into the release tag it
    # builds from it.
    [System.IO.File]::WriteAllText($file, ($lines -join "`n") + "`n")
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
        Fetches a repository file as text, or $null when it is not there. Pages
        serves the index files with a binary content type, for which
        Invoke-WebRequest yields a byte array rather than a string.
    #>
    param([Parameter(Mandatory)][string]$Uri)

    $response = Invoke-WebRequest $Uri -SkipHttpErrorCheck
    if ($response.StatusCode -eq 404) { return $null }
    if ($response.StatusCode -ne 200) {
        throw "GET $Uri returned $($response.StatusCode)"
    }

    $content = $response.Content
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
    <#
    .SYNOPSIS
        A version rendered as a string that plain descending sort orders the
        way apt does.

    .DESCRIPTION
        Never throws on a version a manifest can hold. It runs inside
        Sort-Object expressions, where an
        exception is not caught by the caller: it prints an error, leaves the
        item unsorted, and turns terminating under $ErrorActionPreference
        'Stop' — so an unparseable version would silently mis-order the very
        list that decides which .deb stays in the pool.

        A prerelease sorts below its own release, which is dpkg's rule for the
        "1.2.0~rc1" spelling build-deb.sh writes and the reason it rewrites
        semver's "-" to "~". One key does the whole ordering, so callers cannot
        pair it with a secondary sort that puts the prerelease back on top.

        Digits only, and fixed width: a separator would put the comparison at
        the mercy of culture-aware string collation.
    #>
    param([Parameter(Mandatory)][string]$Version)

    $release, $suffix = $Version -split '[-~+]', 2
    $parts = @($release -split '\.' | ForEach-Object { if ($_ -match '^\d+$') { [int]$_ } else { 0 } })
    while ($parts.Count -lt 4) { $parts += 0 }

    # The flag digit is what puts 1.2.0 above 1.2.0~rc1: same release, 1 vs 0.
    $isRelease = if ($suffix) { 0 } else { 1 }
    '{0:D5}{1:D5}{2:D5}{3:D5}{4}{5}' -f $parts[0], $parts[1], $parts[2], $parts[3], $isRelease, $suffix
}

Export-ModuleMember -Function Get-AptChannel, Save-AptCandidate, New-AptPromotion,
Move-AptPromotion, Remove-AptPromotion, Test-AptChannel, Get-ReleaseTag
