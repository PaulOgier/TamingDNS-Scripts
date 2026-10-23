# WRITES to a Microsoft 365 tenant (Microsoft Graph, Domain.ReadWrite.All): -Action Add creates test subdomains, -Action Remove deletes them (NOT recoverable). -Action Read only reads.
<#
.SYNOPSIS
    Adds throwaway test subdomains, reads the MX host Microsoft generates for each, then removes them,
    to learn how Microsoft 365 turns a domain name into its MX/DKIM token.

.DESCRIPTION
    Run order: -Action Add, wait a few minutes, -Action Read, then the Exchange Online script
    (Test-TokenNamingExo.ps1 -Action Create, then -Action Remove), then -Action Remove here.
    Subdomains of a verified parent verify automatically (Graph domain-post-domains doc), so no
    DNS record is created anywhere and no mail flow changes.
    Safety rail: every domain must be a subdomain of -ParentDomain whose first label contains 'tok',
    so the script cannot touch a real domain. Delete is refused for anything outside that rail.
    Run in a FRESH window: pwsh -NoProfile -File "<absolute path>" ...
    (Graph cannot sign in inside a session that already loaded Exchange Online.)

.PARAMETER TenantId
    Tenant GUID. Sign-in is pinned to it and the script stops if Graph reports another tenant.

.PARAMETER ParentDomain
    The verified parent the test subdomains sit under.

.PARAMETER Action
    Add, Read or Remove.

.PARAMETER Domains
    The test subdomains.
