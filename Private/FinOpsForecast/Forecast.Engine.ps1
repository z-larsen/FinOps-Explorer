# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helpers named for the collections they process.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers that build objects or write only the private local forecast workspace; nothing in Azure changes.')]
param()

###########################################################################
# FORECAST.ENGINE.PS1
# GROWTH ESTIMATION AND FISCAL-YEAR PROJECTION
###########################################################################
# Method (all amounts pre-credit, in the billing currency):
#  1. Run rate R = month cost / days in month x 30, using run-rate charges
#     (Usage; unused-benefit charges exist only in amortized cost).
#  2. The lookback (12+ complete months, ordered by month key) gives N-1
#     adjacent comparisons g = R(m) / R(m-1) - 1. A zero or negative prior
#     run rate makes g undefined; a reviewer must acknowledge it.
#  3. A defined g is flagged when |g - median| exceeds the larger of
#     K x scaled MAD and a minimum deviation. Flagged changes need a review:
#     Retain, Exclude from growth, or Step change. A step change is a
#     one-time move to a new level, such as new reservations covering
#     usage; the baseline already sits at that level, so the jump is left
#     out of growth like an exclusion. Any other change can be reviewed by
#     hand the same way, since with few changes nothing can be flagged.
#     Actual charges are never removed from actuals.
#  4. Central growth is the median of retained g. The sensitivity range uses
#     the low and high percentiles of retained g, or the lowest and highest
#     retained g while the lookback is shorter than a Ready forecast's,
#     because percentiles of a few changes are mostly interpolation. It's
#     historical variability, not a calibrated confidence interval.
#  5. Baseline is the latest month's R unless that month is anomalous: its
#     change was flagged, undefined, or excluded or marked a step change by
#     hand. Then a separate baseline review chooses the baseline, suggesting
#     the latest month after a step change and the median of the last three
#     months otherwise.
#  6. Month j forecast = Baseline x (1 + g)^h x days(j) / 30, where h counts
#     months after the window's last month. Scheduled items add their net
#     effect to every path.
#  7. Fiscal-year totals add actuals to date, month-to-date actuals plus the
#     rest of the current month, and remaining forecast months. Low and high
#     are single growth paths, not sums of independent percentiles.
###########################################################################

function New-ForecastReviewItem {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Fingerprint,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [string]$Detail,
        [Parameter(Mandatory)][string[]]$Options,
        [string]$Suggested,
        [bool]$Required = $true,
        [Collections.IDictionary]$Reviews,
        [string]$Subject
    )
    $decision = 'Pending'; $note = ''; $value = $null; $decidedUtc = $null; $stale = $false
    if ($Reviews -and $Reviews.ContainsKey($Key)) {
        $record = $Reviews[$Key]
        if ([string]$record.fingerprint -ceq $Fingerprint -and [string]$record.decision -in $Options) {
            $decision = [string]$record.decision
            $note = [string]$record.note
            $value = $record.value
            $decidedUtc = $record.decidedUtc
        }
        else { $stale = $true }
    }
    [pscustomobject]@{
        Key = $Key; Fingerprint = $Fingerprint; Category = $Category; Title = $Title; Detail = $Detail
        Options = $Options; Suggested = $Suggested; Required = $Required; Subject = $Subject
        Decision = $decision; Note = $note; Value = $value; DecidedUtc = $decidedUtc; Stale = $stale
    }
}

function New-ForecastMissingMonth {
    param([Parameter(Mandatory)][string]$Month)
    [pscustomobject]@{
        Month = $Month; Status = 'Missing'; Days = Get-ForecastDaysInMonth -MonthKey $Month
        RunRate = $null; Purchase = 0d; Adjustment = 0d; Other = 0d; Headline = $null; Credit = 0d
        ExcludedMarketplace = 0d; ExcludedTax = 0d; ExcludedUnattributed = 0d; ExcludedBoundary = 0d; ExcludedScope = 0d
        DataThrough = $null; Provenance = @(); Approved = $false; Note = 'No data for this month.'
    }
}

function Test-ForecastMonthUsable {
    param($Row)
    return $null -ne $Row -and $Row.Status -in 'Complete', 'VerifiedZero' -and $null -ne $Row.RunRate
}

function Get-ForecastNormalizedRunRate {
    param([Parameter(Mandatory)]$Row)
    if ($null -eq $Row.RunRate) { return $null }
    # Multiply before dividing to keep as much decimal precision as possible.
    return ([decimal]$Row.RunRate * 30d) / [decimal]$Row.Days
}

function Get-ForecastFirstNeededMonth {
    # The earliest month a forecast needs: the lookback window's first month,
    # or the fiscal year's first month when the fiscal year started earlier,
    # because those months count as actuals in the fiscal-year total.
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][datetime]$AsOf)
    $end = Get-ForecastLastEligibleMonth -AsOf $AsOf -GraceDays ([int]$Settings.period.graceDays)
    $pinned = [string]$Settings.period.windowEnd
    if ($pinned -ne 'Auto' -and (Test-ForecastMonthKey -MonthKey $pinned) -and [string]::CompareOrdinal($pinned, $end) -lt 0) { $end = $pinned }
    $first = Add-ForecastMonth -MonthKey $end -Count (1 - [math]::Max(1, [int]$Settings.period.lookbackMonths))
    $fiscal = Get-ForecastFiscalYear -AsOf $AsOf -StartMonth ([int]$Settings.period.fiscalYearStartMonth) -Offset ([int]$Settings.period.fiscalYearOffset)
    if ([string]::CompareOrdinal($fiscal.FirstMonth, $first) -lt 0) { $first = $fiscal.FirstMonth }
    return $first
}

function Get-ForecastWindow {
    param([Parameter(Mandatory)]$Dataset, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][datetime]$AsOf)
    $issues = [Collections.Generic.List[object]]::new()
    $lastEligible = Get-ForecastLastEligibleMonth -AsOf $AsOf -GraceDays ([int]$Settings.period.graceDays)
    $end = $lastEligible
    if ([string]$Settings.period.windowEnd -ne 'Auto') {
        $end = [string]$Settings.period.windowEnd
        if ([string]::CompareOrdinal($end, $lastEligible) -gt 0) {
            $issues.Add((New-ForecastIssue -Code 'WIN-END' -Message "The pinned window end $end hasn't closed and finalized yet. The window ends at $lastEligible instead."))
            $end = $lastEligible
        }
    }
    $length = [int]$Settings.period.lookbackMonths
    $first = Add-ForecastMonth -MonthKey $end -Count (-1 * ($length - 1))
    $byMonth = @{}
    foreach ($row in @($Dataset.Months)) { $byMonth[[string]$row.Month] = $row }
    $rows = foreach ($month in (Get-ForecastMonthSpan -First $first -Last $end)) {
        if ($byMonth.ContainsKey($month)) { $byMonth[$month] } else { New-ForecastMissingMonth -Month $month }
    }
    [pscustomobject]@{ First = $first; Last = $end; LastEligible = $lastEligible; Pinned = ($end -ne $lastEligible); Rows = @($rows); Issues = $issues.ToArray() }
}

