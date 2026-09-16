# Unit tests for Promote.psm1. Nothing here reaches GitHub: the repository under
# test is a temporary git repo with a bare one beside it as origin, and every gh
# call is mocked, which is also the only practical way to present a half-uploaded
# asset, a missing digest or an upload with a chosen age.
#
#   Invoke-Pester tests            # from the repository root

BeforeAll {
    $script:ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Promote.psm1'
    Import-Module $script:ModulePath -Force

    # A repository the tests can write to, with a bare origin so branching,
    # committing and pushing run for real.
    function New-TestRepository {
        $root = Join-Path ([IO.Path]::GetTempPath()) "promote-tests-$([guid]::NewGuid())"
        $bare = "$root.origin.git"
        New-Item -ItemType Directory -Path $root | Out-Null
        git init --quiet --initial-branch=main $root
        git init --quiet --bare $bare
        git -C $root remote add origin $bare
        git -C $root config user.email 'tests@example.invalid'
        git -C $root config user.name 'Promote tests'
        # The fixture files are written with LF, as the module writes them.
        git -C $root config core.autocrlf false

        Set-Content -Path (Join-Path $root 'stable.list') -Value @(
            '# header kept by Write-ChannelFile'
            ''
            'skbridge 0.2.0'
            'skbridge 0.1.9'
        )
        Set-Content -Path (Join-Path $root 'beta.list') -Value @(
            '# header kept by Write-ChannelFile'
            ''
            'skprinter 0.3.0'
        )
        # LF and ordinal order, as Write-HashFile writes them: with CRLF or
        # another order the round-trip test would only be comparing formatting.
        [IO.File]::WriteAllText((Join-Path $root 'SHA256SUMS'), (@(
                    ('c' * 64) + '  skbridge_0.1.9_amd64.deb'
                    ('d' * 64) + '  skbridge_0.1.9_arm64.deb'
                    ('a' * 64) + '  skbridge_0.2.0_amd64.deb'
                    ('b' * 64) + '  skbridge_0.2.0_arm64.deb'
                    ('e' * 64) + '  skprinter_0.3.0_amd64.deb'
                    ('f' * 64) + '  skprinter_0.3.0_arm64.deb'
                ) -join "`n") + "`n")
        git -C $root add -A
        git -C $root commit --quiet -m 'fixture'
        git -C $root push --quiet origin main
        return $root
    }

    function Remove-TestRepository([string] $Root) {
        foreach ($path in $Root, "$Root.origin.git") {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    # What gh prints for `release view --json assets`, as one JSON line.
    function New-AssetJson {
        param([hashtable[]] $Assets)
        $list = foreach ($asset in $Assets) {
            [pscustomobject]@{
                name      = $asset.Name
                digest    = if ($asset.ContainsKey('Digest')) { $asset.Digest } else { 'sha256:' + ('a' * 64) }
                state     = if ($asset.ContainsKey('State')) { $asset.State } else { 'uploaded' }
                createdAt = if ($asset.ContainsKey('CreatedAt')) { $asset.CreatedAt } else { [datetime]::UtcNow.AddDays(-90).ToString('o') }
            }
        }
        [pscustomobject]@{ assets = @($list) } | ConvertTo-Json -Depth 5 -Compress
    }
}

Describe 'ConvertTo-SortableVersion' {
    It 'orders numerically rather than as text' {
        InModuleScope Promote {
            $sorted = '0.1.9', '0.1.10', '0.2.0' |
                Sort-Object -Descending -Property @{ Expression = { ConvertTo-SortableVersion $_ } }
            $sorted | Should -Be @('0.2.0', '0.1.10', '0.1.9')
        }
    }

    It 'sorts a prerelease below its own release' {
        InModuleScope Promote {
            (ConvertTo-SortableVersion '1.2.0~rc1') | Should -BeLessThan (ConvertTo-SortableVersion '1.2.0')
        }
    }

    It 'does not throw on a version a manifest could hold' {
        InModuleScope Promote {
            { ConvertTo-SortableVersion '1.2.0+build.5' } | Should -Not -Throw
            { ConvertTo-SortableVersion 'not-a-version' } | Should -Not -Throw
        }
    }
}

Describe 'Select-KeptVersions' {
    It 'keeps the highest versions, newest first' {
        InModuleScope Promote {
            $existing = @(
                [pscustomobject]@{ Package = 'skbridge'; Version = '0.1.9' }
                [pscustomobject]@{ Package = 'skbridge'; Version = '0.2.0' }
            )
            $kept = Select-KeptVersions -Package skbridge -Version '0.3.0' -Existing $existing -Keep 2
            $kept.Version | Should -Be @('0.3.0', '0.2.0')
        }
    }

    It 'refuses a version that would fall straight out of the window' {
        InModuleScope Promote {
            $existing = @(
                [pscustomobject]@{ Package = 'skbridge'; Version = '0.2.0' }
                [pscustomobject]@{ Package = 'skbridge'; Version = '0.1.9' }
            )
            { Select-KeptVersions -Package skbridge -Version '0.1.0' -Existing $existing -Keep 2 } |
                Should -Throw -ExpectedMessage '*would drop straight back out*'
        }
    }
}

Describe 'Assert-ChannelKeepsPackage' {
    It 'refuses to leave stable without a package it carries' {
        InModuleScope Promote {
            { Assert-ChannelKeepsPackage -Channel stable -Package skbridge -Entries @() } |
                Should -Throw -ExpectedMessage '*no skbridge at all*'
        }
    }

    It 'lets beta drain' {
        InModuleScope Promote {
            { Assert-ChannelKeepsPackage -Channel beta -Package skprinter -Entries @() } | Should -Not -Throw
        }
    }
}

Describe 'Get-ReleaseTagPrefix' {
    It 'maps a package to the project that builds it' {
        InModuleScope Promote {
            Get-ReleaseTag -Package skprinter -Version '0.1.5' | Should -Be 'skprinter-appliance-v0.1.5'
        }
    }

    It 'refuses a package it does not know rather than guessing' {
        InModuleScope Promote {
            { Get-ReleaseTagPrefix -Package skreceiver } | Should -Throw -ExpectedMessage "*unknown package 'skreceiver'*"
        }
    }
}

Describe 'ConvertTo-UtcDate' {
    It 'reads the string GitHub sends as UTC' {
        InModuleScope Promote {
            $utc = ConvertTo-UtcDate '2026-09-16T00:20:42Z'
            $utc.Kind | Should -Be ([datetimekind]::Utc)
            $utc.ToString('yyyy-MM-ddTHH:mm:ss') | Should -Be '2026-09-16T00:20:42'
        }
    }

    It 'keeps the same instant when ConvertFrom-Json already made it a local DateTime' {
        InModuleScope Promote {
            $fromJson = ('{"createdAt":"2026-09-16T00:20:42Z"}' | ConvertFrom-Json).createdAt
            (ConvertTo-UtcDate $fromJson).ToString('yyyy-MM-ddTHH:mm:ss') | Should -Be '2026-09-16T00:20:42'
        }
    }
}

Describe 'Assert-PoolAsset' {
    It 'refuses an upload that never finished' {
        InModuleScope Promote {
            $asset = [pscustomobject]@{ Sha256 = 'a' * 64; State = 'starter'; CreatedAt = [datetime]::UtcNow }
            { Assert-PoolAsset -File 'x_1.0_amd64.deb' -Asset $asset } | Should -Throw -ExpectedMessage "*state 'starter'*"
        }
    }

    It 'refuses an asset with no digest to compare' {
        InModuleScope Promote {
            $asset = [pscustomobject]@{ Sha256 = ''; State = 'uploaded'; CreatedAt = [datetime]::UtcNow }
            { Assert-PoolAsset -File 'x_1.0_amd64.deb' -Asset $asset } | Should -Throw -ExpectedMessage '*no digest*'
        }
    }
}

Describe 'the channel manifests' {
    BeforeEach {
        $script:Root = New-TestRepository
        InModuleScope Promote -Parameters @{ Root = $script:Root } { param($Root) $script:RepoRoot = $Root }
    }
    AfterEach { Remove-TestRepository $script:Root }

    It 'reads entries and ignores comments' {
        InModuleScope Promote {
            $entries = Read-ChannelFile -Channel stable
            $entries.Count | Should -Be 2
            $entries[0].Package | Should -Be 'skbridge'
            $entries[0].Version | Should -Be '0.2.0'
        }
    }

    It 'refuses a malformed line rather than reading half of it' {
        InModuleScope Promote {
            Add-Content -Path (Join-Path $script:RepoRoot 'stable.list') -Value 'skbridge 0.4.0 extra'
            { Read-ChannelFile -Channel stable } | Should -Throw -ExpectedMessage '*malformed stable.list entry*'
        }
    }

    It 'keeps the header and writes LF line endings' {
        InModuleScope Promote {
            Write-ChannelFile -Channel stable -Entries @([pscustomobject]@{ Package = 'skbridge'; Version = '0.5.0' })
            $text = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'stable.list'))
            $text | Should -BeLike '# header kept by Write-ChannelFile*'
            $text | Should -BeLike '*skbridge 0.5.0*'
            $text | Should -Not -BeLike "*`r`n*"
        }
    }
}

