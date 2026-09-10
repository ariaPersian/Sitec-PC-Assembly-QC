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