function Get-ForecastComparisonIdentity {
    # The review key and data fingerprint of one month-to-month change.
    param([Parameter(Mandatory)]$Comparison, [string]$ScopeKey = '')
    [pscustomobject]@{
        Key         = "comparison:${ScopeKey}:$($Comparison.ToMonth)"
        Fingerprint = Get-ForecastHash -Text ("{0}|{1}|{2}|{3}" -f $Comparison.FromMonth, $Comparison.ToMonth, (Format-ForecastDecimal $Comparison.FromRunRate), (Format-ForecastDecimal $Comparison.ToRunRate))
    }
}

function New-ForecastComparisonReview {
    # A review of a change that wasn't flagged, for when you know why the run
    # rate moved, or there are too few changes for any to be flagged. With
    # AgreementChange, it's the required review of a change between months
    # billed under different agreements.
    param([Parameter(Mandatory)]$Comparison, [string]$ScopeKey = '', [Collections.IDictionary]$Reviews, $Median, $Threshold, [switch]$AgreementChange)
    $identity = Get-ForecastComparisonIdentity -Comparison $Comparison -ScopeKey $ScopeKey
    $context = if ($null -ne $Median -and $null -ne $Threshold) { "It isn't flagged: the median change is $(Format-ForecastPercent $Median), and the flag threshold is +/- $(Format-ForecastPercent $Threshold). " } else { '' }
    if ($AgreementChange) {
        return New-ForecastReviewItem -Key $identity.Key -Fingerprint $identity.Fingerprint -Category 'AgreementChange' -Reviews $Reviews -Subject $Comparison.ToMonth `
            -Title "Change $($Comparison.FromMonth) to $($Comparison.ToMonth) spans a change of agreement: $(Format-ForecastPercent $Comparison.Change)" `
            -Detail "$($Comparison.FromMonth) is billed under $($Comparison.FromAgreements), and $($Comparison.ToMonth) under $($Comparison.ToAgreements). EA and MCA prices can differ, so part of this change may be a price change rather than growth in usage. ${context}Compare the unit prices of a few services across the two months. Retain counts the change as growth. Exclude and StepChange leave it out of growth; StepChange records that the new level is real. Until you decide, it counts as growth. Actual charges stay in actuals either way." `
            -Options @('Retain', 'Exclude', 'StepChange') -Suggested 'Retain'
    }
    New-ForecastReviewItem -Key $identity.Key -Fingerprint $identity.Fingerprint -Category 'Comparison' -Reviews $Reviews -Subject $Comparison.ToMonth `
        -Title "Change $($Comparison.FromMonth) to $($Comparison.ToMonth): $(Format-ForecastPercent $Comparison.Change), reviewed by hand" `
        -Detail "${context}Review it by hand when you know why the run rate moved, such as new reservations or savings plans covering usage, or a migration. Retain counts it as growth. Exclude and StepChange leave it out of growth; StepChange records that the new level is real. Actual charges stay in actuals either way." `
        -Options @('Retain', 'Exclude', 'StepChange') -Suggested 'Retain'
}

function Get-ForecastComparisons {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)]$Settings,
        [Collections.IDictionary]$Reviews,
        [string]$ScopeKey = ''
    )
    # Date keys define order, never the order rows arrived in.
    $ordered = Invoke-ForecastSort -Items $Rows -Comparison { param($a, $b) [string]::CompareOrdinal([string]$a.Month, [string]$b.Month) }
    $k = Get-ForecastMethodNumber -Settings $Settings -Name 'anomalyK'
    $minimumDeviation = Get-ForecastMethodNumber -Settings $Settings -Name 'anomalyMinimumDeviation'

    $comparisons = [Collections.Generic.List[object]]::new()
    for ($i = 1; $i -lt $ordered.Count; $i++) {
        $previous = $ordered[$i - 1]
        $current = $ordered[$i]
        $usable = (Test-ForecastMonthUsable $previous) -and (Test-ForecastMonthUsable $current)
        $fromRate = if (Test-ForecastMonthUsable $previous) { Get-ForecastNormalizedRunRate $previous } else { $null }
        $toRate = if (Test-ForecastMonthUsable $current) { Get-ForecastNormalizedRunRate $current } else { $null }
        $status = if (-not $usable) { 'MissingData' } elseif ($fromRate -le 0) { 'Undefined' } else { 'Defined' }
        $change = if ($status -eq 'Defined') { ($toRate / $fromRate) - 1d } else { $null }
        # Months billed under different agreements, such as EA before a move
        # to MCA and both in the month of the move, can differ in price.
        $fromAgreements = @($previous.Agreements | Where-Object { $_ } | Sort-Object -Unique)
        $toAgreements = @($current.Agreements | Where-Object { $_ } | Sort-Object -Unique)
        $spanned = @($fromAgreements + $toAgreements | Sort-Object -Unique)
        $agreementChange = $fromAgreements.Count -gt 0 -and $toAgreements.Count -gt 0 -and ($fromAgreements -join '+') -ne ($toAgreements -join '+') -and 'EA' -in $spanned -and 'MCA' -in $spanned
        $comparisons.Add([pscustomobject]@{
                Index = $i; FromMonth = [string]$previous.Month; ToMonth = [string]$current.Month
                FromRunRate = $fromRate; ToRunRate = $toRate; Change = $change; Status = $status
                Flagged = $false; Deviation = $null; Suggestion = $null; Review = $null; Retained = $false; Reason = ''
                AgreementChange = $agreementChange; FromAgreements = ($fromAgreements -join ' and '); ToAgreements = ($toAgreements -join ' and ')
            })
    }
    $reviewAgreementChange = ConvertTo-ForecastSettingSwitch -Value $Settings.method.reviewAgreementChange -Default $true

    $defined = [decimal[]]@($comparisons | Where-Object Status -EQ 'Defined' | ForEach-Object { [decimal]$_.Change })
    $median = if ($defined.Count) { Get-ForecastMedian -Values $defined } else { $null }
    $scaledMad = if ($defined.Count) { Get-ForecastScaledMad -Values $defined } else { $null }
    $threshold = if ($null -ne $scaledMad) { [math]::Max($k * $scaledMad, $minimumDeviation) } else { $null }

    for ($i = 0; $i -lt $comparisons.Count; $i++) {
        $comparison = $comparisons[$i]
        $identity = Get-ForecastComparisonIdentity -Comparison $comparison -ScopeKey $ScopeKey
        $fingerprint = $identity.Fingerprint
        $key = $identity.Key
        switch ($comparison.Status) {
            'MissingData' {
                $comparison.Reason = 'A month in this pair is missing or not final.'
            }
            'Undefined' {
                $comparison.Reason = 'The earlier month''s run rate is zero or negative, so a percentage change is undefined.'
                $comparison.Review = New-ForecastReviewItem -Key $key -Fingerprint $fingerprint -Category 'Undefined' -Reviews $Reviews -Subject $comparison.ToMonth `
                    -Title "Undefined change $($comparison.FromMonth) to $($comparison.ToMonth)" `
                    -Detail "Run rate went from $(Format-ForecastAmount $comparison.FromRunRate) to $(Format-ForecastAmount $comparison.ToRunRate). Undefined changes are left out of growth estimation; acknowledge to continue." `
                    -Options @('Exclude') -Suggested 'Exclude'
            }
            'Defined' {
                $comparison.Deviation = [decimal]$comparison.Change - $median
                if ([math]::Abs($comparison.Deviation) -gt $threshold) {
                    $comparison.Flagged = $true
                    $next = if ($i + 1 -lt $comparisons.Count) { $comparisons[$i + 1] } else { $null }
                    $persisted = $next -and $next.Status -eq 'Defined' -and [math]::Abs([decimal]$next.Change - $median) -le $threshold
                    # A move back to the trend right after a flagged move the other
                    # way undoes a one-off spike or dip; it isn't a new level.
                    $previous = if ($i -gt 0) { $comparisons[$i - 1] } else { $null }
                    $reverses = $false
                    if ($previous -and $previous.Flagged -and $previous.Status -eq 'Defined' -and [math]::Sign($previous.Deviation) -ne [math]::Sign($comparison.Deviation) -and [decimal]$previous.FromRunRate -gt 0) {
                        $twoStep = ([decimal]$comparison.ToRunRate / [decimal]$previous.FromRunRate) - 1d
                        $expected = (1d + $median) * (1d + $median) - 1d
                        $reverses = [math]::Abs($twoStep - $expected) -le $threshold
                    }
                    $comparison.Suggestion = if ($reverses) { 'Exclude' } elseif ($persisted) { 'StepChange' } else { 'Exclude' }
                    $why = if ($reverses) { "It reverses the flagged change from $($previous.FromMonth) to $($previous.ToMonth): the run rate is back near its earlier trend, which points to a one-off spike or dip rather than a new level." }
                    elseif ($persisted) { 'The new level held the following month, which suggests a step change: a one-time move to a new level, such as new reservations or savings plans covering usage.' }
                    else { 'The change didn''t persist into the next month, or it''s the latest comparison.' }
                    if ($comparison.AgreementChange) { $why += " It also spans a change of agreement ($($comparison.FromAgreements) to $($comparison.ToAgreements)), and EA and MCA prices can differ." }
                    $comparison.Review = New-ForecastReviewItem -Key $key -Fingerprint $fingerprint -Category 'Anomaly' -Reviews $Reviews -Subject $comparison.ToMonth `
                        -Title "Anomalous change $($comparison.FromMonth) to $($comparison.ToMonth): $(Format-ForecastPercent $comparison.Change)" `
                        -Detail "Median change is $(Format-ForecastPercent $median); the flag threshold is +/- $(Format-ForecastPercent $threshold). $why Retain counts it as growth. Exclude and StepChange leave it out of growth; StepChange records that the new level is real, and the baseline already reflects it. Investigate before deciding. Actual charges stay in actuals either way." `
                        -Options @('Retain', 'Exclude', 'StepChange') -Suggested $comparison.Suggestion
                }
                elseif ($comparison.AgreementChange -and $reviewAgreementChange) {
                    $comparison.Review = New-ForecastComparisonReview -Comparison $comparison -ScopeKey $ScopeKey -Reviews $Reviews -Median $median -Threshold $threshold -AgreementChange
                }
                elseif ($Reviews -and $Reviews.ContainsKey($key)) {
                    # A change reviewed by hand keeps its decision until its data changes.
                    $comparison.Review = New-ForecastComparisonReview -Comparison $comparison -ScopeKey $ScopeKey -Reviews $Reviews -Median $median -Threshold $threshold
                }
            }
        }
        $decision = if ($comparison.Review) { $comparison.Review.Decision } else { $null }
        $comparison.Retained = $comparison.Status -eq 'Defined' -and $(if ($comparison.Flagged) { $decision -eq 'Retain' } else { $decision -notin 'Exclude', 'StepChange' })
        if ($comparison.Status -eq 'Defined') {
            $comparison.Reason = if ($comparison.Flagged) {
                if ($decision -eq 'Pending') { 'Flagged; waiting for review.' }
                elseif ($decision -eq 'Exclude') { 'Flagged and excluded from growth after review.' }
                elseif ($decision -eq 'StepChange') { 'Flagged; a step change after review, so the jump is left out of growth.' }
                else { 'Flagged; retained after review.' }
            }
            elseif ($decision -eq 'Exclude') { 'Excluded from growth after review.' }
            elseif ($decision -eq 'StepChange') { 'A step change after review, so the jump is left out of growth.' }
            elseif ($decision -eq 'Pending' -and $comparison.Review.Category -eq 'AgreementChange') { 'Spans a change of agreement, whose prices can differ; waiting for review, and counted in growth until then.' }
            elseif ($decision -eq 'Pending') { 'Within the normal range; its data changed since it was reviewed, so it needs a new review.' }
            elseif ($comparison.Review -and $comparison.Review.Category -eq 'AgreementChange') { 'Spans a change of agreement; retained after review.' }
            else { 'Within the normal range.' }
        }
    }
    [pscustomobject]@{
        Items = $comparisons.ToArray(); Median = $median; ScaledMad = $scaledMad; Threshold = $threshold
        K = $k; MinimumDeviation = $minimumDeviation; Expected = [math]::Max(0, $ordered.Count - 1)
    }
}

