$x = "protocol=https`nhost=github.com`n`n" | git credential fill 2>&1
$token = (($x | Where-Object { $_ -match '^password=' }) -replace '^password=','').Trim()
$headers = @{ Authorization = "Bearer $token"; Accept = "application/vnd.github+json" }
$r = Invoke-RestMethod -Uri "https://api.github.com/repos/chen1203260599-web/Repo/actions/runs/40718617471" -Headers $headers -Method Get
"run_status=$($r.status) conclusion=$($r.conclusion)" | Set-Content -LiteralPath "C:\Users\陈旭\Desktop\Repo\.q1.txt" -Encoding utf8
