#requires -Version 5.1
# Native PowerShell progress renders inside Windows Terminal and console hosts.
function Get-ProgressTextWidth {
    # Classic Windows PowerShell adds borders/indentation and caps pane width.
    # Leave a generous margin and use the narrower visible/buffer width.
    $width=80
    try {
        $visible=$Host.UI.RawUI.WindowSize.Width
        $buffer=$Host.UI.RawUI.BufferSize.Width
        if ($visible -gt 0 -and $buffer -gt 0) { $width=[Math]::Min($visible,$buffer) }
    } catch { }
    return [Math]::Max(1,[Math]::Min(60,$width-20))
}
function Limit-ProgressText([string]$Text,[int]$Width,[switch]$KeepEnd) {
    # Measure conservatively in display cells, not UTF-16 character count.
    # Treat non-ASCII elements as wide, and never split a surrogate/combining pair.
    $Text=[regex]::Replace($Text,'[\s\p{Cc}]+',' ').Trim()
    $elements=[Collections.Generic.List[string]]::new()
    $cells=[Collections.Generic.List[int]]::new()
    $iterator=[Globalization.StringInfo]::GetTextElementEnumerator($Text)
    $total=0
    while ($iterator.MoveNext()) {
        $element=$iterator.GetTextElement()
        $size=0
        foreach ($character in $element.ToCharArray()) {
            if ([int]$character -le 127) { $size++ } else { $size+=2 }
        }
        $elements.Add($element); $cells.Add($size); $total+=$size
    }
    if ($total -le $Width) { return $Text }
    if ($Width -le 3) { return ('.'*[Math]::Max(1,$Width)) }
    $remaining=$Width-3; $result=''
    if ($KeepEnd) {
        for ($i=$elements.Count-1; $i -ge 0; $i--) {
            if ($cells[$i] -gt $remaining) { break }
            $result=$elements[$i]+$result; $remaining-=$cells[$i]
        }
        return '...'+$result
    }
    for ($i=0; $i -lt $elements.Count; $i++) {
        if ($cells[$i] -gt $remaining) { break }
        $result+=$elements[$i]; $remaining-=$cells[$i]
    }
    return $result+'...'
}
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
        $status="$Percent%  |  $Count  |  已用时 $elapsed"
    } else {
        $status="处理中  |  已用时 $elapsed"
    }
    if (-not $Detail) { $Detail='请稍候…' }
    $width=Get-ProgressTextWidth
    $activity=Limit-ProgressText "Codex 修复 · $Stage" $width
    $status=Limit-ProgressText $status $width
    $operation=Limit-ProgressText $Detail $width -KeepEnd
    Write-Progress -Id 1 -Activity $activity -Status $status -CurrentOperation $operation -PercentComplete $Percent
}
function Stop-RepairProgress($Progress,[bool]$Success) {
    if ($null -eq $Progress) { return }
    if ($Success) { Update-RepairProgress $Progress '修复完成' 100 '全部文件已校验并应用' }
    $Progress.Clock.Stop()
    Write-Progress -Id 1 -Activity 'Codex 运行环境修复' -Completed
}