function Test-ForecastShortHistory {
    # Shorter than a Ready forecast's lookback, so the range is lowest to
    # highest instead of interpolated percentiles.
    param([Parameter(Mandatory)]$Settings)
    return [int]$Settings.period.lookbackMonths -lt $script:ForecastReadyMonths
}

function Get-ForecastRangeLabel {
    # How the low-to-high range is chosen, such as "P25 to P75".
    param([Parameter(Mandatory)]$Settings)
    if (Test-ForecastShortHistory -Settings $Settings) { return 'lowest to highest' }
    return "P$($Settings.method.lowPercentile) to P$($Settings.method.highPercentile)"
}

function Get-ForecastGrowth {
    param([Parameter(Mandatory)]$Comparisons, [Parameter(Mandatory)]$Settings)
    $retained = [decimal[]]@($Comparisons.Items | Where-Object Retained | ForEach-Object { [decimal]$_.Change })
    $minimum = [int]$Settings.method.minimumRetained
    # Percentiles 0 and 100 are exactly the lowest and highest values.
    $short = Test-ForecastShortHistory -Settings $Settings
    $low = if ($short) { 0d } else { Read-ForecastDecimal -Value $Settings.method.lowPercentile }
    $high = if ($short) { 100d } else { Read-ForecastDecimal -Value $Settings.method.highPercentile }
    $rangeMethod = if ($short) { 'LowestToHighest' } else { 'Percentile' }
    if ($retained.Count -eq 0) {
        return [pscustomobject]@{ Sufficient = $false; Retained = 0; Minimum = $minimum; Central = $null; Low = $null; High = $null; LowPercentile = $low; HighPercentile = $high; RangeMethod = $rangeMethod }
    }
    [pscustomobject]@{
        Sufficient     = $retained.Count -ge $minimum
        Retained       = $retained.Count
        Minimum        = $minimum
        Central        = Get-ForecastMedian -Values $retained
        Low            = Get-ForecastPercentile -Values $retained -Percentile $low
        High           = Get-ForecastPercentile -Values $retained -Percentile $high
        LowPercentile  = $low
        HighPercentile = $high
        RangeMethod    = $rangeMethod
    }
}

