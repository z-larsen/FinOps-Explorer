# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers create synthetic fixtures in TestDrive only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helpers are named for the collections they build.')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot 'Forecast.TestHelpers.ps1')
    $script:AsOf = [datetime]::SpecifyKind([datetime]'2026-11-07T12:00:00', [DateTimeKind]::Utc)
    $script:Window = Get-TestMonthKeys -Last '2026-10'

    function New-RateSeries {
        # Converts 30-day run rates into monthly costs so normalization recovers the rates exactly.
        param([decimal[]]$Rates, [string[]]$Months = $script:Window)
        $values = [ordered]@{}
        for ($i = 0; $i -lt $Months.Count; $i++) {
            $days = [DateTime]::DaysInMonth([int]$Months[$i].Substring(0, 4), [int]$Months[$i].Substring(5, 2))
            $values[$Months[$i]] = $Rates[$i] * [decimal]$days / 30d
        }
        return $values
    }

    function Invoke-TestModel {
        param($Dataset, $Settings, $Reviews = @{})
        InModuleScope FinOpsForecast -Parameters @{ Dataset = $Dataset; Settings = $Settings; Reviews = $Reviews; AsOf = $script:AsOf } {
            Invoke-ForecastModel -Dataset $Dataset -Settings $Settings -Reviews $Reviews -AsOf $AsOf
        }
    }

    function New-ReviewRecord {
        param($Item, [string]$Decision, [string]$Value)
        @{ $Item.Key = [pscustomobject]@{ decision = $Decision; fingerprint = $Item.Fingerprint; note = 'synthetic review'; value = $Value } }
    }
}

