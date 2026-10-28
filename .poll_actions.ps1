$cred = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null
$token = ($cred | Select-String '^password=').ToString().Substring(9).Trim()
$headers = @{ Authorization = "Bearer $token"; Accept = "application/vnd.github+json" }
$out = "C:\Users\陈旭\Desktop\Repo\.actions_result.txt"
for ($i = 0; $i -lt 55; $i++) {
  Start-Sleep -Seconds 60
  try {
    $r = Invoke-RestMethod -Uri "https://api.github.com/repos/chen1203260599-web/Repo/actions/runs/40718617471" -Headers $headers -Method Get
    if ($r.status -eq 'completed') {
      "COMPLETED conclusion=$($r.conclusion)" | Set-Content -LiteralPath $out -Encoding utf8
      exit 0
    }
    "POLL $i status=$($r.status)" | Set-Content -LiteralPath $out -Encoding utf8
  } catch {
    "POLL $i ERROR $($_.Exception.Message)" | Set-Content -LiteralPath $out -Encoding utf8
  }
}
"TIMEOUT still queued" | Set-Content -LiteralPath $out -Encoding utf8
