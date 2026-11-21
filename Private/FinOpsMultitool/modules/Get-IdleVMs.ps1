# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console tool; the formatted console output is the user interface.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helper named for the collection it processes.')]
param()

###########################################################################
# GET-IDLEVMS.PS1
# AZURE FINOPS MULTITOOL - Idle & Underutilized VM Detection
###########################################################################
# Purpose: Query Azure Monitor metrics to find running VMs with very low
#          CPU and network utilization that Advisor hasn't flagged yet.
#          These are candidates for downsizing or shutting down.
###########################################################################
# Notes:
# - Metrics are read with the Azure Monitor metrics:getBatch API, up to 50
#   VMs per call (same subscription and region). For 800 VMs that's about
#   20 calls instead of 800.
# - getBatch needs Monitoring Reader on the subscription, not just the VM,
#   and only runs in the public cloud. Any batch that is denied or fails is
#   retried one VM at a time with the per-resource metrics API, so coverage
#   never drops below the per-VM path.
###########################################################################

# Turns one VM's metric list (the "value" array of a metrics response) into
# measured CPU and network totals. Throws when a measurement is missing or
# invalid, so the caller counts the VM as not evaluated instead of idle.
function Get-IdleVmMeasurement {
    param([AllowNull()][object[]]$Metrics)

    $avgCpu = $null
    $totalNetIn = 0
    $totalNetOut = 0
    $networkInSamples = 0
    $networkOutSamples = 0

    foreach ($metric in $Metrics) {
        $metricName = $metric.name.value
        if ($metric.PSObject.Properties.Name -contains 'errorCode' -and $metric.errorCode -and $metric.errorCode -ne 'Success') {
            throw "Metric '$metricName' returned $($metric.errorCode)."
        }
        foreach ($ts in $metric.timeseries) {
            foreach ($dp in $ts.data) {
                switch ($metricName) {
                    'Percentage CPU' {
                        $avgCpu = Get-HubCostValue -Row $dp -Column 'average'
                        if ($avgCpu -lt 0 -or $avgCpu -gt 100) { throw 'CPU measurement is outside the valid percentage range.' }
                    }
                    'Network In Total' {
                        $networkValue = Get-HubCostValue -Row $dp -Column 'total'
                        if ($networkValue -lt 0) { throw 'Network measurement cannot be negative.' }
                        $totalNetIn += $networkValue
                        $networkInSamples++
                    }
                    'Network Out Total' {
                        $networkValue = Get-HubCostValue -Row $dp -Column 'total'
                        if ($networkValue -lt 0) { throw 'Network measurement cannot be negative.' }
                        $totalNetOut += $networkValue
                        $networkOutSamples++
                    }
                }
            }
        }
    }

    if ($null -eq $avgCpu -or $networkInSamples -eq 0 -or $networkOutSamples -eq 0) { throw 'CPU or network measurements are missing; the VM was not evaluated.' }
    [PSCustomObject]@{ AvgCpu = $avgCpu; TotalNetwork = $totalNetIn + $totalNetOut }
}

