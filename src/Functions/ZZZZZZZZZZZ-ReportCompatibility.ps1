# Report compatibility guard. Optional hardware/benchmark fields can legitimately be
# absent in older manifests and runtime fixtures; missing optional fields must render
# as blank rather than abort certificate generation under StrictMode.

function ConvertTo-SitecCompactTable {
    param([Parameter(Mandatory)]$Rows,[Parameter(Mandatory)]$Columns)
    $r=@($Rows)
    if ($r.Count -eq 0) { return '' }

    function GetCellValue($Column,$Row) {
        try { return (& $Column.Getter $Row) } catch { return '' }
    }

    $active=@()
    foreach($c in $Columns) {
        $has=$false
        foreach($x in $r) {
            $value=GetCellValue $c $x
            if (Test-SitecPrintableValue $value) { $has=$true;break }
        }
        if ($has) { $active += $c }
    }
    if ($active.Count -eq 0) { return '' }

    $h='<table><thead><tr>'+(($active|ForEach-Object{'<th>'+(ConvertTo-SitecHtml $_.Label)+'</th>'})-join '')+'</tr></thead><tbody>'
    foreach($x in $r) {
        $h+='<tr>'
        foreach($c in $active) {
            $value=GetCellValue $c $x
            $h+='<td>'+(ConvertTo-SitecHtml $value)+'</td>'
        }
        $h+='</tr>'
    }
    $h+'</tbody></table>'
}

$script:SitecTwoPageReportCore = ${function:New-SitecCustomerReport}

function Add-SitecOptionalProperty {
    param($Object,[Parameter(Mandatory)][string]$Name,$Value)
    if ($null -eq $Object) { return }
    if (-not $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function New-SitecCustomerReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run,[Parameter(Mandatory)][string]$RunPath,[Parameter(Mandatory)]$Context)

    # Normalize old/partial result objects before the strict two-page renderer sees them.
    $stress=$null
    if ($Run.Benchmark -and $Run.Benchmark.PSObject.Properties['Stress']) { $stress=$Run.Benchmark.Stress }
    if ($null -eq $stress -and $Run.Benchmark -and $Run.Benchmark.PSObject.Properties['BurnIn']) { $stress=$Run.Benchmark.BurnIn }
    if ($stress) {
        Add-SitecOptionalProperty $stress 'TimedOut' $false
        Add-SitecOptionalProperty $stress 'ActualSeconds' $(if($stress.PSObject.Properties['DurationSeconds']){$stress.DurationSeconds}else{0})
        Add-SitecOptionalProperty $stress 'Error' ''
        if ($stress.PSObject.Properties['CpuStress'] -and $stress.CpuStress) {
            Add-SitecOptionalProperty $stress.CpuStress 'DutyPercent' 0
        }
        if ($stress.PSObject.Properties['MemoryVerification'] -and $stress.MemoryVerification) {
            Add-SitecOptionalProperty $stress.MemoryVerification 'AllocatedMB' 0
        }
    }
    if ($Run.Security) {
        Add-SitecOptionalProperty $Run.Security 'HardwareIdentitySha256' ''
        Add-SitecOptionalProperty $Run.Security 'Sha256' ''
        Add-SitecOptionalProperty $Run.Security 'Signed' $false
    }

    & $script:SitecTwoPageReportCore -Run $Run -RunPath $RunPath -Context $Context
}
