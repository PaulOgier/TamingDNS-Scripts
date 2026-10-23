# Microsoft 365 DKIM tokens for hyphenated domains

Microsoft 365 drops the hyphens from a domain's DKIM CNAME targets and MX host and adds a short suffix that records where the hyphens were. `b-and-q.co.uk` becomes `bandq-co-uk0cc`. Microsoft doesn't document it.

The write-up, with the rule, our results and the sources: https://tamingdns.com/articles/m365-dkim-hyphen

This folder has what we used to work it out, so you can check our results or test your own tenant.

## Check without changing anything

If you already have a hyphenated domain in Microsoft 365, you need no script at all.

1. Get the values Microsoft generated (Exchange Online PowerShell, read-only):

   ```powershell
   Get-DkimSigningConfig -Identity your-domain.com | Format-List Selector1CNAME, Selector2CNAME
   ```

2. Put your domain into the DKIM checker at https://tamingdns.com/dkim. It works out the token Microsoft should have built and flags a CNAME that carries a different one.

## See ours live

These subdomains of osh.co.za are kept in our own Microsoft 365 tenant on purpose, so you can see Microsoft's answer for each one from anywhere. All six returned A records on 23 October 2026:

| Domain | Token | Check |
|---|---|---|
| tok-a.osh.co.za | `toka-osh-co-za0i` | `dig A toka-osh-co-za0i.mail.protection.outlook.com` |
| tok-b-c.osh.co.za | `tokbc-osh-co-za0ic` | `dig A tokbc-osh-co-za0ic.mail.protection.outlook.com` |
| tokk-a.osh.co.za | `tokka-osh-co-za01b` | `dig A tokka-osh-co-za01b.mail.protection.outlook.com` |
| tok---a.osh.co.za | `toka-osh-co-za0id` | `dig A toka-osh-co-za0id.mail.protection.outlook.com` |
| xn--tok-3fd.osh.co.za | `xntok3fd-osh-co-za0mi` | `dig A xntok3fd-osh-co-za0mi.mail.protection.outlook.com` |
| tokab.osh.co.za (no hyphen) | `tokab-osh-co-za` | `dig A tokab-osh-co-za.mail.protection.outlook.com` |

Each name resolves because Microsoft created it. Try the same name with the hyphens left in (`tok-a-osh-co-za.mail.protection.outlook.com`) and you get NXDOMAIN.

## Reproduce the test in your own tenant

**These scripts write to your tenant.** `Test-TokenNamingGraph.ps1 -Action Add` adds domains to Microsoft 365, and `-Action Remove` deletes them, which cannot be undone. `Test-TokenNamingExo.ps1 -Action Create` adds disabled DKIM signing configs. Read both scripts before you run them. Every line has a comment saying what it does.

What keeps them away from your real domains:

- Every domain you pass must be a subdomain of the `-ParentDomain` you name, and its first label must contain `tok`. Anything else is refused, including on delete.
- The tenant ID is a parameter, never written into the file. Sign-in is pinned to it, and the script stops if the session is in another tenant.
- The DKIM configs are created disabled, so nothing is ever signed with them and no DNS record is needed.

### What you need

- PowerShell 7 (`pwsh`). We ran these on macOS; they use nothing Windows-only.
- Two modules, installed once:

  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  Install-Module ExchangeOnlineManagement -Scope CurrentUser
  ```

- An admin account that can add domains in Microsoft 365 and manage DKIM in Exchange Online. A Global Administrator can do both. The Graph script asks for the `Domain.ReadWrite.All` permission when you sign in.
- Your tenant ID (a GUID). In the Microsoft Entra admin centre it's under Entra ID > Overview > Properties.
- A domain already verified in that tenant, to put the test subdomains under. A subdomain of a verified domain verifies itself, so you add no DNS records anywhere.

### How to run them

Download both `.ps1` files. Run each one with `pwsh -NoProfile -File` and the full path to the file, in a **new** PowerShell window each time. The Graph sign-in and the Exchange Online sign-in don't work in the same window.

Pick your test names. Each one must start with a label containing `tok`, sit directly under your verified domain, and be passed as one comma-separated list in quotes. Replace the tenant ID and `contoso.com` below with your own.

**1. Add the test domains** (writes):

```powershell
pwsh -NoProfile -File "/full/path/Test-TokenNamingGraph.ps1" -TenantId 00000000-0000-0000-0000-000000000000 -ParentDomain contoso.com -Action Add -Domains "tok-a.contoso.com,tokk-a.contoso.com,tokab.contoso.com"
```

A browser window opens for sign-in. You should see one line per domain:

```
ADDED tok-a.contoso.com | verified True | services Email
```

**2. Read the MX host Microsoft built for each** (read-only). Wait a couple of minutes first:

```powershell
pwsh -NoProfile -File "/full/path/Test-TokenNamingGraph.ps1" -TenantId 00000000-0000-0000-0000-000000000000 -ParentDomain contoso.com -Action Read -Domains "tok-a.contoso.com,tokk-a.contoso.com,tokab.contoso.com"
```

The token is the first part of the `MX` value, before `.mail.protection.outlook.com`.

**3. Optional: read the DKIM targets** (writes: creates disabled DKIM configs). Use a new window, and give Exchange a few minutes after step 1 to see the new domains:

```powershell
pwsh -NoProfile -File "/full/path/Test-TokenNamingExo.ps1" -TenantId 00000000-0000-0000-0000-000000000000 -ParentDomain contoso.com -Action Create -Domains "tok-a.contoso.com,tokk-a.contoso.com,tokab.contoso.com"
```

Each domain prints its two CNAME targets:

```
tok-a.contoso.com | enabled False | status CnameMissing | s1 selector1-toka-contoso-com0i._domainkey.<tenant>.r-v1.dkim.mail.microsoft | s2 ...
```

`CnameMissing` is expected: you never publish these. If a line says `NOT YET ACCEPTED`, Exchange hasn't caught up with step 1. Wait a few minutes and run the same command again.

**4. Clean up** (writes; the domain delete cannot be undone). DKIM configs first, then the domains, each in its own new window:

```powershell
pwsh -NoProfile -File "/full/path/Test-TokenNamingExo.ps1" -TenantId 00000000-0000-0000-0000-000000000000 -ParentDomain contoso.com -Action Remove -Domains "tok-a.contoso.com,tokk-a.contoso.com,tokab.contoso.com"
pwsh -NoProfile -File "/full/path/Test-TokenNamingGraph.ps1" -TenantId 00000000-0000-0000-0000-000000000000 -ParentDomain contoso.com -Action Remove -Domains "tok-a.contoso.com,tokk-a.contoso.com,tokab.contoso.com"
```

After the Graph delete, the Defender DKIM page kept listing the domains for about two hours in our tenant on 20 October 2026. That is Exchange catching up, not a failed delete.

Any domain that fails prints `FAILED <domain>` with Microsoft's error message, and the script moves on to the next one.

## Found one that breaks the rule?

Send the domain and the CNAME Microsoft gave you to paul@osh.co.za and I'll tell you where it breaks it.

## Licence

MIT. See `LICENSE` in the repository root.
