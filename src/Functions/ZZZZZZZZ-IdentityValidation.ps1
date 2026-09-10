# Final identity validation hardening. The full ATPO is a unique processor serial;
# obvious placeholders such as "123" must never create a production baseline.
$script:SitecExpectedBomBeforeIdentityHardening = ${function:Test-SitecExpectedBom}

function Test-SitecCpuAtpo {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $v=($Value.Trim() -replace '[\s-]','').ToUpperInvariant()
    if ($v -in @('123','1234','12345','TEST','UNKNOWN','DEFAULT','N/A','NA','NONE')) { return $false }
    # Full ATPO is longer than the 3-5 character partial ATPO and is normally
    # scanner-friendly alphanumeric data. Keep the range permissive for Intel generations.
    $v -match '^[A-Z0-9]{6,32}$'
}

function Test-SitecExpectedBom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Hardware,
        [Parameter(Mandatory)]$Physical,
        [Parameter(Mandatory)]$Profile
    )
    $r=& $script:SitecExpectedBomBeforeIdentityHardening -Hardware $Hardware -Physical $Physical -Profile $Profile
    $require=$true
    if ($null -ne $Profile.Capture -and $null -ne $Profile.Capture.PSObject.Properties['RequireCpuAtpo']) { $require=[bool]$Profile.Capture.RequireCpuAtpo }
    if ($require) {
        $check=$r.Checks | Where-Object Name -eq 'CPU ATPO' | Select-Object -First 1
        $valid=Test-SitecCpuAtpo -Value ([string]$Physical.CpuAtpo)
        if ($null -ne $check) {
            $check.Expected='Valid full ATPO / Intel processor S/N'
            $check.Passed=$valid
            $check.Status=if($valid){'PASS'}else{'FAIL'}
            if (-not $valid) { $check.Actual=if([string]::IsNullOrWhiteSpace([string]$Physical.CpuAtpo)){'Missing'}else{'Invalid/placeholder: '+[string]$Physical.CpuAtpo} }
        } elseif (-not $valid) {
            $r.Checks=@($r.Checks)+(New-SitecCheck -Name 'CPU ATPO' -Expected 'Valid full ATPO / Intel processor S/N' -Actual ([string]$Physical.CpuAtpo) -Passed $false)
        }
        if (-not $valid) { $r.Status='FAIL' }
    }
    $r
}