Describe 'Forecast engine' {
    Context 'Comparisons' {
        It 'Accounts for 11 comparisons over 12 months, starting after the first month' {
            $rates = [decimal[]](1000, 1020, 1040, 1061, 1082, 1104, 1126, 1149, 1172, 1195, 1219, 1243)
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $rates)) -Settings (New-TestSettings)
            $model.Comparisons.Items.Count | Should -Be 11
            $model.Comparisons.Expected | Should -Be 11
            $model.Comparisons.Items[0].FromMonth | Should -Be '2025-11'
            $model.Comparisons.Items[0].ToMonth | Should -Be '2025-12'
            @($model.Comparisons.Items | Where-Object Status -EQ 'Defined').Count | Should -Be 11
        }

        It 'Asks for a review of each change between months on different agreements, and counts it until decided' {
            $rates = [decimal[]](1000, 1020, 1040, 1061, 1082, 1104, 1126, 1149, 1172, 1195, 1219, 1243)
            $dataset = New-TestDataset -Values (New-RateSeries $rates)
            # EA until June, both in the month of the move, then MCA.
            foreach ($row in $dataset.Months) {
                $agreements = if ([string]::CompareOrdinal($row.Month, '2026-07') -lt 0) { @('EA') } elseif ($row.Month -eq '2026-07') { @('EA', 'MCA') } else { @('MCA') }
                $row | Add-Member -NotePropertyName Agreements -NotePropertyValue $agreements
            }
            $settings = New-TestSettings
            $model = Invoke-TestModel -Dataset $dataset -Settings $settings
            (@($model.Comparisons.Items | Where-Object AgreementChange | ForEach-Object { "$($_.FromMonth) to $($_.ToMonth)" }) -join ', ') | Should -Be '2026-06 to 2026-07, 2026-07 to 2026-08'
            $reviews = @($model.Reviews | Where-Object Category -EQ 'AgreementChange')
            $reviews.Count | Should -Be 2
            foreach ($review in $reviews) {
                $review.Required | Should -BeTrue
                $review.Decision | Should -Be 'Pending'
                $review.Detail | Should -Match 'EA and MCA prices can differ'
            }
            @($model.Comparisons.Items | Where-Object { $_.AgreementChange -and $_.Retained }).Count | Should -Be 2 -Because 'a pending review leaves the change in growth, so the numbers move only after a decision'

            $excluded = Invoke-TestModel -Dataset $dataset -Settings $settings -Reviews (New-ReviewRecord $reviews[0] 'Exclude')
            @($excluded.Comparisons.Items | Where-Object ToMonth -EQ '2026-07')[0].Retained | Should -BeFalse
            $excluded.Growth.Retained | Should -Be 10

            $settings.method.reviewAgreementChange = $false
            $off = Invoke-TestModel -Dataset $dataset -Settings $settings
            @($off.Reviews | Where-Object Category -EQ 'AgreementChange').Count | Should -Be 0
            $off.Projection.TotalCentral | Should -Be $model.Projection.TotalCentral
        }

        It 'Orders months by date key, not by the order rows arrive in' {
            $rates = [decimal[]](1000, 1100, 1050, 1200, 1180, 1250, 1300, 1280, 1350, 1400, 1390, 1450)
            $ordered = New-TestDataset -Values (New-RateSeries $rates)
            $shuffled = New-TestDataset -Values (New-RateSeries $rates)
            $shuffled.Months = @($shuffled.Months | Sort-Object { $_.Month.GetHashCode() } -Descending)
            $first = Invoke-TestModel -Dataset $ordered -Settings (New-TestSettings)
            $second = Invoke-TestModel -Dataset $shuffled -Settings (New-TestSettings)
            ($second.Comparisons.Items | ForEach-Object { "$($_.ToMonth)=$($_.Change)" }) -join ';' | Should -Be (($first.Comparisons.Items | ForEach-Object { "$($_.ToMonth)=$($_.Change)" }) -join ';')
            $second.Projection.TotalCentral | Should -Be $first.Projection.TotalCentral
        }

        It 'Normalizes month length so equal daily spend shows zero growth' {
            $values = [ordered]@{}
            foreach ($month in $script:Window) { $values[$month] = 100d * [DateTime]::DaysInMonth([int]$month.Substring(0, 4), [int]$month.Substring(5, 2)) }
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values $values) -Settings (New-TestSettings)
            @($model.Comparisons.Items | Where-Object { $_.Change -ne 0 }).Count | Should -Be 0
            $model.Growth.Central | Should -Be 0
            $model.Baseline.Value | Should -Be 3000
        }

        It 'Marks a change from a zero month as undefined and requires a review' {
            $rates = [decimal[]](1000, 1000, 0, 1000, 1010, 1020, 1030, 1040, 1050, 1060, 1070, 1080)
            $dataset = New-TestDataset -Values (New-RateSeries $rates)
            $model = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings)
            $undefined = @($model.Comparisons.Items | Where-Object Status -EQ 'Undefined')
            $undefined.Count | Should -Be 1
            $undefined[0].ToMonth | Should -Be '2026-02'
            $undefined[0].Review.Decision | Should -Be 'Pending'
            $undefined[0].Retained | Should -BeFalse

            $reviewed = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings) -Reviews (New-ReviewRecord $undefined[0].Review 'Exclude')
            @($reviewed.Comparisons.Items | Where-Object Status -EQ 'Undefined')[0].Review.Decision | Should -Be 'Exclude'
        }

        It 'Flags a sustained jump, suggests a step change, and leaves it out of growth unless retained' {
            $rates = [decimal[]](1000, 1010, 1020, 1030, 1040, 1600, 1616, 1632, 1648, 1664, 1680, 1696)
            $dataset = New-TestDataset -Values (New-RateSeries $rates)
            $model = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings)
            $flagged = @($model.Comparisons.Items | Where-Object Flagged)
            $flagged.Count | Should -Be 1
            $flagged[0].ToMonth | Should -Be '2026-04'
            $flagged[0].Suggestion | Should -Be 'StepChange'
            $flagged[0].Retained | Should -BeFalse

            # A step change is a one-time move to a new level that the baseline already reflects.
            $stepped = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings) -Reviews (New-ReviewRecord $flagged[0].Review 'StepChange')
            @($stepped.Comparisons.Items | Where-Object Flagged)[0].Retained | Should -BeFalse
            @($stepped.Comparisons.Items | Where-Object Flagged)[0].Reason | Should -Match 'left out of growth'
            $stepped.Growth.Retained | Should -Be 10
            $kept = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings) -Reviews (New-ReviewRecord $flagged[0].Review 'Retain')
            @($kept.Comparisons.Items | Where-Object Flagged)[0].Retained | Should -BeTrue
            $kept.Growth.Retained | Should -Be 11
        }

        It 'Uses the lowest to highest change while the lookback is under 12 months, and P25 to P75 from 12' {
            $comparisons = [pscustomobject]@{ Items = @(0.01, 0.04, 0.02 | ForEach-Object { [pscustomobject]@{ Retained = $true; Change = [decimal]$_ } }) }
            $short = New-TestSettings
            $short.period.lookbackMonths = 4
            InModuleScope FinOpsForecast -Parameters @{ Comparisons = $comparisons; Short = $short; Full = (New-TestSettings) } {
                $growth = Get-ForecastGrowth -Comparisons $Comparisons -Settings $Short
                $growth.RangeMethod | Should -Be 'LowestToHighest'
                $growth.Central | Should -Be 0.02
                @($growth.Low, $growth.High) | Should -Be @(0.01, 0.04)
                # Linear interpolation between ranks, like Excel PERCENTILE.INC.
                $growth = Get-ForecastGrowth -Comparisons $Comparisons -Settings $Full
                $growth.RangeMethod | Should -Be 'Percentile'
                @($growth.Low, $growth.High) | Should -Be @(0.015, 0.03)
            }
        }

        It 'Lets a change that isn''t flagged be reviewed by hand, even with only two changes' {
            # Run rates 1000, 500, and 510: two changes can't be flagged, but the drop is new commitments covering usage.
            $settings = New-TestSettings
            $settings.period.lookbackMonths = 3
            $settings.method.minimumRetained = 1
            $dataset = New-TestDataset -Values (New-RateSeries -Rates ([decimal[]](1000, 500, 510)) -Months (Get-TestMonthKeys -Last '2026-10' -Count 3))
            $model = Invoke-TestModel -Dataset $dataset -Settings $settings
            @($model.Comparisons.Items | Where-Object Flagged).Count | Should -Be 0
            $model.Growth.Central | Should -Be (-0.24)
            $drop = InModuleScope FinOpsForecast -Parameters @{ Change = $model.Comparisons.Items[0]; ScopeKey = $model.ScopeKey } { New-ForecastComparisonReview -Comparison $Change -ScopeKey $ScopeKey }
            $reviews = New-ReviewRecord $drop 'StepChange'
            $stepped = Invoke-TestModel -Dataset $dataset -Settings $settings -Reviews $reviews
            $stepped.Comparisons.Items[0].Retained | Should -BeFalse
            $stepped.Comparisons.Items[0].Reason | Should -Match 'left out of growth'
            $stepped.Growth.Central | Should -Be 0.02
            @($stepped.Reviews | Where-Object { $_.Category -eq 'Comparison' -and $_.Decision -eq 'StepChange' }).Count | Should -Be 1
            $stepped.Baseline.Review | Should -BeNullOrEmpty
            $disclosure = InModuleScope FinOpsForecast -Parameters @{ Model = $stepped; Dataset = $dataset; Settings = $settings; AsOf = $script:AsOf } {
                $readiness = Test-ForecastReadiness -Dataset $Dataset -Model $Model -Settings $Settings -AsOf $AsOf
                (Get-ForecastDisclosure -Model $Model -Dataset $Dataset -Settings $Settings -Readiness $readiness) -join "`n"
            }
            $disclosure | Should -Match '0 flagged, 1 reviewed by hand\.'
            $disclosure | Should -Match '2026-08 to 2026-09: Defined, change -50\.0%, decision StepChange, retained False'

            # Excluding the latest change by hand also asks for the baseline.
            $latest = InModuleScope FinOpsForecast -Parameters @{ Change = $model.Comparisons.Items[1]; ScopeKey = $model.ScopeKey } { New-ForecastComparisonReview -Comparison $Change -ScopeKey $ScopeKey }
            $reviews += New-ReviewRecord $latest 'Exclude'
            $excluded = Invoke-TestModel -Dataset $dataset -Settings $settings -Reviews $reviews
            $excluded.Comparisons.Items[1].Retained | Should -BeFalse
            $excluded.Baseline.Review.Suggested | Should -Be 'MedianLast3'
            $excluded.Baseline.Pending | Should -BeTrue
        }

        It 'Suggests excluding a one-month spike and keeps the month in actuals' {
            $rates = [decimal[]](1000, 1010, 1020, 1030, 3000, 1040, 1050, 1060, 1070, 1080, 1090, 1100)
            $dataset = New-TestDataset -Values (New-RateSeries $rates)
            $model = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings)
            $spikeIn = @($model.Comparisons.Items | Where-Object ToMonth -EQ '2026-03')[0]
            $spikeIn.Flagged | Should -BeTrue
            $spikeIn.Suggestion | Should -Be 'Exclude'
            # The drop back holds the following month, but it undoes the spike,
            # so it isn't suggested as a step change.
            $spikeOut = @($model.Comparisons.Items | Where-Object ToMonth -EQ '2026-04')[0]
            $spikeOut.Flagged | Should -BeTrue
            $spikeOut.Suggestion | Should -Be 'Exclude'
            $spikeOut.Review.Detail | Should -Match 'reverses the flagged change from 2026-02 to 2026-03'
            ($model.Window.Rows | Where-Object Month -EQ '2026-03').Headline | Should -BeGreaterThan 2900
        }

        It 'Still suggests a step change when a drop after a spike settles at a new level' {
            $rates = [decimal[]](1000, 1010, 1020, 1030, 3000, 600, 606, 612, 618, 624, 630, 636)
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $rates)) -Settings (New-TestSettings)
            @($model.Comparisons.Items | Where-Object ToMonth -EQ '2026-04')[0].Suggestion | Should -Be 'StepChange'
        }

        It 'Reopens a review when the underlying data changes' {
            $rates = [decimal[]](1000, 1010, 1020, 1030, 3000, 1040, 1050, 1060, 1070, 1080, 1090, 1100)
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $rates)) -Settings (New-TestSettings)
            $item = @($model.Comparisons.Items | Where-Object ToMonth -EQ '2026-03')[0].Review
            $corrected = $rates.Clone(); $corrected[4] = 3100
            $after = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $corrected)) -Settings (New-TestSettings) -Reviews (New-ReviewRecord $item 'Exclude')
            $reopened = @($after.Comparisons.Items | Where-Object ToMonth -EQ '2026-03')[0].Review
            $reopened.Decision | Should -Be 'Pending'
            $reopened.Stale | Should -BeTrue
        }

        It 'Reports missing months as comparisons that couldn''t be computed' {
            $values = New-RateSeries ([decimal[]](1000, 1010, 1020, 1030, 1040, 1050, 1060, 1070, 1080, 1090, 1100, 1110))
            $values['2026-05'] = $null
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values $values) -Settings (New-TestSettings)
            @($model.Comparisons.Items | Where-Object Status -EQ 'MissingData').Count | Should -Be 2
        }
    }

    Context 'Baseline' {
        BeforeAll {
            $script:SpikeRates = [decimal[]](1000, 1010, 1020, 1030, 1040, 1050, 1060, 1070, 1080, 1090, 1100, 2500)
        }

        It 'Requires a separate review when the latest month is anomalous' {
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $script:SpikeRates)) -Settings (New-TestSettings)
            $model.Baseline.Review | Should -Not -BeNullOrEmpty
            $model.Baseline.Pending | Should -BeTrue
            $model.Baseline.Review.Category | Should -Be 'Baseline'
        }

        It 'Applies the <Decision> baseline decision' -ForEach @(
            @{ Decision = 'LatestMonth'; Expected = 2500 }
            @{ Decision = 'MedianLast3'; Expected = 1100 }
            @{ Decision = 'Manual'; Expected = 1234.5 }
        ) {
            $dataset = New-TestDataset -Values (New-RateSeries $script:SpikeRates)
            $first = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings)
            $value = if ($Decision -eq 'Manual') { '1234.5' } else { $null }
            $model = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings) -Reviews (New-ReviewRecord $first.Baseline.Review $Decision $value)
            $model.Baseline.Pending | Should -BeFalse
            # The synthetic rate-to-cost conversion divides by 30, so compare at eight decimals.
            [decimal]::Round($model.Baseline.Value, 8) | Should -Be ([decimal]$Expected)
        }

        It 'Suggests the latest month after a step change into it, and asks again if the baseline was answered first' {
            $rates = [decimal[]](@(1..11 | ForEach-Object { 1000 }) + 500)
            $dataset = New-TestDataset -Values (New-RateSeries $rates)
            $model = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings)
            $model.Baseline.Review.Suggested | Should -Be 'MedianLast3'
            # Exceptions lists the baseline review before the change it depends on.
            $reviews = New-ReviewRecord $model.Baseline.Review 'MedianLast3'
            $reviews += New-ReviewRecord @($model.Comparisons.Items)[-1].Review 'StepChange'
            $stepped = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings) -Reviews $reviews
            $stepped.Baseline.Review.Suggested | Should -Be 'LatestMonth'
            $stepped.Baseline.Review.Stale | Should -BeTrue
            $stepped.Baseline.Pending | Should -BeTrue
            $reviews[$stepped.Baseline.Review.Key] = [pscustomobject]@{ decision = 'LatestMonth'; fingerprint = $stepped.Baseline.Review.Fingerprint; note = 'synthetic review'; value = $null }
            $answered = Invoke-TestModel -Dataset $dataset -Settings (New-TestSettings) -Reviews $reviews
            $answered.Baseline.Pending | Should -BeFalse
            [decimal]::Round($answered.Baseline.Value, 8) | Should -Be 500
        }
    }

    Context 'Projection and fiscal-year aggregation' {
        It 'Combines actuals, month-to-date, and forecast into consistent low, central, and high paths' {
            $rates = [decimal[]](1000, 1020, 1040, 1061, 1082, 1104, 1126, 1149, 1172, 1195, 1219, 1243)
            $dataset = New-TestDataset -Values (New-RateSeries $rates)
            $dataset.Months += [pscustomobject]@{
                Month = '2026-11'; Status = 'Provisional'; Days = 30; RunRate = 160d; Purchase = 0d; Adjustment = 0d; Other = 0d; Headline = 160d; Credit = 0d
                ExcludedMarketplace = 0d; ExcludedTax = 0d; ExcludedUnattributed = 0d; ExcludedBoundary = 0d; ExcludedScope = 0d
                DataThrough = [datetime]'2026-11-04'; Provenance = @(); Approved = $true; Note = ''
            }
            $settings = New-TestSettings -StartMonth 7
            $model = Invoke-TestModel -Dataset $dataset -Settings $settings
            $projection = $model.Projection
            $projection.FiscalYear.Label | Should -Be 'FY2027'
            @($projection.Rows | Where-Object Kind -EQ 'Actual').Month -join ',' | Should -Be '2026-07,2026-08,2026-09,2026-10'
            $november = @($projection.Rows | Where-Object Month -EQ '2026-11')[0]
            $november.Kind | Should -Be 'PartialActual'
            $november.DaysWithData | Should -Be 4
            $november.Actual | Should -Be 160
            @($projection.Rows | Where-Object Kind -EQ 'Forecast').Count | Should -Be 7
            $projection.TotalLow | Should -BeLessOrEqual $projection.TotalCentral
            $projection.TotalCentral | Should -BeLessOrEqual $projection.TotalHigh
            $sum = 0d; foreach ($row in $projection.Rows) { $sum += $row.TotalCentral }
            $projection.TotalCentral | Should -Be $sum
        }

        It 'Computes exact totals for a flat history' {
            $rates = [decimal[]]@(1..12 | ForEach-Object { 3000 })
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $rates)) -Settings (New-TestSettings -StartMonth 1)
            $model.Growth.Central | Should -Be 0
            # Jan-Oct 2026 actuals (100 a day) plus Nov and Dec forecast (100 a day).
            $model.Projection.TotalCentral | Should -Be (100d * 365)
            $model.Projection.TotalLow | Should -Be $model.Projection.TotalHigh
        }

        It 'Applies scheduled items by baseline treatment and recurrence' {
            $rates = [decimal[]]@(1..12 | ForEach-Object { 3000 })
            $settings = New-TestSettings -StartMonth 1
            $settings.scheduledItems = @(
                [pscustomobject]@{ id = 'ri-renewal'; type = 'Renewal'; description = 'synthetic renewal'; startMonth = '2026-12'; endMonth = ''; recurrence = 'OneTime'; amount = '5000'; baselineTreatment = 'Additive'; replacedAmount = '' }
                [pscustomobject]@{ id = 'in-baseline'; type = 'Purchase'; description = 'already billed monthly'; startMonth = '2026-11'; endMonth = ''; recurrence = 'Monthly'; amount = '700'; baselineTreatment = 'AlreadyInBaseline'; replacedAmount = '' }
                [pscustomobject]@{ id = 'swap'; type = 'BusinessChange'; description = 'replace workload'; startMonth = '2026-11'; endMonth = '2026-12'; recurrence = 'Monthly'; amount = '400'; baselineTreatment = 'ReplacesBaselineAmount'; replacedAmount = '150' }
            )
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries $rates)) -Settings $settings
            $model.Schedule.Issues.Count | Should -Be 0
            $model.Projection.Scheduled | Should -Be (5000 + 0 + 250 + 250)
            $model.Projection.TotalCentral | Should -Be ((100d * 365) + 5500)
        }

        It 'Doesn''t add a scheduled purchase that already posted in the month-to-date actuals' {
            $rates = [decimal[]]@(1..12 | ForEach-Object { 3000 })
            $dataset = New-TestDataset -Values (New-RateSeries $rates)
            $dataset.Months += [pscustomobject]@{
                Month = '2026-11'; Status = 'Provisional'; Days = 30; RunRate = 400d; Purchase = 500d; Adjustment = 0d; Other = 0d; Headline = 900d; Credit = 0d
                ExcludedMarketplace = 0d; ExcludedTax = 0d; ExcludedUnattributed = 0d; ExcludedBoundary = 0d; ExcludedScope = 0d
                DataThrough = [datetime]'2026-11-04'; Provenance = @(); Approved = $true; Note = ''
            }
            $dataset.Cells = @([pscustomobject]@{ Month = '2026-11'; Stream = 'Purchase'; ChargeType = 'Purchase'; CommitmentId = '/providers/microsoft.capacity/reservationorders/ri-1'; Cost = 500d })
            $settings = New-TestSettings -StartMonth 1
            $settings.scheduledItems = @(
                [pscustomobject]@{ id = 'ri-monthly'; type = 'Purchase'; description = 'synthetic monthly RI'; startMonth = '2026-11'; endMonth = ''; recurrence = 'Monthly'; amount = '500'; baselineTreatment = 'Additive'; replacedAmount = ''; commitmentId = 'RI-1' }
                [pscustomobject]@{ id = 'unlinked'; type = 'Purchase'; description = 'no commitment'; startMonth = '2026-11'; endMonth = ''; recurrence = 'OneTime'; amount = '50'; baselineTreatment = 'Additive'; replacedAmount = '' }
            )
            $model = Invoke-TestModel -Dataset $dataset -Settings $settings
            $november = @($model.Projection.Rows | Where-Object Month -EQ '2026-11')[0]
            $december = @($model.Projection.Rows | Where-Object Month -EQ '2026-12')[0]
            $november.Kind | Should -Be 'PartialActual'
            $november.Scheduled | Should -Be 50
            $november.ScheduledAlreadyPosted | Should -Be 500
            $november.Note | Should -Match 'ri-monthly already posted'
            $november.Note | Should -Match 'unlinked have no commitment ID'
            $december.Scheduled | Should -Be 500
            # 100 a day: 900 posted, 26 remaining days forecast, plus the unlinked item.
            [decimal]::Round($november.TotalCentral, 6) | Should -Be 3550
        }

        It 'Keeps a scheduled purchase when only a refund for that commitment has posted' {
            $dataset = New-TestDataset -Values (New-RateSeries ([decimal[]]@(1..12 | ForEach-Object { 3000 })))
            $month = (New-TestDataset -Values ([ordered]@{ '2026-11' = 400 })).Months[0]
            $month.Status = 'Provisional'; $month.DataThrough = [datetime]'2026-11-04'
            $month.Purchase = -20d; $month.Headline = 380d
            $dataset.Months += $month
            $dataset.Cells = @([pscustomobject]@{ Month = '2026-11'; Stream = 'Purchase'; ChargeType = 'Refund'; CommitmentId = 'ri-synthetic'; Cost = -20d })
            $settings = New-TestSettings
            $settings.scheduledItems = @([pscustomobject]@{
                    id = 'scheduled-ri'; type = 'Purchase'; description = 'Synthetic monthly commitment'
                    startMonth = '2026-11'; endMonth = ''; recurrence = 'Monthly'; amount = '500'
                    baselineTreatment = 'Additive'; replacedAmount = ''; commitmentId = 'ri-synthetic'
                })
            $model = Invoke-TestModel -Dataset $dataset -Settings $settings
            $november = $model.Projection.Rows | Where-Object Month -EQ '2026-11'
            $november.Actual | Should -Be 380
            $november.Scheduled | Should -Be 500
            $november.ScheduledAlreadyPosted | Should -Be 0
            [decimal]::Round($november.TotalCentral, 6) | Should -Be 3480
            ($model.Projection.Rows | Where-Object Month -EQ '2026-12').Scheduled | Should -Be 500
        }

        It 'Rejects duplicate scheduled item IDs and flags near-duplicate schedules' {
            $settings = New-TestSettings
            $item = @{ type = 'Purchase'; description = 'Synthetic RI'; startMonth = '2026-12'; endMonth = ''; recurrence = 'OneTime'; amount = '100'; baselineTreatment = 'Additive'; replacedAmount = '' }
            $settings.scheduledItems = @(
                [pscustomobject](@{ id = 'dup' } + $item)
                [pscustomobject](@{ id = 'DUP' } + $item)
                [pscustomobject](@{ id = 'copy-a' } + $item)
                [pscustomobject](@{ id = 'copy-b' } + $item)
            )
            $model = Invoke-TestModel -Dataset (New-TestDataset -Values (New-RateSeries ([decimal[]]@(1..12 | ForEach-Object { 3000 })))) -Settings $settings
            @($model.Schedule.Issues | Where-Object Code -EQ 'SCH-DUPLICATE').Count | Should -Be 1
            @($model.Reviews | Where-Object Category -EQ 'Schedule').Count | Should -Be 1
        }

        It 'Counts a scheduled item only in months that haven''t ended, and warns when it changes nothing' {
            $dataset = New-TestDataset -Values (New-RateSeries ([decimal[]]@(1..12 | ForEach-Object { 3000 })))
            $settings = New-TestSettings -StartMonth 1
            $item = @{ description = 'synthetic'; endMonth = ''; baselineTreatment = 'Additive'; replacedAmount = ''; commitmentId = '' }
            $settings.scheduledItems = @(
                [pscustomobject](@{ id = 'misdated'; type = 'BusinessChange'; startMonth = '2026-08'; recurrence = 'OneTime'; amount = '100' } + $item)
                [pscustomobject](@{ id = 'next-year'; type = 'Purchase'; startMonth = '2027-03'; recurrence = 'OneTime'; amount = '100' } + $item)
                [pscustomobject](@{ id = 'monthly'; type = 'Purchase'; startMonth = '2026-09'; recurrence = 'Monthly'; amount = '10' } + $item)
            )
            $model = Invoke-TestModel -Dataset $dataset -Settings $settings
            $model.Projection.Scheduled | Should -Be 20 -Because 'only November and December are still to come'
            (@($model.ScheduleSummary) | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ', ' | Should -Be 'misdated=No effect, next-year=No effect, monthly=Partly counted'
            (@($model.ScheduleEffects | Where-Object { $_.Id -eq 'monthly' -and -not $_.Counted }) | ForEach-Object { "$($_.Month) $($_.Status)" }) -join ', ' | Should -Be '2026-09 PastMonth, 2026-10 PastMonth'
            $warnings = @($model.Issues | Where-Object Code -EQ 'SCH-NOEFFECT')
            $warnings.Severity | Should -Be @('Warn', 'Warn')
            $warnings[0].Message | Should -Be 'Scheduled item misdated changes nothing in FY2026: 2026-08 has already ended, so only actual cost counts there. To add cost that''s already billed but isn''t in the data, make it an external actual.'
            $warnings[1].Message | Should -Be 'Scheduled item next-year changes nothing in FY2026: it has no occurrence from 2026-01 to 2026-12.'
            $keys = InModuleScope FinOpsForecast -Parameters @{ Dataset = $dataset; Model = $model; Settings = $settings; AsOf = $script:AsOf } {
                @((Test-ForecastReadiness -Dataset $Dataset -Model $Model -Settings $Settings -AsOf $AsOf).Checks | Where-Object Id -EQ 'KEYS')[0]
            }
            $keys.Status | Should -Be 'Warn' -Because 'the forecast is still right without the item'
            $keys.Detail | Should -Match '^Scheduled item misdated changes nothing'
        }

        It 'Adds an external actual to its month''s actuals, never to growth' {
            $dataset = New-TestDataset -Values (New-RateSeries ([decimal[]](1000, 1020, 1040, 1061, 1082, 1104, 1126, 1149, 1172, 1195, 1219, 1243)))
            $settings = New-TestSettings -StartMonth 1
            $before = Invoke-TestModel -Dataset $dataset -Settings $settings
            $item = @{ type = 'ExternalActual'; endMonth = ''; recurrence = 'OneTime'; baselineTreatment = 'Additive'; replacedAmount = ''; commitmentId = '' }
            $settings.scheduledItems = @(
                [pscustomobject](@{ id = 'ea-july'; description = 'EA charges before the move'; startMonth = '2026-07'; amount = '500' } + $item)
                [pscustomobject](@{ id = 'too-soon'; description = 'Not billed yet'; startMonth = '2026-12'; amount = '70' } + $item)
            )
            $model = Invoke-TestModel -Dataset $dataset -Settings $settings
            $july = @($model.Projection.Rows | Where-Object Month -EQ '2026-07')[0]
            $july.AddedActual | Should -Be 500
            $july.TotalCentral | Should -Be ($july.Actual + 500)
            $model.Projection.AddedActual | Should -Be 500
            $model.Projection.ActualToDate | Should -Be $before.Projection.ActualToDate
            $model.Projection.Scheduled | Should -Be 0
            foreach ($path in 'TotalLow', 'TotalCentral', 'TotalHigh') { $model.Projection.$path | Should -Be ($before.Projection.$path + 500) -Because $path }
            $model.Growth.Central | Should -Be $before.Growth.Central
            $model.Baseline.Value | Should -Be $before.Baseline.Value
            @($model.Issues | Where-Object Code -EQ 'SCH-NOEFFECT').Message | Should -Be 'Scheduled item too-soon changes nothing in FY2026: 2026-12 hasn''t started, and an external actual adds only to a month that has.'
            $settings.scheduledItems = @([pscustomobject](@{ id = 'every-month'; description = 'synthetic'; startMonth = '2026-07'; amount = '500' } + $item))
            $settings.scheduledItems[0].recurrence = 'Monthly'
            $settings.scheduledItems[0].baselineTreatment = 'AlreadyInBaseline'
            @((Invoke-TestModel -Dataset $dataset -Settings $settings).Schedule.Issues | Where-Object Code -EQ 'SCH-INVALID').Message |
                Should -Be 'Scheduled item every-month: an external actual is one month''s cost, so its recurrence must be OneTime; an external actual adds to that month''s actuals, so its treatment must be Additive.'
        }

        It 'Proposes an annual renewal for an up-front purchase that would bill again within the fiscal year' {
            $dataset = New-TestDataset -Values (New-RateSeries ([decimal[]]@(1..12 | ForEach-Object { 3000 })))
            $dataset.SubscriptionNames = @{ 'sub-synth-1' = 'sub-synth-one' }
            $cell = { param($Month, $Commitment, $Cost, $Frequency = 'OneTime', $ChargeType = 'Purchase') [pscustomobject]@{ Month = $Month; Stream = 'Purchase'; ChargeType = $ChargeType; CommitmentId = $Commitment; Frequency = $Frequency; PricingModel = 'Reservation'; SubscriptionId = 'sub-synth-1'; Cost = [decimal]$Cost } }
            $dataset.Cells = @(
                & $cell '2025-12' 'ri-upfront' 1200
                # None of these would bill again in FY2026: a later anniversary, a refund, a monthly charge, a second charge, a purchase before the window, and one already scheduled.
                & $cell '2026-02' 'ri-later' 900
                & $cell '2025-11' 'ri-refunded' 400; & $cell '2026-01' 'ri-refunded' -400 'OneTime' 'Refund'
                & $cell '2025-12' 'ri-monthly' 50 'Recurring'
                & $cell '2025-11' 'ri-twice' 80; & $cell '2025-12' 'ri-twice' 80
                & $cell '2025-10' 'ri-old' 60
                & $cell '2025-12' 'ri-scheduled' 300
            )
            $settings = New-TestSettings -StartMonth 1
            $settings.scheduledItems = @([pscustomobject]@{ id = 'covered'; type = 'Renewal'; description = 'synthetic'; startMonth = '2026-12'; endMonth = ''; recurrence = 'Annual'; amount = '300'; baselineTreatment = 'Additive'; replacedAmount = ''; commitmentId = 'ri-scheduled' })
            $model = Invoke-TestModel -Dataset $dataset -Settings $settings
            $reviews = @($model.Reviews | Where-Object Category -EQ 'RenewalPurchase')
            $reviews.Count | Should -Be 1
            $reviews[0].Required | Should -BeTrue
            $reviews[0].Decision | Should -Be 'Pending'
            @($reviews[0].Options) -join ',' | Should -Be 'Scheduled,NotRenewing'
            $reviews[0].Detail | Should -Match '^Commitment ri-upfront was billed 1,200\.00 once, up front, in 2025-12 by sub-synth-one\. If its term is one year and it renews, it bills again in 2026-12, within FY2026\. Cost data doesn''t show the term, so check it under Reservations in the Azure portal'
            $proposal = $reviews[0].Proposal
            $proposal.id | Should -Match '^renewal-[0-9a-f]{8}$'
            "$($proposal.type) $($proposal.recurrence) $($proposal.startMonth) $($proposal.amount) $($proposal.baselineTreatment) $($proposal.commitmentId) [$($proposal.endMonth)]" | Should -Be 'Renewal Annual 2026-12 1200 Additive ri-upfront []'
            $proposal.description | Should -Be 'Possible renewal of an up-front purchase, paid by sub-synth-one'
            $model.Projection.Scheduled | Should -Be 300 -Because 'a pending proposal changes nothing'
            $settings.scheduledItems = @($settings.scheduledItems) + $proposal
            $added = Invoke-TestModel -Dataset $dataset -Settings $settings
            @($added.Reviews | Where-Object Category -EQ 'RenewalPurchase').Count | Should -Be 0
            @($added.Projection.Rows | Where-Object Month -EQ '2026-12')[0].Scheduled | Should -Be 1500
            # Forecasting next year, the first anniversary comes before it and the second falls in it.
            $settings.scheduledItems = @($settings.scheduledItems[0])
            $settings.period.fiscalYearOffset = 1
            $next = @((Invoke-TestModel -Dataset $dataset -Settings $settings).Reviews | Where-Object Category -EQ 'RenewalPurchase')
            ($next.Subject | Sort-Object) -join ', ' | Should -Be 'ri-later, ri-upfront' -Because 'the purchase from February 2026 would bill again in February 2027'
            $upfront = @($next | Where-Object Subject -EQ 'ri-upfront')[0]
            $upfront.Detail | Should -Match 'it bills again in 2026-12, and each year after, including 2027-12, within FY2027\.'
            $upfront.Proposal.startMonth | Should -Be '2026-12'
        }

        It 'Notes a renewal that may have posted under a new order ID this month' {
            $dataset = New-TestDataset -Values (New-RateSeries ([decimal[]]@(1..12 | ForEach-Object { 3000 })))
            $month = (New-TestDataset -Values ([ordered]@{ '2026-11' = 900 })).Months[0]
            $month.Status = 'Provisional'; $month.DataThrough = [datetime]'2026-11-04'
            $dataset.Months += $month
            $dataset.Cells = @([pscustomobject]@{ Month = '2026-11'; Stream = 'Purchase'; ChargeType = 'Purchase'; CommitmentId = 'ri-new-order'; Cost = 500d })
            $settings = New-TestSettings -StartMonth 1
            $settings.scheduledItems = @([pscustomobject]@{ id = 'renewal-synth'; type = 'Renewal'; description = 'synthetic'; startMonth = '2026-11'; endMonth = ''; recurrence = 'Annual'; amount = '500'; baselineTreatment = 'Additive'; replacedAmount = ''; commitmentId = 'ri-old-order' })
            $november = @((Invoke-TestModel -Dataset $dataset -Settings $settings).Projection.Rows | Where-Object Month -EQ '2026-11')[0]
            $november.Scheduled | Should -Be 500
            $november.Note | Should -Match 'renewal item\(s\) renewal-synth may have posted under a new order ID, so check they aren''t already in the actuals\.'
        }
    }

    Context 'Backtest' {
        It 'Backtests every cutoff with a full window and a later month' {
            $months = Get-TestMonthKeys -Last '2026-10' -Count 18
            $rates = [decimal[]]@(for ($i = 0; $i -lt 18; $i++) { 1000 + (20 * $i) })
            $dataset = New-TestDataset -Values (New-RateSeries -Rates $rates -Months $months)
            $backtest = InModuleScope FinOpsForecast -Parameters @{ Dataset = $dataset; Settings = (New-TestSettings) } { Invoke-ForecastBacktest -Dataset $Dataset -Settings $Settings -LastMonth '2026-10' }
            $backtest.Status | Should -Be 'Completed'
            $backtest.Cutoffs.Count | Should -Be 6
            $backtest.Results[0].Cutoff | Should -Be '2026-04'
            $backtest.MeanAbsoluteErrorRatio | Should -BeLessThan 0.05
        }

        It 'Reports insufficient history with only twelve months' {
            $dataset = New-TestDataset -Values (New-RateSeries ([decimal[]]@(1..12 | ForEach-Object { 3000 })))
            $backtest = InModuleScope FinOpsForecast -Parameters @{ Dataset = $dataset; Settings = (New-TestSettings) } { Invoke-ForecastBacktest -Dataset $Dataset -Settings $Settings -LastMonth '2026-10' }
            $backtest.Status | Should -Be 'InsufficientHistory'
        }
    }
}
