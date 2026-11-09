[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(0.001, 1000.0)]
    [double]$DataRateGbps,

    [Parameter(Mandatory = $true)]
    [ValidateRange(8, 16384)]
    [int]$BusWidthBits,

    [string]$GpuModel,

    [string]$MemoryType,

    [string]$Source
)

$ErrorActionPreference = "Stop"
$theoreticalPeakGBs = ($DataRateGbps * $BusWidthBits) / 8.0

[pscustomobject][ordered]@{
    CalculationVersion = "1.0"
    Formula = "data rate Gb/s per pin * bus width bits / 8"
    GpuModel = if ([string]::IsNullOrWhiteSpace($GpuModel)) { $null } else { $GpuModel.Trim() }
    MemoryType = if ([string]::IsNullOrWhiteSpace($MemoryType)) { $null } else { $MemoryType.Trim() }
    DataRateGbpsPerPin = $DataRateGbps
    BusWidthBits = $BusWidthBits
    TheoreticalPeakGBs = [Math]::Round($theoreticalPeakGBs, 6)
    ResultKind = "theoretical-source-specification"
    Source = if ([string]::IsNullOrWhiteSpace($Source)) { $null } else { $Source.Trim() }
    Limits = @(
        "Requires a source-backed per-pin data-rate basis; do not substitute an arbitrary GPU memory MHz display."
        "Theoretical peak is not observed or achieved application bandwidth."
    )
} | ConvertTo-Json -Depth 4
