# v1.1.2

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Specify the Service Retirement CSV File")]
    [string]$ResourceIdFile = $null,
    [Parameter(Mandatory = $true, HelpMessage = "Billing period, example: 202404")]
    [string]$billingPeriod = $null,
    [Parameter(Mandatory = $false, HelpMessage = "End date with format: YYYY-MM-DD")]
    [datetime]$endDate = [datetime]::MaxValue
)

#requires -version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
Get the cost of retiring resources in a billing period

.PARAMETER resourceId
The resource ID of the resource to get the cost for

.PARAMETER billingPeriodStart
The start of the billing period in UTC format

.PARAMETER billingPeriodEnd
The end of the billing period in UTC format

.PARAMETER token
The token to use for authentication
#>
function Get-ResourceCost($resourceId, $billingPeriodStart, $billingPeriodEnd, $token) {

    $subscriptionId = $resourceId.Split("/")[2]
    $resourceGroup = $resourceId.Split("/")[4]

    $uri = "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.CostManagement/query?api-version=2023-11-01"

    $jsonPayload = @{
        type       = "ActualCost"
        dataSet    = @{
            granularity = "Monthly"
            aggregation = @{
                totalCost = @{
                    name     = "Cost"
                    function = "Sum"
                }
            }
            sorting     = @(@{
                    direction = "ascending"
                    name      = "UsageDate"
                })
            filter      = @{
                Dimensions = @{
                    Name     = "ResourceId"
                    Operator = "In"
                    Values   = @("${resourceId}")
                }
            }
        }
        timeframe  = "Custom"
        timePeriod = @{
            from = "${billingPeriodStart}"
            to   = "${billingPeriodEnd}"
        }
    }

    $jsonPayload = $jsonPayload | ConvertTo-Json -Depth 10

    $cost = 0

    # send the request. Handle errors 429 (too many requests) by waiting 30 seconds and retrying
    do {
        $requestCompleted = $false
        $statusCode = 0
        $responseHeaders = $null
        $response = Invoke-RestMethod -Uri $uri -Method Post -SkipHttpErrorCheck -StatusCodeVariable "statusCode" -ResponseHeadersVariable "responseHeaders" -Body $jsonPayload -Headers @{
            'Authorization' = "Bearer $token"
            'Content-Type'  = 'application/json'
            "Client-Type"   = "GetCostOfRetiringResources"
        }

        if ($statusCode -eq 429) {
            $qpuRetryAfter = [double]::Parse($responseHeaders['x-ms-ratelimit-microsoft.costmanagement-client-qpu-retry-after'] ?? 0)
            $clientRetryAfter = [double]::Parse($responseHeaders['x-ms-ratelimit-microsoft.costmanagement-client-retry-after'] ?? 0)
            $tenantRetryAfter = [double]::Parse($responseHeaders['x-ms-ratelimit-microsoft.costmanagement-tenant-retry-after'] ?? 0)
            $entityRetryAfter = [double]::Parse($responseHeaders['x-ms-ratelimit-microsoft.costmanagement-entity-retry-after'] ?? 0)
            
            $retryAfterSet = @($qpuRetryAfter, $clientRetryAfter, $tenantRetryAfter, $entityRetryAfter)
            $retryAfter = $retryAfterSet | Sort-Object -Descending | Select-Object -First 1
            if ($retryAfter -eq 0) {
                $retryAfter = 30    # if none of the above is set, assume a delay of 30 seconds. Otherwise use the maximum of the values
            }

            write-host -ForegroundColor DarkYellow "wait ${retryAfter}s... " -NoNewline
            Start-Sleep -Seconds $retryAfter
        }
        elseif ($statusCode -ne 200) {
            Write-host -ForegroundColor Red "Error: $statusCode"
            $requestCompleted = $true
        }
        else {
            if (($null -ne $response.properties.rows) -and ($response.properties.rows.Count -gt 0)) {
                $cost = $response.properties.rows[0][0]
                write-host -ForegroundColor Yellow ("{0:N5}" -f $cost)
            }
            else {
                write-host -ForegroundColor Green "no data"
            }
            $requestCompleted = $true
        }
    } while (-not $requestCompleted)

    return $cost
}

### main script ###

$currentDate = Get-Date

# Validate billing period
if ($billingPeriod -notmatch '^\d{6}$') {
    Write-Error "Invalid billing period format '$billingPeriod'. Expected format: yyyyMM"
    return
}

# convert billing period to a start and end date formatted as UTC strings
$billingPeriodStart = [datetime]::ParseExact($billingPeriod, "yyyyMM", $null).ToString("yyyy-MM-01T00:00:00+00:00")
$billingPeriodEnd = [datetime]::ParseExact($billingPeriod, "yyyyMM", $null).AddMonths(1).AddSeconds(-1).ToString("yyyy-MM-ddT23:59:59+00:00")

# Validate and import CSV file
if (-not (Test-Path $ResourceIdFile)) {
    Write-Error "File $ResourceIdFile does not exist"
    return
}

$resourceIds = Import-Csv -Path $ResourceIdFile -Delimiter ";"
if ($null -eq $resourceIds) {
    Write-Error "Failed to import CSV file or file is empty"
    return
}