#>
# Lets the script take named parameters like a cmdlet.
[CmdletBinding()]
# The values the script needs; nothing tenant-specific is written into the file.
param(
    # Tenant GUID to sign in to.
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TenantId,
    # Verified parent domain the test subdomains live under.
    [Parameter(Mandatory)][string]$ParentDomain,
    # What to do: Add, Read or Remove.
    [Parameter(Mandatory)][ValidateSet('Add', 'Read', 'Remove')][string]$Action,
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
# Check every domain before signing in, so a bad list never reaches the tenant.
foreach ($d in $Domains) {
    # Lower-case this domain for the comparison.
    $l = $d.ToLower()
    # Its first label (the part before the first dot).
    $first = $l.Split('.')[0]
    # Refuse anything that is not a 'tok' test label directly under the parent domain.
    if (-not $l.EndsWith('.' + $parent) -or -not $first.Contains('tok') -or $l -ne ($first + '.' + $parent)) { throw "REFUSED: $d is not a 'tok' test subdomain of $parent" }
# End of the safety check.
}

# Sign in to Graph for that tenant only, with permission to add and delete domains; stop if sign-in fails.
Connect-MgGraph -TenantId $TenantId -Scopes 'Domain.ReadWrite.All' -NoWelcome -ErrorAction Stop
# Prove the token works and read which tenant it is really in (Get-MgContext can lie after a failed sign-in).
$org = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName' -ErrorAction Stop
# Stop if no tenant came back or it is not the expected one; otherwise do the work below.
if (-not $org.value -or $org.value[0].id -ne $TenantId) { throw "WRONG TENANT: signed in to $($org.value[0].id) $($org.value[0].displayName), expected $TenantId" } else {
    # Show which tenant this is.
    'Tenant: {0} {1} | Action: {2}' -f $org.value[0].displayName, $org.value[0].id, $Action
    # List the tenant's domains once, so Add and Remove can skip ones already done (safe to re-run).
    $existing = @((Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$select=id' -ErrorAction Stop).value.id)
    # Read the parent domain, so a mistyped parent stops the run instead of creating unverified orphans.
    $par = Invoke-MgGraphRequest -Method GET -Uri ('https://graph.microsoft.com/v1.0/domains/' + $parent) -ErrorAction Stop
    # Stop unless the parent is a verified domain of this tenant.
    if (-not $par.isVerified) { throw "PARENT NOT VERIFIED in this tenant: $parent" }
    # Work through the test domains one at a time.
    foreach ($d in $Domains) {
      # One domain failing (e.g. a label Microsoft rejects) is reported and the run moves on to the next.
      try {
        # Add: create the domain if absent, then make sure the Email service is on, so Microsoft generates its MX record.
        if ($Action -eq 'Add') {
            # Create the domain object only if it is not there yet (a subdomain of a verified parent is verified automatically).
            if (-not ($existing -contains $d)) { $null = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/domains' -Body (@{ id = $d } | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop }
            # Read the domain as it stands now.
            $dom = Invoke-MgGraphRequest -Method GET -Uri ('https://graph.microsoft.com/v1.0/domains/' + $d) -ErrorAction Stop
            # Switch on Email only if it is missing, so a re-run finishes a half-done add instead of skipping it.
            if (-not (@($dom.supportedServices) -contains 'Email')) { $null = Invoke-MgGraphRequest -Method PATCH -Uri ('https://graph.microsoft.com/v1.0/domains/' + $d) -Body (@{ supportedServices = @('Email') } | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop }
            # Read it back so the output shows state, not intent.
            $dom = Invoke-MgGraphRequest -Method GET -Uri ('https://graph.microsoft.com/v1.0/domains/' + $d) -ErrorAction Stop
            # Print what the tenant now holds for this domain.
            'ADDED {0} | verified {1} | services {2}' -f $dom.id, $dom.isVerified, ($dom.supportedServices -join ',')
        # End of Add.
        }
        # Read: print the MX host Microsoft expects for the domain.
        if ($Action -eq 'Read') {
            # Read the DNS records Microsoft says the domain should have.
            $recs = Invoke-MgGraphRequest -Method GET -Uri ('https://graph.microsoft.com/v1.0/domains/' + $d + '/serviceConfigurationRecords') -ErrorAction Stop
            # Read the domain too, so "no MX" can be told apart from "Email service never applied".
            $dom = Invoke-MgGraphRequest -Method GET -Uri ('https://graph.microsoft.com/v1.0/domains/' + $d) -ErrorAction Stop
            # Print its verification state and services.
            'STATE {0} | verified {1} | services {2}' -f $d, $dom.isVerified, ($dom.supportedServices -join ',')
            # Keep only the MX record(s).
            $mx = @($recs.value | Where-Object { $PSItem.recordType -eq 'Mx' })
            # Say so plainly when there is none, rather than printing nothing.
            if ($mx.Count -eq 0) { 'READ  {0} | NO MX RECORD RETURNED ({1} records in total)' -f $d, @($recs.value).Count }
            # Print each MX host with its priority.
            foreach ($r in $mx) { 'READ  {0} | MX {1} | priority {2}' -f $d, $r.mailExchange, $r.preference }
        # End of Read.
        }
        # Remove: delete the domain (not recoverable; only test subdomains get past the check above).
        if ($Action -eq 'Remove' -and -not ($existing -contains $d)) { 'NOT PRESENT {0} (nothing to remove)' -f $d }
        # Remove a domain that is there.
        if ($Action -eq 'Remove' -and ($existing -contains $d)) {
            # Delete the domain object.
            Invoke-MgGraphRequest -Method DELETE -Uri ('https://graph.microsoft.com/v1.0/domains/' + $d) -ErrorAction Stop
            # Confirm by listing domains and looking for it, which cannot be confused with an auth error.
            $all = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$select=id' -ErrorAction Stop
            # Report whether it is still listed.
            if (@($all.value.id) -contains $d) { 'STILL LISTED {0} (deletion can take a moment; re-run -Action Remove later)' -f $d } else { 'REMOVED {0}' -f $d }
        # End of Remove.
        }
      # Report this domain's failure with Microsoft's message, then carry on with the next domain.
      } catch { 'FAILED {0} ({1}): {2}' -f $d, $Action, $PSItem.Exception.Message }
    # End of the domain loop.
    }
# End of the tenant-checked block.
}
# Marks the end of the run.
'Done'
