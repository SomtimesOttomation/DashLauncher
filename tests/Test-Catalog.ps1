<#
.SYNOPSIS  Checks the catalog rules in core\Launcher.Catalog.psm1 (no network). Run: powershell -File tests\Test-Catalog.ps1
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'core\Launcher.Catalog.psm1') -Force
$script:Failed = 0; $script:Passed = 0
function Check { param([string]$Name, [bool]$Condition, [string]$Detail = '') if ($Condition) { $script:Passed++ } else { $script:Failed++; Write-Host "FAIL  $Name  $Detail" -ForegroundColor Red } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('catalog-test-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    # --- versions
    Check 'version v1.2.3' ((ConvertTo-DashVersion 'v1.2.3') -eq [version]'1.2.3')
    Check 'version 0.12.0' ((ConvertTo-DashVersion '0.12.0') -eq [version]'0.12.0')
    Check 'version junk' ($null -eq (ConvertTo-DashVersion 'latest'))

    # --- reading: good entries kept, bad ones skipped
    Set-Content -Path $tmp -Value (@{ modules = @(
        @{ id = 'nbadash'; name = 'NBA'; title = 'NBA 2026-27'; repo = 'SomtimesOttomation/NBADash'; minVersion = '0.12.0'; icon = 'ui/img/catalog/nbadash.svg' },
        @{ id = 'f1dash'; name = 'F1'; repo = 'SomtimesOttomation/F1Dash'; published = $true },
        @{ id = 'nbadash'; name = 'Dupe'; repo = 'x/y' },
        @{ id = 'Bad'; name = 'Bad'; repo = 'x/y' },
        @{ id = 'norepo'; name = 'No repo' },
        @{ id = 'badrepo'; name = 'Bad'; repo = 'https://github.com/x/y' },
        @{ id = 'badver'; name = 'Bad'; repo = 'x/y'; minVersion = 'soon' },
        @{ id = 'badicon'; name = 'Icon'; repo = 'x/y'; icon = '../../evil.svg' }
    ) } | ConvertTo-Json -Depth 5)
    $cat = @(Read-Catalog -Path $tmp)
    Check 'reads 3 valid entries' ($cat.Count -eq 3) "got $($cat.Count): $(($cat | % { $_.Id }) -join ',')"
    Check 'title falls back to name' (($cat | ? Id -eq 'f1dash').Title -eq 'F1')
    Check 'published switch read' (($cat | ? Id -eq 'f1dash').Published -eq $true)
    Check 'unsafe icon dropped' (($cat | ? Id -eq 'badicon').Icon -eq '')
    Check 'missing file -> empty' (@(Read-Catalog -Path ($tmp + '.nope')).Count -eq 0)

    $nba = $cat | ? Id -eq 'nbadash'
    $auto = [pscustomobject]@{ Id = 'x'; Repo = 'SomtimesOttomation/NBADash'; MinVersion = $null; Published = $null }
    $rel = { param($tag) [pscustomobject]@{ Repo = 'SomtimesOttomation/NBADash'; Status = 'published'; Tag = $tag; Url = "https://github.com/SomtimesOttomation/NBADash/releases/tag/$tag"; Asset = "https://github.com/SomtimesOttomation/NBADash/releases/download/$tag/NBADash-$tag.zip"; AssetName = "NBADash-$tag.zip"; PublishedAt = '2026-10-26T14:00:00Z' } }
    $none = [pscustomobject]@{ Repo = 'SomtimesOttomation/NBADash'; Status = 'none' }
    $err = [pscustomobject]@{ Repo = 'SomtimesOttomation/NBADash'; Status = 'error'; Error = 'offline' }

    $r = Resolve-CatalogEntry -Entry $nba -Result (& $rel 'v0.12.0') -Cached $null
    Check 'published at minVersion shows' ($r.Show -and $r.Source -eq 'github' -and $r.Version -eq '0.12.0' -and $r.AssetName -eq 'NBADash-v0.12.0.zip')
    $r = Resolve-CatalogEntry -Entry $nba -Result (& $rel 'v0.11.0') -Cached $null
    Check 'older than minVersion hidden' ((-not $r.Show) -and $r.Reason -like '*older*') $r.Reason
    $r = Resolve-CatalogEntry -Entry $nba -Result $none -Cached $null
    Check 'no release hidden' ((-not $r.Show) -and $r.Reason -eq 'no published release')
    $r = Resolve-CatalogEntry -Entry $nba -Result $err -Cached (& $rel 'v0.12.0')
    Check 'offline uses cache' ($r.Show -and $r.Source -eq 'cache')
    $r = Resolve-CatalogEntry -Entry $nba -Result $err -Cached $null
    Check 'offline, no cache: hidden' ((-not $r.Show) -and $r.Source -eq 'fallback')
    $on = [pscustomobject]@{ Id = 'x'; Repo = 'SomtimesOttomation/NBADash'; MinVersion = $null; Published = $true }
    $r = Resolve-CatalogEntry -Entry $on -Result $err -Cached $null
    Check 'offline, enabled by hand: shown with release page' ($r.Show -and $r.Source -eq 'manual' -and $r.Url -eq 'https://github.com/SomtimesOttomation/NBADash/releases/latest' -and -not $r.Asset)
    $off = [pscustomobject]@{ Id = 'x'; Repo = 'SomtimesOttomation/NBADash'; MinVersion = $null; Published = $false }
    $r = Resolve-CatalogEntry -Entry $off -Result (& $rel 'v1.0.0') -Cached $null
    Check 'hidden by hand wins' ((-not $r.Show) -and $r.Source -eq 'manual')
    $evil = [pscustomobject]@{ Repo = 'SomtimesOttomation/NBADash'; Status = 'published'; Tag = 'v1.0.0'; Url = 'https://evil.example/x'; Asset = 'https://evil.example/x.zip'; AssetName = 'x.zip'; PublishedAt = '' }
    $r = Resolve-CatalogEntry -Entry $auto -Result $evil -Cached $null
    Check 'links outside the repo are not used' ($r.Show -and $r.Url -eq 'https://github.com/SomtimesOttomation/NBADash/releases/latest' -and -not $r.Asset)

    $g = @(Get-ReleaseInfo -Repos @('not a repo'))
    Check 'bad repo name is not requested' ($g.Count -eq 1 -and $g[0].Status -eq 'error' -and $g[0].Error -eq 'bad repo name')
}
finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed) { exit 1 } else { exit 0 }
