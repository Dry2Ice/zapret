param(
    [Parameter(Mandatory=$true)][string]$PolicyJson,
    [Parameter(Mandatory=$true)][string]$PolicyCache
)
$ErrorActionPreference='Stop'

function Pick-FromPool {
    param($Value, [int]$Seed)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Array]) {
        if ($Value.Count -eq 0) { return $null }
        return $Value[[Math]::Abs($Seed) % $Value.Count]
    }
    if ($Value -is [string] -and $Value.Contains(',')) {
        $arr = $Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($arr.Count -eq 0) { return $null }
        return $arr[[Math]::Abs($Seed) % $arr.Count]
    }
    return $Value
}

$profiles = Get-Content -Raw -Path $PolicyJson | ConvertFrom-Json
$cache = if (Test-Path $PolicyCache) { Get-Content -Raw -Path $PolicyCache | ConvertFrom-Json } else { [pscustomobject]@{ version=2; classes=@{}; session_seed=0 } }
if (-not $cache.classes) { $cache | Add-Member -NotePropertyName classes -NotePropertyValue @{} -Force }
if (-not $cache.session_seed -or [int]$cache.session_seed -le 0) { $cache.session_seed = Get-Random -Minimum 10000 -Maximum 2147483000 }

$ladder=@('none','fake(2)','fake(6)','multisplit')
$threshold=[int]$profiles.failureThreshold
$globalMaxRetries = if($profiles.guardrails.maxRetries){[int]$profiles.guardrails.maxRetries}else{12}
$globalMaxOverhead = if($profiles.guardrails.maxByteOverhead){[int]$profiles.guardrails.maxByteOverhead}else{4096}
$globalQoEFloor = if($profiles.guardrails.qoeFloor){[double]$profiles.guardrails.qoeFloor}else{0.85}
$parts=@()

foreach($prop in $profiles.classes.PSObject.Properties){
    $name=$prop.Name; $c=$prop.Value
    if(-not ($cache.classes.PSObject.Properties.Name -contains $name)){
        $cache.classes | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{ fail_count=0; success_level=''; active_strategy=''; degradation_score=1.0 })
    }
    $state=$cache.classes.$name
    $state.active_strategy = if($state.active_strategy){$state.active_strategy}else{ if($c.strategy){$c.strategy}else{'none'} }

    # Guardrails + rollback
    $curRepeats = [int](Pick-FromPool -Value $(if($c.repeatsPool){$c.repeatsPool}else{ if($c.repeats){$c.repeats}else{6}}) -Seed ($cache.session_seed + $name.GetHashCode()))
    $estimatedOverhead = $curRepeats * 350
    if([int]$state.fail_count -ge $threshold -or $estimatedOverhead -gt $globalMaxOverhead -or $curRepeats -gt $globalMaxRetries -or [double]$state.degradation_score -lt $globalQoEFloor){
        $idx=[Math]::Max(0,$ladder.IndexOf([string]$state.active_strategy))
        if($idx -gt 0){ $state.active_strategy=$ladder[$idx-1] }
        $state.fail_count=0
    }

    $parts += $c.filters
    $seed = $cache.session_seed + $name.GetHashCode()

    switch([string]$state.active_strategy){
        'none' { }
        'fake(2)' { $parts += '--dpi-desync=fake'; $parts += '--dpi-desync-repeats=2' }
        'fake(6)' { $parts += '--dpi-desync=fake'; $parts += '--dpi-desync-repeats=6' }
        'multisplit' {
            $parts += '--dpi-desync=multisplit'
            $splitPos = Pick-FromPool -Value $(if($c.splitPosPool){$c.splitPosPool}else{ if($c.splitPos){$c.splitPos}else{1}}) -Seed $seed
            $seqovl = Pick-FromPool -Value $(if($c.splitSeqovlPool){$c.splitSeqovlPool}else{ if($c.splitSeqovl){$c.splitSeqovl}else{568}}) -Seed ($seed+7)
            $parts += '--dpi-desync-split-pos=' + $splitPos
            $parts += '--dpi-desync-split-seqovl=' + $seqovl
            if($c.splitPattern){$parts += '--dpi-desync-split-seqovl-pattern="' + $c.splitPattern + '"'}
            # TCP fragmentation jitter: add alternate segmentation points when provided
            if($c.fragmentJitterPool){
                $j = Pick-FromPool -Value $c.fragmentJitterPool -Seed ($seed+11)
                if($j){ $parts += '--dpi-desync-split-pos=' + $j }
            }
        }
    }

    # session/host deterministic fake payload selection
    $fakeQuic = Pick-FromPool -Value $c.fakeQuicPool -Seed ($seed+17); if(-not $fakeQuic){$fakeQuic=$c.fakeQuic}
    $fakeUnknownUdp = Pick-FromPool -Value $c.fakeUnknownUdpPool -Seed ($seed+19); if(-not $fakeUnknownUdp){$fakeUnknownUdp=$c.fakeUnknownUdp}

    # UDP/QUIC probabilistic fake injection with rate cap
    $injectChance = if($c.probabilisticFakeRate){[int]$c.probabilisticFakeRate}else{100}
    $roll = [Math]::Abs(($seed*1103515245 + 12345) % 100)
    $allowFake = $roll -lt $injectChance

    if($allowFake -and $fakeQuic -and [string]$state.active_strategy -ne 'none'){ $parts += '--dpi-desync-fake-quic="' + $fakeQuic + '"' }
    if($allowFake -and $c.fakeDiscord -and [string]$state.active_strategy -ne 'none'){ $parts += '--dpi-desync-fake-discord="' + $c.fakeDiscord + '"' }
    if($allowFake -and $c.fakeStun -and [string]$state.active_strategy -ne 'none'){ $parts += '--dpi-desync-fake-stun="' + $c.fakeStun + '"' }
    if($allowFake -and $fakeUnknownUdp -and [string]$state.active_strategy -ne 'none'){ $parts += '--dpi-desync-fake-unknown-udp="' + $fakeUnknownUdp + '"' }

    # Adaptive TTL with path viability guardrail
    if($c.ttlAdaptive -and $c.ttlViable -and [string]$state.active_strategy -ne 'none'){
        $ttlMin = if($c.ttlMin){[int]$c.ttlMin}else{2}
        $ttlMax = if($c.ttlMax){[int]$c.ttlMax}else{5}
        if($ttlMax -lt $ttlMin){$ttlMax=$ttlMin}
        $ttl = $ttlMin + ([Math]::Abs($seed) % (($ttlMax-$ttlMin)+1))
        $parts += '--dpi-desync-autottl=' + $ttl
    }

    if($c.anyProtocol -and [string]$state.active_strategy -ne 'none'){ $parts += '--dpi-desync-any-protocol=' + $c.anyProtocol }
    if($c.cutoff -and [string]$state.active_strategy -ne 'none'){ $parts += '--dpi-desync-cutoff=' + $c.cutoff }
    $parts += '--new'
    $state.success_level = $state.active_strategy
}

$json = $cache | ConvertTo-Json -Depth 10
Set-Content -Path $PolicyCache -Value $json -Encoding UTF8
if($parts.Count -gt 0 -and $parts[-1] -eq '--new'){ $parts = $parts[0..($parts.Count-2)] }
[Console]::Out.WriteLine(($parts -join ' '))