function Get-ForecastBaseline {
    param([Parameter(Mandatory)][object[]]$Rows, [Parameter(Mandatory)]$Comparisons, [Collections.IDictionary]$Reviews, [string]$ScopeKey = '')
    $ordered = Invoke-ForecastSort -Items $Rows -Comparison { param($a, $b) [string]::CompareOrdinal([string]$a.Month, [string]$b.Month) }
    $last = $ordered[-1]
    if (-not (Test-ForecastMonthUsable $last)) {
        return [pscustomobject]@{ Value = $null; Method = 'Unavailable'; Month = $last.Month; Review = $null; Pending = $false; Detail = 'The latest month in the window has no final data.' }
    }
    $latestRate = Get-ForecastNormalizedRunRate $last
    $recent = [decimal[]]@($ordered | Select-Object -Last 3 | Where-Object { Test-ForecastMonthUsable $_ } | ForEach-Object { Get-ForecastNormalizedRunRate $_ })
    $medianRecent = if ($recent.Count) { Get-ForecastMedian -Values $recent } else { $null }
    $lastComparison = @($Comparisons.Items)[-1]
    $lastDecision = if ($lastComparison -and $lastComparison.Review) { [string]$lastComparison.Review.Decision } else { '' }
    $stepped = $lastDecision -eq 'StepChange'
    $anomalous = $lastComparison -and ($lastComparison.Flagged -or $lastComparison.Status -eq 'Undefined' -or $lastDecision -in 'Exclude', 'StepChange')
    if (-not $anomalous) {
        return [pscustomobject]@{ Value = $latestRate; Method = 'LatestMonth'; Month = $last.Month; Review = $null; Pending = $false; Detail = "Run rate of $($last.Month)." }
    }
    # A step change into the latest month makes it the new level, so it's
    # suggested instead, and an answer given before the step change is asked
    # again.
    $fingerprint = Get-ForecastHash -Text (((@($ordered | Select-Object -Last 3 | ForEach-Object { "$($_.Month)=$(Format-ForecastDecimal $_.RunRate)" })) -join '|') + $(if ($stepped) { '|StepChange' } else { '' }))
    $levels = "Latest month run rate $(Format-ForecastAmount $latestRate); median of the last three months $(Format-ForecastAmount $medianRecent)."
    $reviewDetail = if ($stepped) { "You marked the change from $($lastComparison.FromMonth) to $($lastComparison.ToMonth) as a step change, so LatestMonth is suggested: the latest month is the new level. Choose Manual, with a value and a reason, if the step happened partway through the month. $levels" }
    else { "$levels Choose LatestMonth, MedianLast3, or Manual with a value and a reason." }
    $review = New-ForecastReviewItem -Key "baseline:${ScopeKey}:$($last.Month)" -Fingerprint $fingerprint -Category 'Baseline' -Reviews $Reviews -Subject $last.Month `
        -Title "Baseline review: $($last.Month) is anomalous" `
        -Detail $reviewDetail `
        -Options @('LatestMonth', 'MedianLast3', 'Manual') -Suggested $(if ($stepped) { 'LatestMonth' } else { 'MedianLast3' })
    $value = $latestRate; $method = 'LatestMonth'; $detail = 'Pending review; the latest month is used provisionally.'
    switch ($review.Decision) {
        'LatestMonth' { $value = $latestRate; $method = 'LatestMonth'; $detail = "Reviewed: run rate of $($last.Month)." }
        'MedianLast3' { $value = $medianRecent; $method = 'MedianLast3'; $detail = 'Reviewed: median run rate of the last three months.' }
        'Manual' {
            $manual = Read-ForecastDecimal -Value $review.Value
            if ($null -eq $manual -or $manual -lt 0) { $review.Decision = 'Pending'; $detail = 'The manual baseline value is missing or invalid.' }
            else { $value = $manual; $method = 'Manual'; $detail = "Reviewed: manual baseline. $($review.Note)" }
        }
    }
    [pscustomobject]@{ Value = $value; Method = $method; Month = $last.Month; Review = $review; Pending = ($review.Decision -eq 'Pending'); Detail = $detail }
}

# -- Scheduled items -------------------------------------------------------
function Test-ForecastScheduledItems {
    param([AllowEmptyCollection()][object[]]$Items, [Collections.IDictionary]$Reviews, [string]$ScopeKey = '')
    $issues = [Collections.Generic.List[object]]::new()
    $reviewItems = [Collections.Generic.List[object]]::new()
    $ids = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
    $valid = [Collections.Generic.List[object]]::new()
    foreach ($item in @($Items)) {
        $id = [string]$item.id
        $label = if ($id) { ConvertTo-ForecastSafeText $id 64 } else { '(no ID)' }
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { $issues.Add((New-ForecastIssue -Code 'SCH-ID' -Message "Scheduled item $label needs an ID of letters, digits, dots, dashes, or underscores." -Subject $label)); continue }
        if ($ids.ContainsKey($id)) { $ids[$id]++; continue }
        $ids[$id] = 1
        $problems = @()
        if ($item.type -notin 'Purchase', 'Renewal', 'BusinessChange', 'ExternalActual') { $problems += 'type must be Purchase, Renewal, BusinessChange, or ExternalActual' }
        if (-not (Test-ForecastMonthKey -MonthKey ([string]$item.startMonth))) { $problems += 'start month must be yyyy-MM' }
        if ($item.endMonth -and -not (Test-ForecastMonthKey -MonthKey ([string]$item.endMonth))) { $problems += 'end month must be yyyy-MM' }
        elseif ($item.endMonth -and (Test-ForecastMonthKey ([string]$item.startMonth)) -and [string]::CompareOrdinal([string]$item.endMonth, [string]$item.startMonth) -lt 0) { $problems += 'end month is before the start month' }
        if ($item.recurrence -notin 'OneTime', 'Monthly', 'Annual') { $problems += 'recurrence must be OneTime, Monthly, or Annual' }
        elseif ($item.type -eq 'ExternalActual' -and $item.recurrence -ne 'OneTime') { $problems += 'an external actual is one month''s cost, so its recurrence must be OneTime' }
        if ($null -eq (Read-ForecastDecimal -Value $item.amount)) { $problems += 'amount must be a number' }
        if ($item.baselineTreatment -notin 'Additive', 'AlreadyInBaseline', 'ReplacesBaselineAmount') { $problems += 'baseline treatment must be Additive, AlreadyInBaseline, or ReplacesBaselineAmount' }
        elseif ($item.type -eq 'ExternalActual' -and $item.baselineTreatment -ne 'Additive') { $problems += 'an external actual adds to that month''s actuals, so its treatment must be Additive' }
        if ($item.baselineTreatment -eq 'ReplacesBaselineAmount' -and $null -eq (Read-ForecastDecimal -Value $item.replacedAmount)) { $problems += 'a replaced amount is required' }
        if ($problems.Count) { $issues.Add((New-ForecastIssue -Code 'SCH-INVALID' -Message "Scheduled item ${label}: $($problems -join '; ')." -Subject $label)); continue }
        $valid.Add($item)
    }
    foreach ($entry in $ids.GetEnumerator()) {
        if ($entry.Value -gt 1) { $issues.Add((New-ForecastIssue -Code 'SCH-DUPLICATE' -Message "Scheduled item ID '$(ConvertTo-ForecastSafeText $entry.Key 64)' is used $($entry.Value) times. IDs must be unique." -Subject $entry.Key)) }
    }
    # Two items with different IDs but the same schedule and amount are
    # probably the same commitment entered twice.
    $groups = @{}
    foreach ($item in $valid) {
        $signature = '{0}|{1}|{2}|{3}|{4}' -f $item.type, $item.startMonth, $item.recurrence, (Format-ForecastDecimal (Read-ForecastDecimal $item.amount)), ([string]$item.description).Trim().ToLowerInvariant()
        if (-not $groups.ContainsKey($signature)) { $groups[$signature] = [Collections.Generic.List[object]]::new() }
        $groups[$signature].Add($item)
    }
    foreach ($group in $groups.Values) {
        if ($group.Count -lt 2) { continue }
        $memberIds = @($group | ForEach-Object { [string]$_.id } | Sort-Object -CaseSensitive)
        $reviewItems.Add((New-ForecastReviewItem -Key "schedule:${ScopeKey}:$($memberIds -join '+')" -Fingerprint (Get-ForecastHash -Text ($memberIds -join '|')) -Category 'Schedule' -Reviews $Reviews `
                    -Title "Possible duplicate scheduled items: $($memberIds -join ', ')" -Detail 'These items have the same type, start month, recurrence, amount, and description. Confirm they are distinct, or remove one.' `
                    -Options @('ConfirmedDistinct') -Suggested 'ConfirmedDistinct' -Subject ($memberIds -join ', ')))
    }
    [pscustomobject]@{ Valid = $valid.ToArray(); Issues = $issues.ToArray(); Reviews = $reviewItems.ToArray() }
}

function Get-ForecastScheduleEffects {
    # Net effect of each valid scheduled item in each requested month.
    param([AllowEmptyCollection()][object[]]$Items, [Parameter(Mandatory)][string[]]$Months)
    $effects = [Collections.Generic.List[object]]::new()
    foreach ($item in @($Items)) {
        $amount = Read-ForecastDecimal -Value $item.amount
        $replaced = if ($item.baselineTreatment -eq 'ReplacesBaselineAmount') { Read-ForecastDecimal -Value $item.replacedAmount } else { 0d }
        $net = switch ($item.baselineTreatment) {
            'Additive' { $amount }
            'AlreadyInBaseline' { 0d }
            'ReplacesBaselineAmount' { $amount - $replaced }
        }
        foreach ($month in $Months) {
            if ([string]::CompareOrdinal($month, [string]$item.startMonth) -lt 0) { continue }
            if ($item.endMonth -and [string]::CompareOrdinal($month, [string]$item.endMonth) -gt 0) { continue }
            $occurs = switch ($item.recurrence) {
                'OneTime' { $month -eq [string]$item.startMonth }
                'Monthly' { $true }
                'Annual' { ((Get-ForecastMonthDifference -First ([string]$item.startMonth) -Second $month) % 12) -eq 0 }
            }
            if (-not $occurs) { continue }
            $effects.Add([pscustomobject]@{ Id = [string]$item.id; Type = [string]$item.type; Month = $month; Amount = $amount; Replaced = $replaced; Net = $net; Treatment = [string]$item.baselineTreatment; CommitmentId = ([string]$item.commitmentId).Trim().ToLowerInvariant() })
        }
    }
    return , $effects.ToArray()
}

function Test-ForecastCommitmentMatch {
    # A scheduled item may name the commitment by its full resource ID or by
    # its trailing ID (for example the reservation order GUID).
    param([string]$Scheduled, [string]$Posted)
    if (-not $Scheduled -or -not $Posted) { return $false }
    $a = $Scheduled.Trim().TrimEnd('/').ToLowerInvariant()
    $b = $Posted.Trim().TrimEnd('/').ToLowerInvariant()
    return ($a -eq $b) -or $b.EndsWith("/$a", [StringComparison]::Ordinal) -or $a.EndsWith("/$b", [StringComparison]::Ordinal)
}

function Get-ForecastRenewalReviews {
    # Up-front purchases from the last 12 complete months that would bill
    # again in a fiscal-year month still to come, if their term is one year
    # and they renew. Cost data doesn't carry the term, so each one asks,
    # and proposes an annual item from the purchase's anniversary. A
    # commitment billed more than once, refunded, or already covered by a
    # scheduled item is left out.
    param(
        [Parameter(Mandatory)]$Dataset,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)]$FiscalYear,
        [Collections.IDictionary]$Reviews,
        [string]$ScopeKey = ''
    )
    $last = [string]$Window.Last
    if (-not (Test-ForecastMonthKey -MonthKey $last)) { return , @() }
    $first = Add-ForecastMonth -MonthKey $last -Count -11
    $commitments = @{}
    foreach ($cell in @($Dataset.Cells)) {
        if (-not $cell -or $cell.Stream -ne 'Purchase' -or -not $cell.CommitmentId) { continue }
        $key = [string]$cell.CommitmentId
        if (-not $commitments.ContainsKey($key)) { $commitments[$key] = [pscustomobject]@{ Months = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); Cost = 0d; OneTime = $false; Other = $false; Refunded = $false; Payers = @{}; Pricing = '' } }
        $entry = $commitments[$key]
        if ($cell.ChargeType -eq 'Refund') { $entry.Refunded = $true; continue }
        if ($cell.ChargeType -ne 'Purchase') { continue }
        [void]$entry.Months.Add([string]$cell.Month)
        if ([string]$cell.Frequency -match '^(?i)one-?time$') { $entry.OneTime = $true } else { $entry.Other = $true }
        $entry.Cost += [decimal]$cell.Cost
        $payer = [string]$cell.SubscriptionId
        if (-not $entry.Payers.ContainsKey($payer)) { $entry.Payers[$payer] = 0d }
        $entry.Payers[$payer] += [decimal]$cell.Cost
        if (-not $entry.Pricing) { $entry.Pricing = [string]$cell.PricingModel }
    }
    $scheduledItems = @($Settings.scheduledItems | Where-Object { $_ })
    $scheduledText = (@($scheduledItems | ForEach-Object { "$($_.id) $($_.commitmentId) $($_.description)" }) -join ' ').ToLowerInvariant()
    $takenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $scheduledItems) { [void]$takenIds.Add([string]$item.id) }
    $coming = @($FiscalYear.Months | Where-Object { [string]::CompareOrdinal([string]$_, $last) -gt 0 })
    $names = if ($Dataset.SubscriptionNames) { $Dataset.SubscriptionNames } else { @{} }
    $reviewItems = [Collections.Generic.List[object]]::new()
    foreach ($entry in ($commitments.GetEnumerator() | Sort-Object { [string]$_.Key })) {
        $value = $entry.Value
        if (-not $value.OneTime -or $value.Other -or $value.Refunded -or $value.Months.Count -ne 1 -or $value.Cost -le 0) { continue }
        $purchased = @($value.Months)[0]
        if ([string]::CompareOrdinal($purchased, $first) -lt 0 -or [string]::CompareOrdinal($purchased, $last) -gt 0) { continue }
        $anniversary = Add-ForecastMonth -MonthKey $purchased -Count 12
        $due = @($coming | Where-Object { [string]::CompareOrdinal([string]$_, $anniversary) -ge 0 -and ((Get-ForecastMonthDifference -First $anniversary -Second $_) % 12) -eq 0 })
        if (-not $due.Count) { continue }
        if ($scheduledText.Contains($entry.Key) -or @($scheduledItems | Where-Object { Test-ForecastCommitmentMatch -Scheduled ([string]$_.commitmentId) -Posted $entry.Key }).Count) { continue }
        $payerId = @($value.Payers.GetEnumerator() | Sort-Object @{ Expression = { [decimal]$_.Value }; Descending = $true }, @{ Expression = { [string]$_.Key } } | Select-Object -First 1 | ForEach-Object Key)[0]
        $payerName = if ($payerId -and $names[$payerId]) { ConvertTo-ForecastSafeText ([string]$names[$payerId]) 60 } else { '' }
        $paidBy = if ($payerName) { " by $payerName" } elseif ($payerId) { " by subscription $payerId" } else { '' }
        $guid = [regex]::Match([string]$entry.Key, '[0-9a-fA-F]{8}(?=-[0-9a-fA-F]{4}-)')
        $stem = 'renewal-' + $(if ($guid.Success) { $guid.Value.ToLowerInvariant() } else { Get-ForecastHash -Text ([string]$entry.Key) -Length 8 })
        $id = $stem; $suffix = 2
        while ($takenIds.Contains($id)) { $id = "$stem-$suffix"; $suffix++ }
        [void]$takenIds.Add($id)
        $proposal = [pscustomobject]@{
            id = $id; type = 'Renewal'; description = "Possible renewal of an up-front purchase$(if ($paidBy) { ", paid$paidBy" })"
            startMonth = $anniversary; endMonth = ''; recurrence = 'Annual'
            amount = Format-ForecastDecimal $value.Cost; baselineTreatment = 'Additive'; replacedAmount = ''; commitmentId = [string]$entry.Key
        }
        $check = switch ($value.Pricing) {
            'Reservation' { 'check it under Reservations in the Azure portal, along with its renewal setting, which is on by default when a reservation is bought' }
            'SavingsPlan' { 'check it under Savings plans in the Azure portal, along with its renewal setting, which is off by default' }
            default { 'check it where it was bought, along with whether it renews automatically' }
        }
        $when = if ($due[0] -eq $anniversary) { $anniversary } else { "$anniversary, and each year after, including $($due[0])" }
        $detail = "Commitment $($entry.Key) was billed $(Format-ForecastAmount $value.Cost) once, up front, in $purchased$paidBy. If its term is one year and it renews, it bills again in $when, within $($FiscalYear.Label). Cost data doesn't show the term, so $check. Purchases aren't grown with the run rate, so a renewal is in the forecast only as a scheduled item. Press A to add the proposed item: $(Format-ForecastAmount $value.Cost) a year from $anniversary, for this commitment. Or choose NotRenewing if the term is longer, it won't renew, or something else will replace it."
        $review = New-ForecastReviewItem -Key "renewal:${ScopeKey}:$($entry.Key)" -Fingerprint (Get-ForecastHash -Text "$($entry.Key)|$purchased|$(Format-ForecastDecimal $value.Cost)") -Category 'RenewalPurchase' -Reviews $Reviews -Subject $entry.Key `
            -Title 'Possible renewal of an up-front purchase' -Detail $detail -Options @('Scheduled', 'NotRenewing')
        $review | Add-Member -NotePropertyName Proposal -NotePropertyValue $proposal
        $reviewItems.Add($review)
    }
    return , $reviewItems.ToArray()
}

