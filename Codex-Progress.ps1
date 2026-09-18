#requires -Version 5.1
# Native PowerShell progress renders inside Windows Terminal and console hosts.
function Start-RepairProgress {
    $progress=[pscustomobject]@{Clock=[Diagnostics.Stopwatch]::StartNew()}
    Write-Host ''
    Write-Host '  Codex 运行环境修复' -ForegroundColor Cyan
    Update-RepairProgress $progress '准备复制' -1 '正在统计文件，请稍候'
    return $progress
}
function Update-RepairProgress($Progress,[string]$Stage,[int]$Percent=-1,[string]$Detail='',[string]$Count='') {
    if ($null -eq $Progress) { return }
    $elapsed=$Progress.Clock.Elapsed.ToString('hh\:mm\:ss')
    if ($Percent -ge 0) {
        $Percent=[Math]::Max(0,[Math]::Min(100,$Percent))
        $filled=[int][Math]::Floor($Percent/5.0)
        $bar=('█'*$filled)+('░'*(20-$filled))
        $status="[$bar] $Percent%  |  $Count  |  已用时 $elapsed"
    } else {
        $status="处理中  |  已用时 $elapsed"
    }
    if (-not $Detail) { $Detail='请稍候…' }
    Write-Progress -Id 1 -Activity "Codex 修复 · $Stage" -Status $status -CurrentOperation $Detail -PercentComplete $Percent
}
function Stop-RepairProgress($Progress,[bool]$Success) {
    if ($null -eq $Progress) { return }
    if ($Success) { Update-RepairProgress $Progress '修复完成' 100 '全部文件已校验并应用' }
    $Progress.Clock.Stop()
    Write-Progress -Id 1 -Activity 'Codex 运行环境修复' -Completed
}
