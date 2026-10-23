# WRITES to Exchange Online: -Action Create makes DISABLED DKIM signing configs for test subdomains, -Action Remove deletes them. -Action Read only reads.
<#
.SYNOPSIS
    Creates a disabled DKIM signing config for each test subdomain so Exchange Online shows the
    selector CNAME targets it generates, then removes them. Pairs with Test-TokenNamingGraph.ps1.

.DESCRIPTION
    Run after Test-TokenNamingGraph.ps1 -Action Add (give Exchange a few minutes to see the new
    accepted domains), and before Test-TokenNamingGraph.ps1 -Action Remove (a domain with a DKIM
    config still attached may refuse deletion). The configs are created with -Enabled $false, so
    nothing is ever signed with them and no DNS record is needed.
    Same safety rail as the Graph script: only 'tok' test subdomains of -ParentDomain are accepted.
    Run in its OWN window: pwsh -NoProfile -File "<absolute path>" ...

.PARAMETER TenantId
    Tenant GUID. The script stops unless every connected Exchange Online session is in this tenant.

.PARAMETER ParentDomain
    The verified parent the test subdomains sit under.

.PARAMETER Action
    Create, Read or Remove.

.PARAMETER Domains
    The test subdomains.
#>
# Lets the script take named parameters like a cmdlet.
[CmdletBinding()]
# The values the script needs; nothing tenant-specific is written into the file.
param(
    # Tenant GUID the Exchange Online session must be in.
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TenantId,
    # Verified parent domain the test subdomains live under.
    [Parameter(Mandatory)][string]$ParentDomain,
    # What to do: Create, Read or Remove.
    [Parameter(Mandatory)][ValidateSet('Create', 'Read', 'Remove')][string]$Action,
    # The test subdomains to work on.
    [Parameter(Mandatory)][string[]]$Domains
# End of the parameters.
)

# Stop on any error from here on, so nothing runs after a failure.
$ErrorActionPreference = 'Stop'
# Lower-case the parent domain so the safety check compares like with like.
$parent = $ParentDomain.ToLower()
# Split any comma-joined entries (pwsh -File passes 'a,b' as one string), trim, lower-case and drop blanks.
$Domains = @(foreach ($x in $Domains) { foreach ($y in $x.Split(',')) { if ($y.Trim()) { $y.Trim().ToLower() } } })
# Check every domain before connecting, so a bad list never reaches the tenant.
foreach ($d in $Domains) {
    # Lower-case this domain for the comparison.
    $l = $d.ToLower()
    # Its first label (the part before the first dot).
    $first = $l.Split('.')[0]
    # Refuse anything that is not a 'tok' test label directly under the parent domain.
    if (-not $l.EndsWith('.' + $parent) -or -not $first.Contains('tok') -or $l -ne ($first + '.' + $parent)) { throw "REFUSED: $d is not a 'tok' test subdomain of $parent" }
# End of the safety check.
}

# Sign in to Exchange Online (browser sign-in); stop if it fails.
Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
# Every live Exchange Online connection in this window (a stale one can be listed first).
$conns = @(Get-ConnectionInformation | Where-Object { $PSItem.State -eq 'Connected' })
# Any connected session in a different tenant.
$wrong = @($conns | Where-Object { $PSItem.TenantID -ne $TenantId })
# Stop if nothing is connected or any connection is in another tenant; otherwise do the work below.
if ($conns.Count -eq 0 -or $wrong.Count -gt 0) { throw "WRONG TENANT or not connected: sessions in $(@($conns.TenantID) -join ', '), expected $TenantId" } else {
    # Show which tenant this is.
    'Exchange Online tenant: {0} | Action: {1}' -f $conns[0].TenantID, $Action
    # Work through the test domains one at a time.
    foreach ($d in $Domains) {
      # One domain failing is reported and the run moves on to the next.
      try {
        # Look for the domain among Exchange's accepted domains by listing and matching (a not-found -Identity lookup returned a non-empty object, 2026-10-20).
        $acc = Get-AcceptedDomain | Where-Object { [string]$PSItem.DomainName -eq $d } | Select-Object -First 1
        # Look for an existing DKIM config for it the same way.
        $cfg = Get-DkimSigningConfig | Where-Object { [string]$PSItem.Domain -eq $d } | Select-Object -First 1
        # Create: make a DISABLED config so Exchange generates the selector CNAME targets.
        if ($Action -eq 'Create') {
            # Exchange has not picked the domain up yet: say so and move on (re-run later).
            if (-not $acc) { 'NOT YET ACCEPTED {0} (wait a few minutes and re-run -Action Create)' -f $d }
            # A config already exists: do not make another.
            elseif ($cfg) { 'ALREADY HAS CONFIG {0}' -f $d }
            # Create the config, switched off, so nothing is ever signed with it.
            else { $null = New-DkimSigningConfig -DomainName $d -Enabled $false -ErrorAction Stop; 'CREATED {0}' -f $d }
            # Re-read the config so the output shows what Exchange holds.
            $cfg = Get-DkimSigningConfig | Where-Object { [string]$PSItem.Domain -eq $d } | Select-Object -First 1
        # End of Create.
        }
        # Create and Read both print the generated selector targets.
        if ($Action -ne 'Remove') {
            # No config to show for this domain.
            if (-not $cfg) { 'NO CONFIG {0}' -f $d }
            # Print the domain, its status and both selector CNAME targets.
            else { '{0} | enabled {1} | status {2} | s1 {3} | s2 {4}' -f $d, $cfg.Enabled, $cfg.Status, $cfg.Selector1CNAME, $cfg.Selector2CNAME }
        # End of Create/Read output.
        }
        # Remove: delete the config if there is one.
        if ($Action -eq 'Remove') {
            # Nothing to delete.
            if (-not $cfg) { 'NO CONFIG {0} (nothing to remove)' -f $d }
            # Delete it without the confirmation prompt (the safety rail above already limits which domains get here).
            else { Remove-DkimSigningConfig -Identity $d -Confirm:$false -ErrorAction Stop; 'REMOVED CONFIG {0}' -f $d }
        # End of Remove.
        }
      # Report this domain's failure with Exchange's message, then carry on with the next domain.
      } catch { 'FAILED {0} ({1}): {2}' -f $d, $Action, $PSItem.Exception.Message }
    # End of the domain loop.
    }
# End of the tenant-checked block.
}
# Marks the end of the run.
'Done'