function Get-IdleVMs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Subscriptions
    )

    Write-Host "  Scanning for idle and underutilized VMs..." -ForegroundColor Cyan

    $subIds = $Subscriptions | ForEach-Object { $_.Id }
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $metricFailures = [System.Collections.Generic.List[string]]::new()

    # -- 1: Find all running VMs ------------------------------------------
    # Pull every VM with its power state so we can distinguish "no VMs at all"
    # from "VMs exist but are all deallocated" (idle detection only applies to
    # RUNNING VMs - a deallocated VM has no CPU to sample).
    $totalVMs = 0
    $deallocatedCount = 0
    try {
        $query = @"
resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend powerState = tostring(properties.extended.instanceView.powerState.code)
| project id, name, resourceGroup, subscriptionId, location,
          vmSize = properties.hardwareProfile.vmSize,
          osType = properties.storageProfile.osDisk.osType,
          powerState
"@
        $result = Search-AzGraphSafe -Query $query -Subscription $subIds -First 1000 -All
        $allVMs = if ($result) { @($result.Data) } else { @() }
        $totalVMs = $allVMs.Count
        $runningVMs = @($allVMs | Where-Object { $_.powerState -eq 'PowerState/running' })
        $deallocatedCount = $totalVMs - $runningVMs.Count
        Write-Host "    VMs found: $totalVMs ($($runningVMs.Count) running, $deallocatedCount stopped/deallocated)" -ForegroundColor Gray
    }
    catch {
        throw "Running VM inventory is incomplete: $($_.Exception.Message)"
    }

    if ($runningVMs.Count -eq 0) {
        $note = if ($totalVMs -gt 0) {
            "$totalVMs VM(s) found but none are running ($deallocatedCount stopped/deallocated), so there is no CPU to sample for idle detection. Stopped/deallocated VMs still incur disk and IP cost - run the orphaned resources scan."
        }
        else {
            'No virtual machines found in scope.'
        }
        return [PSCustomObject]@{
            IdleVMs             = @()
            Count               = 0
            HasData             = $false
            ScannedVMs          = 0
            TotalVMs            = $totalVMs
            DeallocatedVMs      = $deallocatedCount
            # Same shape as the main return so callers can read these on either path.
            EvaluatedVMs        = 0
            MetricFailures      = 0
            MetricFailureDetail = @()
            Note                = $note
        }
    }

    # -- 2: Read 14-day avg CPU + network for each VM --------------------
    $armBase = Get-FinOpsArmEndpoint
    $now = (Get-Date).ToUniversalTime()
    $fourteenDaysAgo = $now.AddDays(-14).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $nowStr = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $batchStart = $now.AddDays(-14).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $batchEnd = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $metricNames = 'Percentage CPU,Network In Total,Network Out Total'

    $cpuThreshold = 5    # avg CPU < 5% = idle
    $networkThreshold = 1048576  # < 1 MB/day total network = idle (14d * 1MB = 14MB)
    $networkThreshold14d = $networkThreshold * 14

    $vmCount = $runningVMs.Count
    $progress = @{ Done = 0; Next = 1; Step = [math]::Max(1, [int][math]::Ceiling($vmCount / 20)) }
    $reportProgress = {
        param([int]$Count)
        $progress.Done += $Count
        if ($vmCount -gt 10 -and $progress.Done -ge $progress.Next -and (Get-Command Update-ScanStatus -ErrorAction SilentlyContinue)) {
            Update-ScanStatus "Checking VM metrics ($([math]::Min($progress.Done, $vmCount))/$vmCount VMs)..."
            $progress.Next = $progress.Done + $progress.Step
        }
    }
    $vmScope = { param($Vm) "/subscriptions/$($Vm.subscriptionId)/resourceGroups/$($Vm.resourceGroup)/providers/Microsoft.Compute/virtualMachines/$($Vm.name)" }
    $classifyVm = {
        param($Vm, $Measurement)
        $avgCpu = $Measurement.AvgCpu
        $totalNetwork = $Measurement.TotalNetwork
        $classification = if ($avgCpu -lt $cpuThreshold -and $totalNetwork -lt $networkThreshold14d) { 'Idle' }
        elseif ($avgCpu -lt 10 -and $totalNetwork -lt ($networkThreshold14d * 10)) { 'Underutilized' }
        else { $null }
        if ($classification) {
            $dailyNetMB = [math]::Round($totalNetwork / 14 / 1MB, 2)
            [void]$results.Add([PSCustomObject]@{
                    VMName         = $Vm.name
                    ResourceGroup  = $Vm.resourceGroup
                    SubscriptionId = $Vm.subscriptionId
                    Location       = $Vm.location
                    VMSize         = $Vm.vmSize
                    OS             = $Vm.osType
                    AvgCPU14d      = [math]::Round($avgCpu, 1)
                    NetworkPerDay  = "$($dailyNetMB) MB"
                    Classification = $classification
                    Recommendation = if ($classification -eq 'Idle') { 'Deallocate or delete' } else { 'Downsize VM' }
                })
        }
    }

    # Batch reads: one call per 50 VMs that share a subscription and region.
    $perVm = [System.Collections.Generic.List[object]]::new()
    $batchToken = $null
    if ($armBase -eq 'https://management.azure.com') {
        try { $batchToken = Get-PlainAccessToken -ResourceUrl 'https://metrics.monitor.azure.com' }
        catch { Write-Verbose "    Batch metrics token unavailable; reading VMs one at a time. $($_.Exception.Message)" }
    }
    if ($batchToken) {
        $batchHeaders = @{ 'Authorization' = "Bearer $batchToken" }
        $groups = $runningVMs | Group-Object { "$($_.subscriptionId)|$(([string]$_.location).ToLowerInvariant())" }
        foreach ($group in $groups) {
            $subscriptionId, $region = $group.Name -split '\|', 2
            $members = @($group.Group)
            if ($region -notmatch '^[a-z0-9]+$' -or $subscriptionId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                foreach ($vm in $members) { $perVm.Add($vm) }
                continue
            }
            for ($offset = 0; $offset -lt $members.Count; $offset += 50) {
                $chunk = @($members[$offset..([math]::Min($offset + 49, $members.Count - 1))])
                $ids = @($chunk | ForEach-Object { & $vmScope $_ })
                $deferred = 0
                try {
                    $batchUri = "https://$region.metrics.monitor.azure.com/subscriptions/$subscriptionId/metrics:getBatch?api-version=2023-10-01&metricnamespace=Microsoft.Compute/virtualMachines&metricnames=$metricNames&starttime=$batchStart&endtime=$batchEnd&aggregation=average,total&interval=FULL"
                    $body = @{ resourceids = $ids } | ConvertTo-Json -Depth 3 -Compress
                    $resp = Invoke-WebRequest -Uri $batchUri -Headers $batchHeaders -Method Post -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 0 -ErrorAction Stop
                    $byId = @{}
                    foreach ($entry in @(($resp.Content | ConvertFrom-Json).values)) {
                        if ($entry -and $entry.resourceid) { $byId[([string]$entry.resourceid).ToLowerInvariant()] = $entry }
                    }
                    for ($n = 0; $n -lt $chunk.Count; $n++) {
                        $entry = $byId[$ids[$n].ToLowerInvariant()]
                        # A VM the batch didn't answer for gets its own call rather than a guess.
                        if (-not $entry) { $perVm.Add($chunk[$n]); $deferred++; continue }
                        try { & $classifyVm $chunk[$n] (Get-IdleVmMeasurement -Metrics $entry.value) }
                        catch { [void]$metricFailures.Add("$($chunk[$n].name): $($_.Exception.Message)") }
                    }
                }
                catch {
                    Write-Verbose "    Batch metrics read failed for $($chunk.Count) VM(s) in $region; reading them one at a time. $($_.Exception.Message)"
                    foreach ($vm in $chunk) { $perVm.Add($vm) }
                    $deferred = $chunk.Count
                }
                & $reportProgress ($chunk.Count - $deferred)
            }
        }
    }
    else {
        foreach ($vm in $runningVMs) { $perVm.Add($vm) }
    }

    # Per-VM reads: sovereign clouds, missing subscription-level Monitoring Reader,
    # or anything a batch didn't answer.
    if ($perVm.Count -gt 0) {
        $token = Get-PlainAccessToken -ResourceUrl $armBase
        $headers = @{ 'Authorization' = "Bearer $token"; 'Content-Type' = 'application/json' }
        foreach ($vm in $perVm) {
            $scope = & $vmScope $vm
            try {
                # FULL is the only way to get one datapoint for the whole span:
                # P14D is not a published timegrain and the API rejects it.
                $metricUri = "$armBase$scope/providers/Microsoft.Insights/metrics?api-version=2023-10-01&metricnames=$metricNames&timespan=$fourteenDaysAgo/$nowStr&aggregation=Average,Total&interval=FULL"
                $resp = Invoke-WebRequest -Uri $metricUri -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 0 -ErrorAction Stop
                & $classifyVm $vm (Get-IdleVmMeasurement -Metrics ($resp.Content | ConvertFrom-Json).value)
            }
            catch {
                # A throttled or unauthorized metrics call is not the same as a busy VM,
                # so count it rather than letting it read as "nothing to report".
                [void]$metricFailures.Add("$($vm.name): $($_.Exception.Message)")
            }
            & $reportProgress 1
        }
    }
    if ($metricFailures.Count -gt 0) {
        Write-Warning "    Metrics unavailable for $($metricFailures.Count) of $($runningVMs.Count) VM(s); those VMs were not evaluated."
        foreach ($f in ($metricFailures | Select-Object -First 3)) { Write-Verbose "      $f" }
    }

    Write-Host "    Idle/underutilized VMs: $($results.Count)" -ForegroundColor Gray

    [PSCustomObject]@{
        IdleVMs             = @($results)
        Count               = $results.Count
        HasData             = ($results.Count -gt 0)
        ScannedVMs          = $runningVMs.Count
        TotalVMs            = $totalVMs
        DeallocatedVMs      = $deallocatedCount
        # Evaluated excludes VMs whose metrics could not be read, so a caller can
        # tell a clean result from a partial one.
        EvaluatedVMs        = ($runningVMs.Count - $metricFailures.Count)
        MetricFailures      = $metricFailures.Count
        MetricFailureDetail = @($metricFailures)
        Note                = if ($metricFailures.Count -gt 0) { 'VM utilization coverage is incomplete; VMs with unreadable metrics are not assumed active.' } else { $null }
    }
}