# -- Projection ------------------------------------------------------------
function Invoke-ForecastProjection {
    param(
        [Parameter(Mandatory)]$Dataset,
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)]$Growth,
        [Parameter(Mandatory)]$Baseline,
        [Parameter(Mandatory)]$FiscalYear,
        [AllowEmptyCollection()][object[]]$ScheduleEffects
    )
    $byMonth = @{}
    foreach ($row in @($Dataset.Months)) { $byMonth[[string]$row.Month] = $row }
    # Purchases already billed in a month, so a scheduled item for the same
    # commitment isn't added on top of the month-to-date actuals.
    $postedCommitments = @{}
    foreach ($cell in @($Dataset.Cells)) {
        if ($cell.Stream -ne 'Purchase' -or $cell.ChargeType -ne 'Purchase' -or -not $cell.CommitmentId) { continue }
        $cellMonth = [string]$cell.Month
        if (-not $postedCommitments.ContainsKey($cellMonth)) { $postedCommitments[$cellMonth] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
        [void]$postedCommitments[$cellMonth].Add([string]$cell.CommitmentId)
    }
    $paths = [ordered]@{ Low = $Growth.Low; Central = $Growth.Central; High = $Growth.High }
    $rows = [Collections.Generic.List[object]]::new()
    # Whether each occurrence of a scheduled item counted, and why not, for
    # the item list, the report, and the check for items that change nothing.
    $outcomes = [Collections.Generic.List[object]]::new()
    $record = {
        param($Effect, [bool]$Counted, [string]$Status)
        $outcomes.Add([pscustomobject]@{
                Id = $Effect.Id; Type = $Effect.Type; Month = $Effect.Month; Amount = $Effect.Amount; Replaced = $Effect.Replaced; Net = $Effect.Net
                Treatment = $Effect.Treatment; CommitmentId = $Effect.CommitmentId; Counted = $Counted; Status = $Status
            })
    }
    foreach ($month in $FiscalYear.Months) {
        $days = Get-ForecastDaysInMonth -MonthKey $month
        $data = $byMonth[$month]
        $monthEffects = @($ScheduleEffects | Where-Object Month -EQ $month)
        # An external actual is cost already billed that the data doesn't
        # include. It adds to a month that has started, never to growth.
        $actualEffects = @($monthEffects | Where-Object Type -EQ 'ExternalActual')
        $plannedEffects = @($monthEffects | Where-Object Type -NE 'ExternalActual')
        $scheduled = 0d
        foreach ($effect in $plannedEffects) { $scheduled += [decimal]$effect.Net }
        $row = [ordered]@{
            Month = $month; Kind = 'Forecast'; Days = $days; DaysWithData = 0; Actual = 0d; AddedActual = 0d; Scheduled = 0d; ScheduledAlreadyPosted = 0d
            RunRateLow = 0d; RunRateCentral = 0d; RunRateHigh = 0d; TotalLow = 0d; TotalCentral = 0d; TotalHigh = 0d
            Horizon = $null; Note = ''
        }
        $afterWindow = [string]::CompareOrdinal($month, $Window.Last) -gt 0
        if (-not $afterWindow) {
            if (Test-ForecastMonthUsable $data) {
                $row.Kind = 'Actual'; $row.Actual = [decimal]$data.Headline; $row.DaysWithData = $days
            }
            else { $row.Kind = 'MissingActual'; $row.Note = 'No final data for this month.' }
            foreach ($effect in $plannedEffects) { & $record $effect $false 'PastMonth' }
            foreach ($effect in $actualEffects) { $row.AddedActual += [decimal]$effect.Net; & $record $effect $true 'Counted' }
            foreach ($path in 'Low', 'Central', 'High') { $row["Total$path"] = $row.Actual + $row.AddedActual }
            $rows.Add([pscustomobject]$row)
            continue
        }
        $horizon = Get-ForecastMonthDifference -First $Window.Last -Second $month
        $row.Horizon = $horizon
        $covered = 0
        if ($data -and $data.DataThrough -and $null -ne $data.Headline) {
            $start = Get-ForecastMonthStart -MonthKey $month
            $through = ConvertFrom-ForecastDate -Value $data.DataThrough
            if ($through -ge $start) { $covered = [math]::Min($days, [int][math]::Floor(($through.Date - $start).TotalDays) + 1) }
        }
        if ($data -and $data.Status -eq 'Complete' -and $null -ne $data.Headline) { $covered = $days }
        $remaining = [decimal]($days - $covered) / [decimal]$days
        if ($covered -ge $days) {
            $row.Kind = if ($data.Status -eq 'Complete') { 'Actual' } else { 'ProvisionalActual' }
            $row.Actual = [decimal]$data.Headline
            $row.DaysWithData = $days
            $row.Note = if ($row.Kind -eq 'ProvisionalActual') { 'Full month of data that isn''t final yet.' } else { 'Final month after the lookback window.' }
            foreach ($effect in $plannedEffects) { & $record $effect $false 'PastMonth' }
        }
        elseif ($covered -gt 0) {
            $row.Kind = 'PartialActual'
            $row.Actual = [decimal]$data.Headline
            $row.DaysWithData = $covered
            $row.Note = "Month-to-date actuals for $covered of $days days plus forecast for the rest."
            $posted = $postedCommitments[$month]
            $postedIds = [Collections.Generic.List[string]]::new()
            $unlinked = [Collections.Generic.List[string]]::new()
            $renewals = [Collections.Generic.List[string]]::new()
            foreach ($effect in $plannedEffects) {
                $isPosted = $false
                if ($posted -and $effect.CommitmentId) { foreach ($id in $posted) { if (Test-ForecastCommitmentMatch -Scheduled $effect.CommitmentId -Posted $id) { $isPosted = $true; break } } }
                if ($isPosted) { $scheduled -= [decimal]$effect.Net; $row.ScheduledAlreadyPosted += [decimal]$effect.Net; $postedIds.Add($effect.Id); & $record $effect $false 'AlreadyPosted'; continue }
                & $record $effect $true 'Counted'
                if ($posted -and -not $effect.CommitmentId -and $effect.Type -in 'Purchase', 'Renewal') { $unlinked.Add($effect.Id) }
                # Renewing creates a new reservation or savings plan, so the renewal bills under its own order ID.
                elseif ($posted -and $effect.Type -eq 'Renewal') { $renewals.Add($effect.Id) }
            }
            if ($postedIds.Count) { $row.Note += " Scheduled item(s) $($postedIds -join ', ') already posted this month, so they're counted in the actuals, not added again." }
            if ($unlinked.Count) { $row.Note += " Purchases have posted this month; scheduled item(s) $($unlinked -join ', ') have no commitment ID, so check they aren't already in the actuals." }
            if ($renewals.Count) { $row.Note += " Purchases have posted this month; renewal item(s) $($renewals -join ', ') may have posted under a new order ID, so check they aren't already in the actuals." }
        }
        else { foreach ($effect in $plannedEffects) { & $record $effect $true 'Counted' } }
        foreach ($effect in $actualEffects) {
            if ($row.Kind -eq 'Forecast') { & $record $effect $false 'NotStarted' }
            else { $row.AddedActual += [decimal]$effect.Net; & $record $effect $true 'Counted' }
        }
        $row.Scheduled = $scheduled
        foreach ($path in $paths.Keys) {
            $rate = $paths[$path]
            $forecast = 0d
            if ($null -ne $Baseline.Value -and $null -ne $rate -and $remaining -gt 0) {
                $forecast = [decimal]$Baseline.Value * (Get-ForecastCompound -Rate $rate -Periods $horizon) * ([decimal]$days / 30d) * $remaining
            }
            $row["RunRate$path"] = $forecast
            $row["Total$path"] = $row.Actual + $row.AddedActual + $forecast + $(if ($row.Kind -in 'Actual', 'ProvisionalActual') { 0d } else { $scheduled })
        }
        if ($row.Kind -in 'Actual', 'ProvisionalActual') { $row.Scheduled = 0d }
        $rows.Add([pscustomobject]$row)
    }
    $totals = [ordered]@{}
    foreach ($path in 'Low', 'Central', 'High') {
        $sum = 0d
        foreach ($row in $rows) { $sum += [decimal]$row."Total$path" }
        $totals[$path] = $sum
    }
    $actualToDate = 0d; $addedActual = 0d; $scheduledTotal = 0d; $remainingCentral = 0d
    foreach ($row in $rows) { $actualToDate += [decimal]$row.Actual; $addedActual += [decimal]$row.AddedActual; $scheduledTotal += [decimal]$row.Scheduled; $remainingCentral += [decimal]$row.RunRateCentral }
    [pscustomobject]@{
        Rows = $rows.ToArray()
        FiscalYear = $FiscalYear
        TotalLow = $totals.Low; TotalCentral = $totals.Central; TotalHigh = $totals.High
        ActualToDate = $actualToDate; AddedActual = $addedActual; Scheduled = $scheduledTotal; RemainingRunRateCentral = $remainingCentral
        MissingActualMonths = @($rows | Where-Object Kind -EQ 'MissingActual' | ForEach-Object Month)
        Effects = $outcomes.ToArray()
    }
}