Describe 'SHA256SUMS' {
    BeforeEach {
        $script:Root = New-TestRepository
        InModuleScope Promote -Parameters @{ Root = $script:Root } { param($Root) $script:RepoRoot = $Root }
    }
    AfterEach { Remove-TestRepository $script:Root }

    It 'reads every recorded file' {
        InModuleScope Promote {
            (Read-HashFile).Count | Should -Be 6
            (Read-HashFile)['skbridge_0.2.0_amd64.deb'] | Should -Be ('a' * 64)
        }
    }

    It 'refuses the single-space spelling sha256sum --strict rejects' {
        InModuleScope Promote {
            Add-Content -Path (Join-Path $script:RepoRoot 'SHA256SUMS') -Value (('9' * 64) + ' one-space_1.0_amd64.deb')
            { Read-HashFile } | Should -Throw -ExpectedMessage '*malformed SHA256SUMS line*'
        }
    }

    It 'refuses the same file twice' {
        InModuleScope Promote {
            Add-Content -Path (Join-Path $script:RepoRoot 'SHA256SUMS') -Value (('9' * 64) + '  skbridge_0.2.0_amd64.deb')
            { Read-HashFile } | Should -Throw -ExpectedMessage '*appears twice*'
        }
    }

    It 'round-trips byte for byte, sorted and LF-terminated' {
        InModuleScope Promote {
            $before = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'SHA256SUMS'))
            Write-HashFile -Hashes (Read-HashFile)
            $after = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'SHA256SUMS'))
            $after | Should -Be $before
            $after | Should -Not -BeLike "*`r`n*"
        }
    }

    It 'writes the names in ordinal order whatever order they arrive in' {
        InModuleScope Promote {
            Write-HashFile -Hashes ([ordered]@{
                    'skprinter_0.3.0_amd64.deb' = 'e' * 64
                    'skbridge_0.2.0_amd64.deb'  = 'a' * 64
                    'skbridge_0.1.9_amd64.deb'  = 'c' * 64
                })
            $names = @(Get-Content (Join-Path $script:RepoRoot 'SHA256SUMS') | ForEach-Object { ($_ -split '  ')[1] })
            $names | Should -Be @('skbridge_0.1.9_amd64.deb', 'skbridge_0.2.0_amd64.deb', 'skprinter_0.3.0_amd64.deb')
        }
    }
}