# convert the retirement date to a datetime object
$resourceIds = $resourceIds | % { $_.'Retirement Date' = ( $_.'Retirement Date' -as [datetime] ) ; $_ }

# filter out resource whose retirement date is before today or after the end date (if specified, otherwise assume [datetime]::MaxValue)
$resourceIds = $resourceIds | Where-Object { $_.'Retirement Date' -ge $currentDate -and $_.'Retirement Date' -le $endDate }

if ($null -eq $resourceIds -or $resourceIds.Count -eq 0) {
    if ([datetime]::MaxValue -ne $endDate) {
        Write-Error "No resources found in file with future retirement date on or before ${endDate}."
    }
    else {
        Write-Error "No resources found in file with future retirement date."
    }
    return
}

Write-Host -NoNewline ([datetime]::MaxValue -eq $endDate ? "Resources in file with future retirement date: " : "Resources in file with future retirement date on or before ${endDate}: ")
Write-Host -ForegroundColor Yellow $resourceIds.Count

# if we have ASE in the list, we also need to get the list of all app plans in the ASE
$aseResources = ($resourceIds | Where-Object { $_.'Type' -eq "microsoft.web/hostingenvironments" })
if ($null -ne $aseResources) {
    Write-Host "You have $($aseResources.Count) ASE resource(s) in the list. Getting the impacted app service plans used by the ASEs..."

    $retiringFeature = $aseResources[0].'Retiring Feature'
    $retirementDate = $aseResources[0].'Retirement Date'
    $action = $aseResources[0].'Action'
    $aseResourcesIds = $aseResources.'Resource Name'

    $appPlans = Search-AzGraph -Query @"
        resources
        | where type =~ 'microsoft.web/serverfarms' and properties.hostingEnvironmentProfile <> ''
        | mv-expand ASE = properties.hostingEnvironmentProfile
        | project name, ASEid = ASE.id, type, subscriptionId, resourceGroup, location, id, tags
        | where ASEid <> ''
"@

    $impactedAppPlans = $appPlans | Where-Object { $aseResourcesIds -contains $_.ASEid }

    if ($null -eq $impactedAppPlans) {
        Write-Host "No impacted app plans found."
    }
    else {
        Write-Host "There are $($impactedAppPlans.Count) impacted app plans."

        # add the impacted app plans to the list of resources because we need to get the cost for them as well
        foreach ($appPlan in $impactedAppPlans) {
            $newresource = [PSCustomObject]@{
                'Subscription'     = $appPlan.subscriptionId
                'Type'             = $appPlan.type
                'Retiring Feature' = $retiringFeature
                'Retirement Date'  = $retirementDate
                'Resource Group'   = $appPlan.resourceGroup
                'Location'         = $appPlan.location
                'Resource Name'    = $appPlan.id
                'Tags'             = $appPlan.tags
                'Action'           = $action
            }
            Write-Host  "Adding app plan $($appPlan.Name) to the list of resources to get cost for..."
            $resourceIds += $newresource
        }
    }
}

# get a token
$token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token

# sort by retirement date (soonest first) then by retiring feature
$resourceIds = $resourceIds | Sort-Object -Property @{Expression = "Retirement Date"; Ascending = $true }, @{Expression = "Retiring Feature"; Ascending = $true }

$resourceCount = 0
$totalCost = 0
# prepare a hashtable to store cumulative costs for each resource type
$totalCostByResourceType = @{}

# iterate over the resources in the list
Write-Host
foreach ($resourceLine in $resourceIds) {

    $resourceCount++

    $resourceId = $resourceLine.'Resource Name'
    $resourceType = $resourceLine.'Type'
    # extract the resource name from the resource ID - it's the last part of the resource ID from item #7 onwards. It can have one or more slashes in it.
    $resourceName = $resourceid.Split("/")[8..($resourceid.Split("/").Count - 1)] -join "/"
    $retirementDate = $resourceLine.'Retirement Date'
    $retiringFeature = $resourceLine.'Retiring Feature'

    write-host -NoNewline "[${resourceCount}] "
    write-host -NoNewline -ForegroundColor Cyan "${retirementDate} "
    write-host -NoNewline "${resourceType}, "
    write-host -NoNewline -ForegroundColor Yellow "${retiringFeature}: "
    write-host -NoNewLine "${resourceName}: "

    # get the cost for the resource in the billing period
    $cost = Get-ResourceCost -resourceId $resourceId -billingPeriodStart $billingPeriodStart -billingPeriodEnd $billingPeriodEnd -token $token

    $totalCost += $cost
    $totalCostByResourceType["${resourceType}, ${retiringFeature}"] += $cost
}

write-host
write-host -NoNewline "Total cost for all resources in billing period ${billingPeriod}: "
write-host -ForegroundColor Yellow ("{0:N5}" -f $totalCost)

# write out the costs by resource type
write-host
write-host "Total costs by resource type:"
foreach ($resourceTypeAndRetiringFeature in $totalCostByResourceType.Keys) {
    write-host -NoNewline "${resourceTypeAndRetiringFeature}: "
    write-host -ForegroundColor Yellow ("{0:N5}" -f $totalCostByResourceType[$resourceTypeAndRetiringFeature])
}
