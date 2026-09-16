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

    The .deb files are downloaded here with your own GitHub access and uploaded
    to this repository's `pool` release; SHA256SUMS records the hash of each and
    is committed with the manifest edit. So the only thing that ever crosses
    from private to public is a person running these commands, git carries no
    binaries, and CI holds no credential for iot-edge and cannot reach it.

    Nothing but a promotion adds assets to that release, and nothing but
    Remove-AptStaleAsset deletes them.

    Requires the GitHub CLI, authenticated with read access to the (private)
    iot-edge repository and write access to this one.

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
    Remove-AptStaleAsset -WhatIf                                 # release assets no branch records
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

# The release on this repository holding every .deb a manifest may name, and the
# committed file recording the hash each one must have to be published.
$script:PoolRelease = 'pool'
$script:HashFile    = 'SHA256SUMS'

# owner/name of this repository, resolved from the checkout on first use.
$script:ChannelRepository = $null

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

    $subject = "feat: promote $Package $Version to the $Channel channel"
    $body = if (-not $isTop) {
        "The $Channel channel already serves $Package $($promoted[0].Version), which is higher, " +
        "so no site moves on its own: $Version becomes installable by exact version, with " +
        "``apt install $Package=$Version``."
    }
    elseif ($Channel -eq 'beta') {
        "Sites subscribed to beta receive $Package $Version on ``apt upgrade``. " +
        "The stable channel does not change."
    }
    elseif ($existing) {
        "Debian 13 sites receive $Package $Version on ``apt upgrade``."
    }
    else {
        # Nothing to upgrade from on the first promotion: the package only
        # becomes installable once this is published.
        "First version of $Package on the channel. Debian 13 sites can install it " +
        "with ``apt install $Package``."
    }
    if ($dropped) { $body += "`n`nLeaving $($Channel): $($dropped -join ', ')." }
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
    if ($dropped) { Write-Host "    leaving $To : $($dropped -join ', ')" -ForegroundColor DarkGray }

    $target = "promote/$To-$Package-$Version"
    if (-not $PSCmdlet.ShouldProcess((Get-ChannelFile -Channel $To),
            "move $Package $Version from $From to $To on branch $target")) {
        return
    }

    $subject = "feat: move $Package $Version from $From to $To"
    $body = if ($To -eq 'stable') {
        "Soaked long enough on $From. Every Debian 13 site receives $Package $Version " +
        "on ``apt upgrade``; the .deb is already on the pool release, so nothing new " +
        "is uploaded."
    }
    else {
        # stable -> beta: this takes a version away from the fleet rather than
        # giving it to them, so say that instead of the promotion sentence.
        "$Package $Version leaves $From and is served only to the canaries subscribed " +
        "to $To. Sites on $From go back to the previous version with " +
        "``apt install $Package=<previous>``; the .deb is already on the pool release, " +
        "so nothing new is uploaded."
    }
    if ($dropped) { $body += "`n`nLeaving $($To): $($dropped -join ', ')." }
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

    $subject = "revert: withdraw $Package $Version from the $Channel channel"
    $body = if ($remaining) {
        $fallback = @($remaining | Sort-Object -Descending -Property @{ Expression = { ConvertTo-SortableVersion $_ } })[0]
        "The channel goes back to serving $Package $fallback. " +
        "Sites that already upgraded return with ``apt install $Package=$fallback``."
    }
    else {
        # Only reachable on beta: stable is guarded above.
        "The $Channel channel is left without $Package. Canaries go back to what stable serves, " +
        "with ``apt install $Package=<stable version>``."
    }
    Submit-ChannelChange -Manifests @{ $Channel = $updated } -Branch $target `
        -Subject $subject -Body $body -Push:$Push
}

function Remove-AptStaleAsset {
    <#
    .SYNOPSIS
        Deletes the assets on the pool release that no branch's SHA256SUMS
        records.

    .DESCRIPTION
        Promotions only add assets, which is what lets reverting a manifest
        change republish the version it dropped. An asset is kept while the
        default branch's SHA256SUMS records it, while the head of an open pull
        request does, while a branch in this checkout does, or while it is
        younger than -GraceDays — the window that covers a promotion someone has
        committed but not pushed yet.

        The branches that matter are read from the repository itself, not from
        this checkout's remote-tracking refs, which can be stale or point
        somewhere else entirely. Reading the default branch has to succeed: a
        repository that answers nothing is not a repository where everything is
        stale.

        Deletion is permanent: a pruned version comes back only by promoting it
        again. Try -WhatIf first; unless -Confirm:$false is given, every asset
        asks before it goes.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([ValidateRange(0, 365)][int]$GraceDays = 14)

    $repository = Get-ChannelRepository
    $defaultBranch = "$(gh api "repos/$repository" --jq .default_branch 2>$null)".Trim()
    if ($LASTEXITCODE -ne 0 -or -not $defaultBranch) { throw "reading the default branch of $repository failed" }

    $recorded = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $published = Get-RecordedNames -Repository $repository -Ref $defaultBranch
    if ($null -eq $published) {
        throw "$defaultBranch on $repository carries no $script:HashFile; refusing to treat every asset as stale"
    }
    foreach ($name in $published) { [void]$recorded.Add($name) }

    $open = @(gh api "repos/$repository/pulls?state=open&per_page=100" --jq '.[].head.sha' 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "listing open pull requests of $repository failed" }
    # With nothing open gh prints nothing, which arrives here as one empty line.
    foreach ($sha in @($open | Where-Object { $_ -and $_.Trim() })) {
        foreach ($name in @(Get-RecordedNames -Repository $repository -Ref $sha)) { [void]$recorded.Add($name) }
    }

    # This checkout's own branches, which is where a promotion committed without
    # -Push lives until it is pushed.
    foreach ($ref in @(git -C $script:RepoRoot for-each-ref --format='%(refname)' refs/heads)) {
        $lines = @(git -C $script:RepoRoot show "${ref}:$script:HashFile" 2>$null)
        if ($LASTEXITCODE -ne 0) { continue }
        foreach ($line in $lines) {
            if ($line -cmatch '^[0-9a-f]{64}  ([^ ]+)$') { [void]$recorded.Add($Matches[1]) }
        }
    }

    $assets = Get-PoolAssets
    $cutoff = [datetime]::UtcNow.AddDays(-$GraceDays)
    $unrecorded = foreach ($name in $assets.Keys) {
        if ($recorded.Contains($name)) { continue }
        $created = $assets[$name].CreatedAt
        if ($created -and $created -gt $cutoff) {
            Write-Host "    keeping $name, uploaded less than $GraceDays days ago" -ForegroundColor DarkGray
            continue
        }
        $name
    }
    $stale = @($unrecorded | Sort-Object)
    if (-not $stale) {
        Write-Host "==> nothing on the $script:PoolRelease release is stale" -ForegroundColor Cyan
        return
    }

    Write-Host "==> $($stale.Count) asset(s) on the $script:PoolRelease release that nothing records" -ForegroundColor Cyan
    foreach ($name in $stale) {
        if (-not $PSCmdlet.ShouldProcess("$repository release $script:PoolRelease", "delete $name")) { continue }
        $out = gh release delete-asset $script:PoolRelease $name --repo $repository --yes 2>&1
        if ($LASTEXITCODE -ne 0) { throw "gh release delete-asset failed for ${name}: $out" }
        Write-Host "    deleted $name" -ForegroundColor DarkGray
    }
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

    # Parse every manifest and SHA256SUMS before touching anything. Sync-Pool
    # reads them all, so a malformed line in a file this call is not even
    # editing would otherwise surface halfway through, on a fresh branch, with
    # files already rewritten.
    foreach ($channel in $script:Channels) { $null = Read-ChannelFile -Channel $channel }
    $null = Read-HashFile

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
        # so a sync run against one channel's entries alone would drop the
        # other's hashes.
        Sync-Pool
        git -C $script:RepoRoot add $script:Channels.ForEach({ "$_.list" }) $script:HashFile
        if ($LASTEXITCODE -ne 0) { throw "git add failed" }

        git -C $script:RepoRoot commit -m $Subject -m $Body
        if ($LASTEXITCODE -ne 0) { throw "git commit failed" }
    }
    catch {
        # Assert-CleanMain ran at entry, so everything below is this call's own
        # work and there is nothing of yours here to lose. Leaving it behind
        # would strand the next run on "working tree is dirty".
        #
        # Assets Sync-Pool already uploaded stay on the pool release. No
        # committed SHA256SUMS records them, so they publish nothing; a retry
        # reuses them, and Remove-AptStaleAsset deletes them otherwise.
        Write-Host "Failed; undoing the half-made change" -ForegroundColor Yellow
        git -C $script:RepoRoot reset --quiet
        git -C $script:RepoRoot checkout --quiet -- $script:Channels.ForEach({ "$_.list" }) $script:HashFile
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

function Get-ChannelRepository {
    <#
    .SYNOPSIS
        owner/name of the repository behind this checkout's origin remote: the
        one whose pool release this module uploads to and prunes.

    .DESCRIPTION
        Read from origin rather than asked of gh, which picks a remote named
        upstream or github over origin when a clone has one. Uploading to one
        repository while reading another's branches is how a prune deletes a
        file something still needs.
    #>
    param()

    if (-not $script:ChannelRepository) {
        $url = "$(git -C $script:RepoRoot remote get-url origin 2>$null)".Trim()
        if ($LASTEXITCODE -ne 0 -or -not $url) { throw "this checkout has no origin remote" }
        if ($url -notmatch 'github[.]com[:/]+([^/]+)/(.+?)(?:[.]git)?/?$') {
            throw "origin ($url) is not a GitHub repository"
        }
        $script:ChannelRepository = "$($Matches[1])/$($Matches[2])"
    }
    return $script:ChannelRepository
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
        Makes SHA256SUMS record exactly the .deb files the channels name, across
        all of them, uploading to the pool release any file it does not hold yet.

    .DESCRIPTION
        It reads the manifests itself rather than taking entries, because the
        pool is shared between the channels: handed one channel's entries it
        would drop every hash only the other names.

        A file that leaves every manifest loses its line in SHA256SUMS and
        nothing else. Its asset stays on the release, so reverting the change
        republishes it; Remove-AptStaleAsset is what deletes it.
    #>
    param()

    $entries = @($script:Channels | ForEach-Object { Read-ChannelFile -Channel $_ })
    $recorded = Read-HashFile
    $assets = Get-PoolAssets

    $hashes = @{}
    foreach ($entry in $entries) {
        foreach ($arch in $script:Architectures) {
            $file = "$($entry.Package)_$($entry.Version)_$arch.deb"
            # Named by both channels while a move is being written: one line.
            if ($hashes.ContainsKey($file)) { continue }

            if ($recorded.ContainsKey($file)) {
                if ($assets.ContainsKey($file)) {
                    # Published before, so CI will demand these exact bytes from
                    # the release. Checking here names the file, instead of
                    # leaving it to fail the publish this change triggers.
                    Assert-PoolAsset -File $file -Asset $assets[$file]
                    if ($assets[$file].Sha256 -ne $recorded[$file]) {
                        throw "$file on the $script:PoolRelease release does not match the hash $script:HashFile records"
                    }
                    $hashes[$file] = $recorded[$file]
                    continue
                }
                # Recorded but gone from the release, which every other command
                # and the publish would trip over. Uploading it again is safe
                # because the recorded hash decides what may go up.
                Write-Host "    $file is recorded but missing from the $script:PoolRelease release" -ForegroundColor Yellow
                $hashes[$file] = Publish-PoolAsset -Package $entry.Package -Version $entry.Version `
                    -File $file -Assets $assets -ExpectedHash $recorded[$file]
                continue
            }

            $hashes[$file] = Publish-PoolAsset -Package $entry.Package -Version $entry.Version `
                -File $file -Assets $assets
        }
    }

    Write-HashFile -Hashes $hashes
}

function Publish-PoolAsset {
    <#
    .SYNOPSIS
        Uploads one .deb from its iot-edge release to the pool release and
        returns its SHA-256.

    .DESCRIPTION
        An asset of that name may already be there, from a promotion that was
        never merged or one that failed after uploading. It is reused only if
        it holds the same bytes; a different file under a published name is
        refused rather than replaced, since CI checks the bytes, not the name.

        -ExpectedHash restores a file SHA256SUMS already records: what goes up
        must hash to what was reviewed, or nothing does.
    #>
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][hashtable]$Assets,
        [string]$ExpectedHash
    )

    # GitHub rewrites an asset name it does not accept — a "~" lands as "." —
    # and the manifests would then name a file the release does not hold.
    if ($File -cnotmatch '^[A-Za-z0-9._+-]+$') {
        throw "$File carries characters GitHub rewrites in an asset name"
    }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "apt-pool-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        Write-Host "    fetching $File" -ForegroundColor DarkGray
        $tag = Get-ReleaseTag -Package $Package -Version $Version
        $out = gh release download $tag --repo $script:Upstream --pattern $File --dir $temp 2>&1
        if ($LASTEXITCODE -ne 0) { throw "gh release download failed for ${File}: $out" }
        $path = Join-Path $temp $File
        if (-not (Test-Path -LiteralPath $path)) { throw "$tag carries no $File" }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($ExpectedHash -and $hash -ne $ExpectedHash) {
            throw ("$tag now carries a different $File ($hash) than $script:HashFile records " +
                "($ExpectedHash); that release was rebuilt and the published version cannot be restored from it")
        }

        if ($Assets.ContainsKey($File)) {
            Assert-PoolAsset -File $File -Asset $Assets[$File]
            if ($Assets[$File].Sha256 -ne $hash) {
                throw ("the $script:PoolRelease release already holds a different $File " +
                    "($($Assets[$File].Sha256)) than $tag ($hash); refusing to replace it")
            }
            Write-Host "    $File is already on the $script:PoolRelease release" -ForegroundColor DarkGray
            return $hash
        }

        Write-Host "    uploading $File" -ForegroundColor DarkGray
        $out = gh release upload $script:PoolRelease $path --repo (Get-ChannelRepository) 2>&1
        if ($LASTEXITCODE -ne 0) { throw "gh release upload failed for ${File}: $out" }

        # Read back rather than trust the exit code: an upload lands under a
        # rewritten name, or unfinished, without saying so.
        $stored = (Get-PoolAssets)[$File]
        if (-not $stored) {
            throw "$File is not on the $script:PoolRelease release after the upload"
        }
        Assert-PoolAsset -File $File -Asset $stored
        if ($stored.Sha256 -ne $hash) {
            throw "$File on the $script:PoolRelease release does not match the file that was uploaded"
        }
        return $hash
    }
    finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-PoolAsset {
    <#
    .SYNOPSIS
        Refuses an asset that is not a finished upload with a digest to compare.
    #>
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][pscustomobject]$Asset
    )

    if ($Asset.State -ne 'uploaded') {
        throw ("$File on the $script:PoolRelease release is in state '$($Asset.State)' rather than " +
            "uploaded; delete that asset and run this again")
    }
    if (-not $Asset.Sha256) {
        throw "GitHub reports no digest for $File on the $script:PoolRelease release; a newer gh reports one"
    }
}

function Get-PoolAssets {
    <#
    .SYNOPSIS
        The pool release's assets, as file name -> Sha256, State and CreatedAt.
    #>
    param()

    $repository = Get-ChannelRepository
    # stderr kept out of what is parsed: folded in, a gh warning becomes a JSON
    # error that says nothing about what went wrong.
    $output = gh release view $script:PoolRelease --repo $repository --json assets 2>&1
    $failures = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    if ($LASTEXITCODE -ne 0) {
        throw "release '$script:PoolRelease' not found on ${repository}: $($failures -join ' ')"
    }
    $json = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"

    $assets = @{}
    foreach ($asset in ($json | ConvertFrom-Json).assets) {
        $assets[$asset.name] = [pscustomobject]@{
            Sha256    = ($asset.digest -replace '^sha256:', '').ToLowerInvariant()
            State     = $asset.state
            CreatedAt = ConvertTo-UtcDate $asset.createdAt
        }
    }
    return $assets
}

function ConvertTo-UtcDate {
    <#
    .SYNOPSIS
        An asset timestamp as UTC, whether it arrives as the string GitHub sends
        or as the local DateTime ConvertFrom-Json makes of it.
    #>
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }
    return [datetime]::Parse([string]$Value, [cultureinfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
        [System.Globalization.DateTimeStyles]::AdjustToUniversal)
}

function Get-RecordedNames {
    <#
    .SYNOPSIS
        The file names SHA256SUMS records at one ref of the channel repository,
        or $null when that ref carries no SHA256SUMS.
    #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Ref
    )

    $output = gh api "repos/$Repository/contents/$($script:HashFile)?ref=$Ref" `
        -H 'Accept: application/vnd.github.raw' 2>&1
    $failures = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join ' '
    if ($LASTEXITCODE -ne 0) {
        if ($failures -match '404') { return $null }
        throw "reading $script:HashFile at $Ref on ${Repository}: $failures"
    }
    $text = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    return @($text -split "`r?`n" | ForEach-Object {
            if ($_ -cmatch '^[0-9a-f]{64}  ([^ ]+)$') { $Matches[1] }
        })
}