function Get-ForecastScheduleSummary {
    # What each valid scheduled item adds to the fiscal year, and why any
    # occurrence doesn't count: its month has ended, so only actual cost
    # counts there; it already posted this month; or, for an external
    # actual, its month hasn't started. An item that adds nothing, and
    # didn't post, gets a warning, since it's most likely dated wrong.
    param([AllowEmptyCollection()][object[]]$Items, [AllowEmptyCollection()][object[]]$Effects, [Parameter(Mandatory)]$FiscalYear)
    $issues = [Collections.Generic.List[object]]::new()
    $rows = foreach ($item in @($Items | Where-Object { $_ })) {
        $id = [string]$item.id
        $mine = @($Effects | Where-Object { $_ -and [string]$_.Id -eq $id })
        $counted = @($mine | Where-Object Counted)
        $added = 0d
        foreach ($effect in $counted) { $added += [decimal]$effect.Net }
        $ended = @($mine | Where-Object Status -EQ 'PastMonth' | ForEach-Object Month)
        $posted = @($mine | Where-Object Status -EQ 'AlreadyPosted' | ForEach-Object Month)
        $notStarted = @($mine | Where-Object Status -EQ 'NotStarted' | ForEach-Object Month)
        $status = if ($counted.Count -and $counted.Count -eq $mine.Count) { 'Counted' } elseif ($counted.Count) { 'Partly counted' } elseif ($posted.Count) { 'Already posted' } else { 'No effect' }
        $reasons = @()
        if (-not $mine.Count) { $reasons += "it has no occurrence from $($FiscalYear.FirstMonth) to $($FiscalYear.LastMonth)" }
        if ($ended.Count) { $reasons += "$(Join-ForecastMonthList $ended) $(if ($ended.Count -eq 1) { 'has' } else { 'have' }) already ended, so only actual cost counts there" }
        if ($posted.Count) { $reasons += "it already posted in $(Join-ForecastMonthList $posted), so it's in the actuals" }
        if ($notStarted.Count) { $reasons += "$(Join-ForecastMonthList $notStarted) $(if ($notStarted.Count -eq 1) { 'hasn''t' } else { 'haven''t' }) started, and an external actual adds only to a month that has" }
        if ($status -eq 'No effect') {
            $hint = if ($ended.Count -and [string]$item.type -ne 'ExternalActual') { ' To add cost that''s already billed but isn''t in the data, make it an external actual.' } else { '' }
            $issues.Add((New-ForecastIssue -Code 'SCH-NOEFFECT' -Severity 'Warn' -Message "Scheduled item $(ConvertTo-ForecastSafeText $id 64) changes nothing in $($FiscalYear.Label): $($reasons -join '; ').$hint" -Subject $id))
        }
        [pscustomobject]@{
            Id = $id; Type = [string]$item.type; Description = ConvertTo-ForecastSafeText ([string]$item.description) 200; Recurrence = [string]$item.recurrence
            StartMonth = [string]$item.startMonth; EndMonth = [string]$item.endMonth; Amount = Read-ForecastDecimal -Value $item.amount; Treatment = [string]$item.baselineTreatment
            CommitmentId = [string]$item.commitmentId; Months = @($counted | ForEach-Object Month); Added = $added; Status = $status
            Note = if ($reasons.Count) { ($reasons -join '; ').Substring(0, 1).ToUpperInvariant() + ($reasons -join '; ').Substring(1) + '.' } else { '' }
        }
    }
    [pscustomobject]@{ Items = @($rows); Issues = $issues.ToArray() }
}