Describe 'Get-ChannelRepository' {
    BeforeEach {
        $script:Root = New-TestRepository
        InModuleScope Promote -Parameters @{ Root = $script:Root } {
            param($Root)
            $script:RepoRoot = $Root
            $script:ChannelRepository = $null
        }
    }
    AfterEach { Remove-TestRepository $script:Root }

    It 'reads owner/name from origin, not from another remote' {
        InModuleScope Promote {
            git -C $script:RepoRoot remote set-url origin 'https://github.com/SkyMobDev/apt.git'
            git -C $script:RepoRoot remote add upstream 'https://github.com/someone-else/fork.git'
            Get-ChannelRepository | Should -Be 'SkyMobDev/apt'
        }
    }

    It 'reads the ssh spelling too' {
        InModuleScope Promote {
            git -C $script:RepoRoot remote set-url origin 'git@github.com:SkyMobDev/apt.git'
            Get-ChannelRepository | Should -Be 'SkyMobDev/apt'
        }
    }

    It 'refuses an origin that is not on GitHub' {
        InModuleScope Promote {
            git -C $script:RepoRoot remote set-url origin 'https://gitlab.com/SkyMobDev/apt.git'
            { Get-ChannelRepository } | Should -Throw -ExpectedMessage '*not a GitHub repository*'
        }
    }
}

