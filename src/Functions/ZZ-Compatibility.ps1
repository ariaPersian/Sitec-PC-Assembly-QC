# Windows PowerShell 5.1 compatibility overrides.
# Keep these functions narrow and covered by tests; they intentionally load
# after the core function files because Sitec.QC.psm1 imports by filename.

function New-SitecObjectTableSection {
    param(
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][AllowEmptyCollection()]$Rows,
        [Parameter(Mandatory)]$Columns
    )
    if ($null -eq $Rows) { return '' }
    $rowsArray=@($Rows | Where-Object { $null -ne $_ })
    if ($rowsArray.Count -eq 0) { return '' }

    $active=@()
    foreach ($column in $Columns) {
        $has=$false
        foreach ($row in $rowsArray) {
            $value=''
            try { $value=& $column.Getter $row } catch [System.Management.Automation.PropertyNotFoundException] { $value='' }
            if (Test-SitecReportValue $value) { $has=$true;break }
        }
        if ($has) { $active += $column }
    }
    if ($active.Count -eq 0) { return '' }

    $head='<tr>'+(($active | ForEach-Object { '<th>'+(ConvertTo-SitecHtml $_.Label)+'</th>' }) -join '')+'</tr>'
    $body=''
    foreach ($row in $rowsArray) {
        $cells=''
        foreach ($column in $active) {
            $value=''
            try { $value=& $column.Getter $row } catch [System.Management.Automation.PropertyNotFoundException] { $value='' }
            $cells += '<td>'+(ConvertTo-SitecHtml $value)+'</td>'
        }
        $body += '<tr>'+$cells+'</tr>'
    }
    '<section><h2>'+(ConvertTo-SitecHtml $Title)+'</h2><table><thead>'+$head+'</thead><tbody>'+$body+'</tbody></table></section>'
}
