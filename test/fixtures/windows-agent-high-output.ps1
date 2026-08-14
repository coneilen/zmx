[CmdletBinding()]
param([int]$Lines = 256)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

for ($index = 0; $index -lt $Lines; $index++) {
    "ZMX_HIGH_OUTPUT_{0:D4}" -f $index
}