Describe 'Publish-PoolAsset' {
    BeforeEach {
        $script:Root = New-TestRepository
        InModuleScope Promote -Parameters @{ Root = $script:Root } {
            param($Root)
            $script:RepoRoot = $Root
            $script:ChannelRepository = 'SkyMobDev/apt'
        }
    }
    AfterEach { Remove-TestRepository $script:Root }

    It 'refuses a name GitHub would rewrite, before downloading anything' {
        InModuleScope Promote {
            Mock gh { throw 'gh should not run' }
            { Publish-PoolAsset -Package skbridge -Version '1.2.0~rc1' -File 'skbridge_1.2.0~rc1_amd64.deb' -Assets @{} } |
                Should -Throw -ExpectedMessage '*GitHub rewrites*'
            Should -Not -Invoke gh
        }
    }

    It 'reuses an asset already on the release when the bytes match' {
        InModuleScope Promote {
            Mock gh {
                if ($args -contains 'download') {
                    $dir = $args[$args.IndexOf('--dir') + 1]
                    Set-Content -Path (Join-Path $dir 'skbridge_0.2.0_amd64.deb') -Value 'payload' -NoNewline
                }
                $global:LASTEXITCODE = 0
            }
            $hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('payload'))) -Algorithm SHA256).Hash.ToLowerInvariant()
            $assets = @{ 'skbridge_0.2.0_amd64.deb' = [pscustomobject]@{ Sha256 = $hash; State = 'uploaded'; CreatedAt = [datetime]::UtcNow } }
            Publish-PoolAsset -Package skbridge -Version '0.2.0' -File 'skbridge_0.2.0_amd64.deb' -Assets $assets |
                Should -Be $hash
            Should -Not -Invoke gh -ParameterFilter { $args -contains 'upload' }
        }
    }

    It 'refuses to replace a published name whose bytes differ' {
        InModuleScope Promote {
            Mock gh {
                if ($args -contains 'download') {
                    $dir = $args[$args.IndexOf('--dir') + 1]
                    Set-Content -Path (Join-Path $dir 'skbridge_0.2.0_amd64.deb') -Value 'payload' -NoNewline
                }
                $global:LASTEXITCODE = 0
            }
            $assets = @{ 'skbridge_0.2.0_amd64.deb' = [pscustomobject]@{ Sha256 = 'b' * 64; State = 'uploaded'; CreatedAt = [datetime]::UtcNow } }
            { Publish-PoolAsset -Package skbridge -Version '0.2.0' -File 'skbridge_0.2.0_amd64.deb' -Assets $assets } |
                Should -Throw -ExpectedMessage '*refusing to replace it*'
        }
    }

    It 'refuses to restore a file upstream has rebuilt' {
        InModuleScope Promote {
            Mock gh {
                if ($args -contains 'download') {
                    $dir = $args[$args.IndexOf('--dir') + 1]
                    Set-Content -Path (Join-Path $dir 'skbridge_0.2.0_amd64.deb') -Value 'rebuilt' -NoNewline
                }
                $global:LASTEXITCODE = 0
            }
            { Publish-PoolAsset -Package skbridge -Version '0.2.0' -File 'skbridge_0.2.0_amd64.deb' `
                    -Assets @{} -ExpectedHash ('c' * 64) } |
                Should -Throw -ExpectedMessage '*was rebuilt*'
        }
    }
}

Describe 'Remove-AptStaleAsset' {
    BeforeEach {
        $script:Root = New-TestRepository
        InModuleScope Promote -Parameters @{ Root = $script:Root } {
            param($Root)
            $script:RepoRoot = $Root
            $script:ChannelRepository = 'SkyMobDev/apt'
        }
    }
    AfterEach { Remove-TestRepository $script:Root }

    It 'refuses to run when the default branch records nothing' {
        InModuleScope Promote {
            # As gh behaves when the file is not there: a message on stderr and a
            # non-zero exit code, not a thrown error.
            Mock gh {
                $global:LASTEXITCODE = 0
                if ($args -contains 'repos/SkyMobDev/apt') { return 'main' }
                if ("$args" -match 'contents/SHA256SUMS') {
                    $global:LASTEXITCODE = 1
                    return [System.Management.Automation.ErrorRecord]::new(
                        [Exception]::new('gh: Not Found (HTTP 404)'), 'NotFound', 'NotSpecified', $null)
                }
                return '[]'
            }
            { Remove-AptStaleAsset -WhatIf } | Should -Throw -ExpectedMessage '*refusing to treat every asset as stale*'
        }
    }

    It 'keeps what main records, what an open pull request records, and anything young' {
        InModuleScope Promote {
            $old = [datetime]::UtcNow.AddDays(-90).ToString('o')
            $young = [datetime]::UtcNow.AddDays(-1).ToString('o')
            $listing = @{
                assets = @(
                    @{ name = 'kept-by-main_1.0_amd64.deb'; digest = 'sha256:' + ('a' * 64); state = 'uploaded'; createdAt = $old }
                    @{ name = 'kept-by-pr_1.0_amd64.deb'; digest = 'sha256:' + ('b' * 64); state = 'uploaded'; createdAt = $old }
                    @{ name = 'young_1.0_amd64.deb'; digest = 'sha256:' + ('c' * 64); state = 'uploaded'; createdAt = $young }
                    @{ name = 'stale_1.0_amd64.deb'; digest = 'sha256:' + ('d' * 64); state = 'uploaded'; createdAt = $old }
                )
            } | ConvertTo-Json -Depth 5 -Compress
            Mock gh {
                $global:LASTEXITCODE = 0
                if ($args -contains 'repos/SkyMobDev/apt') { return 'main' }
                if ("$args" -match 'contents/SHA256SUMS\?ref=main') { return ('a' * 64) + '  kept-by-main_1.0_amd64.deb' }
                if ("$args" -match 'contents/SHA256SUMS\?ref=') { return ('b' * 64) + '  kept-by-pr_1.0_amd64.deb' }
                if ("$args" -match 'pulls\?state=open') { return 'deadbeef' }
                if ($args -contains 'view') { return $listing }
                return ''
            }
            Remove-AptStaleAsset -Confirm:$false
            # Only stale_1.0_amd64.deb: the other three are recorded on main, on
            # the open pull request, or still inside the window.
            Should -Invoke gh -ParameterFilter { $args -contains 'delete-asset' -and $args -contains 'stale_1.0_amd64.deb' } -Times 1 -Exactly
            Should -Invoke gh -ParameterFilter { $args -contains 'delete-asset' } -Times 1 -Exactly
        }
    }

    It 'deletes an asset uploaded minutes ago once the grace window is zero' {
        InModuleScope Promote {
            $listing = @{
                assets = @(
                    @{ name = 'kept_1.0_amd64.deb'; digest = 'sha256:' + ('a' * 64); state = 'uploaded'; createdAt = [datetime]::UtcNow.AddDays(-90).ToString('o') }
                    @{ name = 'fresh_1.0_amd64.deb'; digest = 'sha256:' + ('b' * 64); state = 'uploaded'; createdAt = [datetime]::UtcNow.AddMinutes(-5).ToString('o') }
                )
            } | ConvertTo-Json -Depth 5 -Compress
            Mock gh {
                $global:LASTEXITCODE = 0
                if ($args -contains 'repos/SkyMobDev/apt') { return 'main' }
                if ("$args" -match 'contents/SHA256SUMS\?ref=main') { return ('a' * 64) + '  kept_1.0_amd64.deb' }
                if ("$args" -match 'pulls\?state=open') { return '' }
                if ($args -contains 'view') { return $listing }
                return ''
            }
            Remove-AptStaleAsset -GraceDays 0 -Confirm:$false
            Should -Invoke gh -ParameterFilter { $args -contains 'delete-asset' -and $args -contains 'fresh_1.0_amd64.deb' } -Times 1 -Exactly
        }
    }
}
