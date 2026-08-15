[CmdletBinding()]
param(
    [int]$Lines = 256,
    [int]$ChunkSize = 32,
    [int]$HoldSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Lines -lt 1 -or $ChunkSize -lt 1) {
    throw "Lines and ChunkSize must be positive"
}

"ZMX_HIGH_OUTPUT_BEGIN"
for ($index = 0; $index -lt $Lines; $index++) {
    if ($index % $ChunkSize -eq 0) {
        "ZMX_HIGH_OUTPUT_CHUNK_{0:D2}_BEGIN" -f ([int]($index / $ChunkSize))
    }
    "ZMX_HIGH_OUTPUT_{0:D4}" -f $index
    if (($index + 1) % $ChunkSize -eq 0 -or $index -eq $Lines - 1) {
        "ZMX_HIGH_OUTPUT_CHUNK_{0:D2}_END" -f ([int]($index / $ChunkSize))
    }
}
"ZMX_HIGH_OUTPUT_END"
if ($HoldSeconds -gt 0) {
    Start-Sleep -Seconds $HoldSeconds
}