function Read-HashFile {
    <#
    .SYNOPSIS
        SHA256SUMS as file name -> lowercase SHA-256.
    #>
    param()

    $file = Join-Path $script:RepoRoot $script:HashFile
    if (-not (Test-Path -LiteralPath $file)) { throw "$script:HashFile is missing from $($script:RepoRoot)" }

    $hashes = @{}
    foreach ($line in Get-Content -LiteralPath $file) {
        if (-not $line.Trim()) { continue }
        # Two spaces between hash and name, as sha256sum writes it and as the
        # workflow's `sha256sum --strict -c` requires.
        if ($line -cnotmatch '^([0-9a-f]{64})  ([^ /]+[.]deb)$') {
            throw "malformed $script:HashFile line: '$line'"
        }
        if ($hashes.ContainsKey($Matches[2])) { throw "$($Matches[2]) appears twice in $script:HashFile" }
        $hashes[$Matches[2]] = $Matches[1]
    }
    return $hashes
}

function Write-HashFile {
    param([Parameter(Mandatory)][hashtable]$Hashes)

    $names = [string[]]@($Hashes.Keys)
    # Ordinal, so the order does not depend on the culture of the machine that
    # promoted and the diff shows only real changes.
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    $lines = @($names | ForEach-Object { "$($Hashes[$_])  $_" })
    # LF explicitly, as for the manifests: the workflow reads this file on Linux.
    [System.IO.File]::WriteAllText((Join-Path $script:RepoRoot $script:HashFile), (($lines -join "`n") + "`n"))
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
Move-AptPromotion, Remove-AptPromotion, Remove-AptStaleAsset, Test-AptChannel, Get-ReleaseTag
