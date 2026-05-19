function Get-StringHash {
    param([string]$Value)
    if (-not $Value) { return 0 }
    return [Math]::Abs($Value.GetHashCode())
}

function Get-FeatureBucket {
    param([string]$Value,[int]$Buckets=4)
    if (-not $Value) { return 0 }
    return (Get-StringHash -Value $Value) % $Buckets
}

function Get-StrategyFeatures {
    param(
        [string]$ConfigName,
        [string]$TargetName,
        [bool]$IsUrl,
        [string]$Url
    )

    $host = $null
    $port = 0
    $protocol = if ($IsUrl) { 'tcp+t' } else { 'icmp' }
    $sniAlpnClass = if ($IsUrl) { 'https-web' } else { 'raw-ip' }
    if ($Url) {
        try {
            $uri = [System.Uri]$Url
            $host = $uri.Host
            $port = if ($uri.Port -gt 0) { $uri.Port } else { 443 }
            $protocol = $uri.Scheme
            if ($host -match 'youtube|googlevideo|ytimg') { $sniAlpnClass = 'streaming-http2' }
            elseif ($host -match 'discord|gateway') { $sniAlpnClass = 'voip-websocket' }
        } catch {}
    }

    $appType = 'web'
    if ($TargetName -match 'YouTube') { $appType = 'streaming' }
    elseif ($TargetName -match 'Discord') { $appType = 'voip' }
    elseif ($TargetName -match 'Game|Steam') { $appType = 'game' }

    return [PSCustomObject]@{
        config = $ConfigName
        port_protocol = "$protocol/$port"
        sni_alpn_class = $sniAlpnClass
        asn_prefix_bucket = "asn-bucket-$(Get-FeatureBucket -Value $host -Buckets 8)"
        app_type = $appType
    }
}

function Get-MultiObjectiveScore {
    param(
        [double]$SuccessRate,
        [double]$LatencyMs,
        [double]$PacketLoss,
        [double]$CpuOverhead,
        [double]$Alpha = 0.003,
        [double]$Beta = 0.5,
        [double]$Gamma = 0.02
    )
    return $SuccessRate - ($Alpha * $LatencyMs) - ($Beta * $PacketLoss) - ($Gamma * $CpuOverhead)
}

function Get-SuccessiveHalvingPlan {
    param(
        [array]$Candidates,
        [int]$TopK = 5
    )
    if (-not $Candidates) { return @() }
    $short = $Candidates | Sort-Object quick_score -Descending
    $k = [Math]::Min($TopK, [Math]::Max(1, [Math]::Ceiling($short.Count / 2)))
    return $short | Select-Object -First $k
}

function Select-BanditStrategy {
    param([array]$Candidates,[string]$Method='thompson')
    if (-not $Candidates -or $Candidates.Count -eq 0) { return $null }
    if ($Method -eq 'ucb') {
        $total = [Math]::Max(1, ($Candidates | Measure-Object -Property pulls -Sum).Sum)
        $ranked = $Candidates | ForEach-Object {
            $pulls = [Math]::Max(1, [double]$_.pulls)
            $mean = [double]$_.success_rate
            $ucb = $mean + [Math]::Sqrt((2.0 * [Math]::Log($total + 1)) / $pulls)
            $_ | Add-Member -NotePropertyName bandit_score -NotePropertyValue $ucb -PassThru
        }
        return $ranked | Sort-Object bandit_score -Descending | Select-Object -First 1
    }

    $sampled = $Candidates | ForEach-Object {
        $a = 1 + [Math]::Round([double]$_.wins)
        $b = 1 + [Math]::Round([double]$_.losses)
        $theta = (Get-Random -Minimum 0.0 -Maximum 1.0) * ($a / ($a + $b))
        $_ | Add-Member -NotePropertyName bandit_score -NotePropertyValue $theta -PassThru
    }
    return $sampled | Sort-Object bandit_score -Descending | Select-Object -First 1
}

Export-ModuleMember -Function Get-StrategyFeatures,Get-MultiObjectiveScore,Get-SuccessiveHalvingPlan,Select-BanditStrategy
