# Shared helpers used by every function in this app. Kept deliberately narrow:
# this bridge exists to do exactly three things (list/grant/revoke Full Access
# on project mailboxes), not to proxy arbitrary Exchange Online PowerShell.

$ProjectMailboxPattern = '^[a-zA-Z]{5}\d{5}_.+@summation\.au$'
$SummationUserPattern = '^[^@]+@summation\.au$'

function Test-ProjectMailboxAddress {
    param([Parameter(Mandatory)][string]$Address)
    return $Address -match $ProjectMailboxPattern
}

function Test-SummationUserAddress {
    param([Parameter(Mandatory)][string]$Address)
    return $Address -match $SummationUserPattern
}

# Exchange Online sessions can go stale between invocations on a warm instance,
# so check-and-reconnect rather than assuming profile.ps1's connection is still good.
function Connect-IfNeeded {
    if (Get-ConnectionInformation -ErrorAction SilentlyContinue) {
        return
    }

    Connect-ExchangeOnline `
        -AppId $env:EXO_APP_ID `
        -Organization $env:EXO_ORGANIZATION `
        -CertificateThumbprint $env:EXO_CERT_THUMBPRINT `
        -ShowBanner:$false
}

function New-JsonResponse {
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)]$Body
    )
    return [HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = @{ "Content-Type" = "application/json" }
        Body       = ($Body | ConvertTo-Json -Depth 5)
    }
}

Export-ModuleMember -Function Test-ProjectMailboxAddress, Test-SummationUserAddress, Connect-IfNeeded, New-JsonResponse
