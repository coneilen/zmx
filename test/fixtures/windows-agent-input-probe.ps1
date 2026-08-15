[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$inputStream = [Console]::OpenStandardInput()
$writer = [Console]::Out
$bytes = [System.Collections.Generic.List[byte]]::new()

$writer.WriteLine("ZMX_PROBE_READY")
$writer.Flush()

while ($true) {
    $value = $inputStream.ReadByte()
    if ($value -lt 0) {
        break
    }
    $bytes.Add([byte]$value)
    if ($value -ne 13 -and $value -ne 10) {
        continue
    }

    $payload = $bytes.ToArray()
    $text = $utf8.GetString($payload).TrimEnd([char]13, [char]10)
    $normalizedText = $text.Replace(([char]27) + "[200~", "").Replace(([char]27) + "[201~", "")
    $normalizedPayload = $utf8.GetBytes($normalizedText + [char]13)
    $base64 = [Convert]::ToBase64String($payload)
    $normalizedBase64 = [Convert]::ToBase64String($normalizedPayload)
    $writer.WriteLine("ZMX_PROBE_TEXT:$normalizedText")
    $writer.WriteLine("ZMX_PROBE_B64:$base64")
    $writer.WriteLine("ZMX_PROBE_NORMALIZED_B64:$normalizedBase64")
    $writer.WriteLine("ZMX_PROBE_LEN:$($payload.Length)")
    $writer.Flush()
    $bytes.Clear()
}
