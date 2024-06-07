[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Specify the Service Retirement CSV File")]
    [string]$ResourceIdFile = $null,
    [Parameter(Mandatory = $true, HelpMessage = "Billing period, example: 202404")]
    [string]$billingPeriod = $null,
    [Parameter(Mandatory = $false, HelpMessage = "End date in yyyy-MM-dd")]
    [string]$endDate = $null,
    [Parameter(Mandatory = $false, HelpMessage = "CSV delimiter, default is semicolon")]
    [string]$delimiter = ";",
    [Parameter(Mandatory = $false, HelpMessage = "Export output to a file, default is console output")]
    [string]$output = $null
)

#requires -version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$totalCost = 0

# Validate billing period
if ($billingPeriod -notmatch '^\d{6}$') {
    Write-Error "Invalid billing period format '$billingPeriod'. Expected format: yyyyMM"
    return
}

# convert billing period to a start and end date formatted as UTC strings
$billingPeriodStart = [datetime]::ParseExact($billingPeriod, "yyyyMM", $null).ToString("yyyy-MM-01T00:00:00+00:00")
$billingPeriodEnd = [datetime]::ParseExact($billingPeriod, "yyyyMM", $null).AddMonths(1).AddSeconds(-1).ToString("yyyy-MM-ddT23:59:59+00:00")

# validate end date if specified
if (-not [string]::IsNullOrEmpty($endDate)) {
    if ($endDate -notmatch '^\d{4}-\d{2}-\d{2}$') {
        Write-Error "Invalid end date format '$endDate'. Expected format: yyyy-MM-dd"
        return
    }
}

# Validate and import CSV file
if (-not (Test-Path $ResourceIdFile)) {
    Write-Error "File $ResourceIdFile does not exist"
    return
}

$resourceIds = Import-Csv -Path $ResourceIdFile -Delimiter ","
if ($null -eq $resourceIds) {
    Write-Error "Failed to import CSV file or file is empty"
    return
}

# sort by retirement date (soonest first) then by retiring feature
$resourceIds = $resourceIds | Sort-Object -Property @{Expression = "Retirement Date"; Ascending = $true }, @{Expression = "Retiring Feature"; Ascending = $true }

# if an end date is specified, filter out resources with a retirement date after the end date
if (-not [string]::IsNullOrEmpty($endDate)) {
    $resourceIds = $resourceIds | Where-Object { $_.'Retirement Date' -le $endDate }
}

# filter out resources with a retirement date in the past
$currentDate = Get-Date
$resourceIds = $resourceIds | Where-Object { $_.'Retirement Date' -ge ($currentDate.ToString("yyyy-MM-dd")) }

Write-Host -NoNewline ([string]::IsNullOrEmpty($endDate) ? "All resources in file with future retirement date: " : "Resources in file with future retirement date on or before ${endDate}: ")
Write-Host -ForegroundColor Yellow $resourceIds.Count

# get a token
$token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token

# iterate over the resources in the list
$totalCost = 0
$currentDate = Get-Date
$line = 0
$export = @()
$currency = $null
foreach ($resourceLine in $resourceIds) {

    $line++
    $row = $null

    $resourceId = $resourceLine.'Resource Name'
    $subscriptionId = $resourceId.Split("/")[2]
    $resourceType = $resourceLine.'Type'
    # extract the resource name from the resource ID - it's the last part of the resource ID from item #7 onwards. It can have one or more slashes in it.
    $resourceName = $resourceid.Split("/")[8..($resourceid.Split("/").Count - 1)] -join "/"
    $resourceGroup = $resourceid.Split("/")[4]
    $retirementDate = $resourceLine.'Retirement Date'
    $retiringFeature = $resourceLine.'Retiring Feature'

    # get the cost for the resource in the billing period
    write-host -NoNewline "[${line}] "
    write-host -NoNewline -ForegroundColor Cyan "${retirementDate} "
    write-host -NoNewline "${resourceType}, "
    write-host -NoNewline -ForegroundColor Yellow "${retiringFeature}: "
    write-host -NoNewLine "${resourceName}: "

    if ($output -ne $null) {
        $row = [PSCustomObject]@{
            'Resource Name' = $resourceName
            'Resource Type' = $resourceType
            'Subscription ID' = $subscriptionId
            'Resource Group' = $resourceGroup
            'Retirement Date' = $retirementDate
            'Retiring Feature' = $retiringFeature
            'Cost' = 0
            'Currency' = $null
        }
    }

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
        $done = $false
        $statusCode = 0
        $response = Invoke-RestMethod -Uri $uri -Method Post -SkipHttpErrorCheck -StatusCodeVariable "statusCode" -Body $jsonPayload -Headers @{
            'Authorization' = "Bearer $token"
            'Content-Type'  = 'application/json'
        }
        if ($statusCode -eq 429) {
            write-host -ForegroundColor DarkYellow "wait... " -NoNewline
            Start-Sleep -Seconds 30
        }
        elseif ($statusCode -ne 200) {
            Write-host -ForegroundColor Red "Error: $statusCode"
            $done = $true
        }
        else {
            if (($null -ne $response.properties.rows) -and ($response.properties.rows.Count -gt 0)) {
                $cost = $response.properties.rows[0][0]
                $currency = $response.properties.rows[0][2]
                write-host -ForegroundColor Yellow ("{0:N5} {1}" -f $cost, $currency)   
                if ($output -ne $null) {
                    $row.'Cost' = $cost
                    $row.'Currency' = $currency
                }         
            }
            else {
                write-host -ForegroundColor Green "no data"
            }
            $done = $true
        }
    } while (-not $done)
    
    $totalCost += $cost
    if ($output -ne $null) {
        $export += $row
    } 
}

write-host
write-host -NoNewline "Total cost for all resources in billing period ${billingPeriod}: "
write-host -ForegroundColor Yellow ("{0:N5} {1}" -f $totalCost, $currency)

if ($output -ne $null) {
    $export | Export-Csv -Path $output -Delimiter $delimiter -NoTypeInformation
    write-host
    write-host "Exported to $output"
}