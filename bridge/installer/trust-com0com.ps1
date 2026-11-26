# Trusts com0com's driver publisher on this PC, so the bridge service can make virtual COM pairs
# later without Windows' "Would you like to install this device software?" prompt (a service has
# no screen to show it on). Same effect as ticking "Always trust software from Steven William
# Hatchett" in that prompt. Run by the installer whenever com0com is present; safe to run again.
$ErrorActionPreference = "Stop"
$dirs = @("${env:ProgramFiles(x86)}\com0com", "$env:ProgramFiles\com0com") | Where-Object { Test-Path $_ }
$cat = $dirs | ForEach-Object { Get-ChildItem $_ -Recurse -Filter "com0com.cat" -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $cat) { Write-Output "com0com's driver catalog (com0com.cat) wasn't found"; exit 1 }
$cert = (Get-AuthenticodeSignature $cat.FullName).SignerCertificate
if (-not $cert) { Write-Output "$($cat.FullName) isn't signed"; exit 1 }
# Only the publisher the signed com0com 2.2.2.0 build is known to use (see its ReadMe1st.txt).
if ($cert.Subject -notmatch "Hatchett") { Write-Output "Unexpected signer, not trusted: $($cert.Subject)"; exit 1 }
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
$store.Open("ReadWrite")
$store.Add($cert)
$store.Close()
Write-Output "Trusted com0com's driver publisher: $($cert.Subject)"