function Invoke-ForecastModel {
    # Runs the complete method. The result carries every review item it
    # raised; the readiness gate decides whether the forecast can be used.
    param(
        [Parameter(Mandatory)]$Dataset,
        [Parameter(Mandatory)]$Settings,
        [Collections.IDictionary]$Reviews,
        [Parameter(Mandatory)][datetime]$AsOf
    )
    $scopeKey = Get-ForecastScopeKey -Settings $Settings
    $window = Get-ForecastWindow -Dataset $Dataset -Settings $Settings -AsOf $AsOf
    $comparisons = Get-ForecastComparisons -Rows $window.Rows -Settings $Settings -Reviews $Reviews -ScopeKey $scopeKey
    $growth = Get-ForecastGrowth -Comparisons $comparisons -Settings $Settings
    $baseline = Get-ForecastBaseline -Rows $window.Rows -Comparisons $comparisons -Reviews $Reviews -ScopeKey $scopeKey
    $fiscalYear = Get-ForecastFiscalYear -AsOf $AsOf -StartMonth ([int]$Settings.period.fiscalYearStartMonth) -Offset ([int]$Settings.period.fiscalYearOffset)
    $schedule = Test-ForecastScheduledItems -Items @($Settings.scheduledItems) -Reviews $Reviews -ScopeKey $scopeKey
    $effects = Get-ForecastScheduleEffects -Items $schedule.Valid -Months $fiscalYear.Months
    $projection = Invoke-ForecastProjection -Dataset $Dataset -Window $window -Growth $growth -Baseline $baseline -FiscalYear $fiscalYear -ScheduleEffects $effects
    $scheduleSummary = Get-ForecastScheduleSummary -Items $schedule.Valid -Effects $projection.Effects -FiscalYear $fiscalYear
    $renewals = Get-ForecastRenewalReviews -Dataset $Dataset -Settings $Settings -Window $window -FiscalYear $fiscalYear -Reviews $Reviews -ScopeKey $scopeKey

    $reviewItems = [Collections.Generic.List[object]]::new()
    foreach ($comparison in $comparisons.Items) { if ($comparison.Review) { $reviewItems.Add($comparison.Review) } }
    if ($baseline.Review) { $reviewItems.Add($baseline.Review) }
    foreach ($item in $schedule.Reviews) { $reviewItems.Add($item) }
    foreach ($item in @($renewals)) { $reviewItems.Add($item) }

    [pscustomobject]@{
        AsOf = (ConvertFrom-ForecastDate -Value $AsOf); ScopeKey = $scopeKey; Currency = $Dataset.Currency
        Window = $window; Comparisons = $comparisons; Growth = $growth; Baseline = $baseline
        FiscalYear = $fiscalYear; Schedule = $schedule; ScheduleEffects = $projection.Effects; ScheduleSummary = $scheduleSummary.Items; Projection = $projection
        Reviews = $reviewItems.ToArray()
        Issues = @($window.Issues) + @($schedule.Issues) + @($scheduleSummary.Issues)
    }
}
