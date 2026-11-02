# =====================================================================
# SCRIPT AUDIT SWITCH MULTI-VENDOR (HPE ProCurve / ArubaOS-CX / Comware)
# Protocolli supportati: SSH (porta 22) e Telnet (porta 23)
# =====================================================================

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$SwitchListFile = (Join-Path -Path $PSScriptRoot -ChildPath "switches.txt"),

    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory = (Join-Path -Path $PSScriptRoot -ChildPath "output"),

    [Parameter(Mandatory = $false)]
    [string]$CredentialsFile = (Join-Path -Path $PSScriptRoot -ChildPath "credentials.json"),

    [Parameter(Mandatory = $false)]
    [switch]$NoPause
)

# ----------------- PREREQUISITI MODULI -----------------
if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Write-Error "Il modulo 'Posh-SSH' non è installato. Esegui: Install-Module -Name Posh-SSH -Scope CurrentUser"
    exit 1
}
Import-Module Posh-SSH -ErrorAction Stop

# ----------------- GESTIONE CREDENZIALI -----------------
$CredentialSets = @()

if (Test-Path -Path $CredentialsFile) {
    Write-Verbose "Caricamento credenziali dal file: $CredentialsFile"
    try {
        $CredentialSets = Get-Content -Path $CredentialsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Error "Impossibile analizzare il file JSON delle credenziali ($CredentialsFile): $($_.Exception.Message)"
        exit 1
    }
} else {
    Write-Host "[INFO] File '$CredentialsFile' non trovato. Inserimento credenziale interattivo:" -ForegroundColor Yellow
    $promptCred = Get-Credential -UserName "admin" -Message "Credenziali di accesso agli switch"
    $CredentialSets = @(
        [PSCustomObject]@{
            Nome     = "Credenziale Manuale"
            Username = $promptCred.UserName
            Password = $promptCred.GetNetworkCredential().Password
        }
    )
}

# ----------------- PERCORSI E VERIFICHE -----------------
$OutputReport = Join-Path -Path $OutputDirectory -ChildPath "tutti_gli_switch_report.txt"

if (-not (Test-Path -Path $OutputDirectory)) {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
}

if (-not (Test-Path -Path $SwitchListFile)) {
    Write-Host "[ERRORE] File degli switch non trovato: $SwitchListFile" -ForegroundColor Red
    Write-Host "Crea il file inserendo un IP per riga o usa il parametro -SwitchListFile." -ForegroundColor Yellow
    if (-not $NoPause) { Start-Sleep -Seconds 10 }
    exit 1
}

# ----------------- FUNZIONI DI SUPPORTO -----------------
function Clean-TerminalOutput {
    param ([string]$Text)
    if (-not $Text) { return "" }
    $clean = $Text -replace '\x1B\[[0-9;]*[a-zA-Z]|\x1B\[\?[0-9]+[a-zA-Z]|\x1B\([B0]|\x1B\[[0-9;]*[HfABCDsuJKhlmnpr]', ''
    $clean = $clean -replace '-- MORE --[^\r\n]*', ''
    return $clean.Trim()
}

function Test-TcpPort {
    param (
        [string]$IP, 
        [int]$Port, 
        [int]$TimeoutMs = 1500
    )
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($IP, $Port, $null, $null)
        $success = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($success) {
            $client.EndConnect($iar)
            $client.Close()
            return $true
        } else {
            $client.Close()
            return $false
        }
    } catch {
        return $false
    }
}

function Read-TelnetStream {
    param ($Stream, [int]$WaitMs = 600)
    Start-Sleep -Milliseconds $WaitMs
    $text = ""
    $buffer = New-Object byte[] 8192
    while ($Stream.DataAvailable) {
        $bytesRead = $Stream.Read($buffer, 0, $buffer.Length)
        $text += [System.Text.Encoding]::ASCII.GetString($buffer, 0, $bytesRead)
        Start-Sleep -Milliseconds 150
    }
    return $text
}

function Send-TelnetCommand {
    param ($Stream, [string]$Command)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("$Command`r`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

# ----------------- LETTURA SWITCH E HEADER REPORT -----------------
$SwitchList = Get-Content -Path $SwitchListFile | ForEach-Object { $_.Trim() } | Where-Object { 
    $_ -ne "" -and -not $_.StartsWith("#") 
}

$DataOra = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$Header = "######################################################################`r`n" +
          "# REPORT CONSOLIDATO SWITCH HPE / ARUBA / COMWARE`r`n" +
          "# Data: $DataOra`r`n" +
          "# Totale apparati in lista: $($SwitchList.Count)`r`n" +
          "######################################################################`r`n`r`n"

Set-Content -Path $OutputReport -Value $Header -Encoding UTF8

# ----------------- MOTORE SSH -----------------
function Audit-Switch-SSH {
    param ([string]$IP)

    $session = $null
    $usedCred = $null

    foreach ($cred in $CredentialSets) {
        Write-Host "[$IP] [SSH] Tentativo autenticazione con $($cred.Nome)..." -ForegroundColor Yellow

        $secPassword = ConvertTo-SecureString $cred.Password -AsPlainText -Force
        $psCred = New-Object System.Management.Automation.PSCredential($cred.Username, $secPassword)

        try {
            $session = New-SSHSession -ComputerName $IP -Credential $psCred -AcceptKey -ConnectionTimeout 10 -ErrorAction Stop
            if ($session) {
                $usedCred = $cred.Nome
                Write-Host "[$IP] [SSH] Autenticato con $($cred.Nome)!" -ForegroundColor Green
                break
            }
        }
        catch {
            Write-Host "[$IP] [SSH] Fallito con $($cred.Nome)." -ForegroundColor DarkGray
        }
    }

    if (-not $session) { return $false }

    try {
        $stream = New-SSHShellStream -Index $session.SessionId
        $stream.WriteLine("")
        Start-Sleep -Milliseconds 600
        $null = $stream.Read()

        $stream.WriteLine("no page")
        Start-Sleep -Milliseconds 400
        $stream.WriteLine("screen-length 0 temporary")
        Start-Sleep -Milliseconds 400
        $null = $stream.Read()

        $stream.WriteLine("display version")
        Start-Sleep -Seconds 1
        $vDisplay = $stream.Read()

        $commandsToRun = @()
        $osType = ""

        if ($vDisplay -match "Comware") {
            $osType = "HPE Comware"
            $commandsToRun = @("display device", "display version", "display current-configuration")
        } else {
            $stream.WriteLine("show version")
            Start-Sleep -Seconds 1
            $vShow = $stream.Read()

            if (($vShow -match "AOS-CX") -or ($vShow -match "ArubaOS-CX")) {
                $osType = "ArubaOS-CX"
                $commandsToRun = @("show system", "show system uptime", "show running-config")
            } else {
                $osType = "ArubaOS-S / HPE ProCurve"
                $commandsToRun = @("show system", "show uptime", "show running-config")
            }
        }

        Write-Host "[$IP] Sistema rilevato: $osType (via SSH)" -ForegroundColor Magenta

        $nowSw = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $swHeader = "======================================================================`r`n" +
                    "SWITCH IP: $IP`r`n" +
                    "PROTOCOLLO: SSH (Porta 22)`r`n" +
                    "DATA RILEVAZIONE: $nowSw`r`n" +
                    "CREDENZIALI USATE: $usedCred`r`n" +
                    "OS RILEVATO: $osType`r`n" +
                    "======================================================================`r`n`r`n"
        Add-Content -Path $OutputReport -Value $swHeader -Encoding UTF8

        foreach ($cmd in $commandsToRun) {
            Write-Host "[$IP] Esecuzione: $cmd" -ForegroundColor Gray
            $stream.WriteLine($cmd)

            $rawOutput = ""
            $maxWait = if (($cmd -match "running-config") -or ($cmd -match "current-configuration")) { 25 } else { 4 }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            while ($sw.Elapsed.TotalSeconds -lt $maxWait) {
                Start-Sleep -Milliseconds 400
                $chunk = $stream.Read()
                if ($chunk) {
                    $rawOutput += $chunk
                    if ($chunk -match "-- MORE --") { $stream.Write(" ") }
                    if ($rawOutput -match "([#>]|\])\s*$") { break }
                }
            }

            $cleaned = Clean-TerminalOutput -Text $rawOutput
            $cmdBlock = ">>> COMANDO: $cmd`r`n$cleaned`r`n--------------------------------------------------`r`n`r`n"
            Add-Content -Path $OutputReport -Value $cmdBlock -Encoding UTF8
        }

        Write-Host "[$IP] Dati salvati con successo (SSH)." -ForegroundColor Green
        return $true
    }
    finally {
        if ($session) { $null = Remove-SSHSession -Index $session.SessionId }
    }
}

# ----------------- MOTORE TELNET -----------------
function Audit-Switch-Telnet {
    param ([string]$IP)

    $tcp = $null
    $stream = $null
    $usedCred = $null
    $authenticated = $false

    foreach ($cred in $CredentialSets) {
        Write-Host "[$IP] [TELNET] Tentativo con $($cred.Nome)..." -ForegroundColor Yellow
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.ReceiveTimeout = 6000
            $tcp.SendTimeout = 6000
            $tcp.Connect($IP, 23)
            $stream = $tcp.GetStream()

            $loginSw = [System.Diagnostics.Stopwatch]::StartNew()
            $bufferAll = ""
            $userSent = $false
            $passSent = $false

            while ($loginSw.Elapsed.TotalSeconds -lt 12) {
                $chunk = Read-TelnetStream -Stream $stream -WaitMs 500
                if ($chunk) {
                    $bufferAll += $chunk

                    if ($bufferAll -match "(?i)press any key") {
                        Send-TelnetCommand -Stream $stream -Command ""
                        $bufferAll = ""
                    }
                    elseif ($bufferAll -match "(?i)(menu system|main menu)") {
                        Send-TelnetCommand -Stream $stream -Command "0"
                        $bufferAll = ""
                    }
                    elseif ((-not $userSent) -and ($bufferAll -match "(?i)(username|login):")) {
                        Write-Host "[$IP] Invio Username ($($cred.Username))..." -ForegroundColor DarkGray
                        Send-TelnetCommand -Stream $stream -Command $cred.Username
                        $userSent = $true
                        $bufferAll = ""
                    }
                    elseif ((-not $passSent) -and ($bufferAll -match "(?i)password:")) {
                        Write-Host "[$IP] Invio Password..." -ForegroundColor DarkGray
                        Send-TelnetCommand -Stream $stream -Command $cred.Password
                        $passSent = $true
                        $bufferAll = ""
                    }
                    elseif ($passSent -and ($bufferAll -match "(<[^>]+>|\[[^\]]+\]|[#>]|Login failed|failed|incorrect)")) {
                        if ($bufferAll -match "(?i)(failed|incorrect)") {
                            Write-Host "[$IP] Credenziali rifiutate." -ForegroundColor DarkGray
                            break
                        } else {
                            $authenticated = $true
                            $usedCred = $cred.Nome
                            Write-Host "[$IP] [TELNET] Autenticato con $($cred.Nome)!" -ForegroundColor Green
                            break
                        }
                    }
                }
            }

            if ($authenticated) { break }
            $tcp.Close()
        }
        catch {
            if ($tcp) { $tcp.Close() }
        }
    }

    if (-not $authenticated) { return $false }

    try {
        Send-TelnetCommand -Stream $stream -Command "screen-length 0 temporary"
        Send-TelnetCommand -Stream $stream -Command "no page"
        $null = Read-TelnetStream -Stream $stream -WaitMs 500

        Send-TelnetCommand -Stream $stream -Command "display version"
        $vDisplay = Read-TelnetStream -Stream $stream -WaitMs 1000

        $commandsToRun = @()
        $osType = ""

        if ($vDisplay -match "Comware") {
            $osType = "HPE Comware"
            $commandsToRun = @("display device", "display version", "display current-configuration")
        } else {
            Send-TelnetCommand -Stream $stream -Command "show version"
            $vShow = Read-TelnetStream -Stream $stream -WaitMs 1000

            if (($vShow -match "AOS-CX") -or ($vShow -match "ArubaOS-CX")) {
                $osType = "ArubaOS-CX"
                $commandsToRun = @("show system", "show system uptime", "show running-config")
            } else {
                $osType = "ArubaOS-S / HPE ProCurve"
                $commandsToRun = @("show system", "show uptime", "show running-config")
            }
        }

        Write-Host "[$IP] Sistema rilevato: $osType (via Telnet)" -ForegroundColor Magenta

        $nowSw = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $swHeader = "======================================================================`r`n" +
                    "SWITCH IP: $IP`r`n" +
                    "PROTOCOLLO: TELNET (Porta 23)`r`n" +
                    "DATA RILEVAZIONE: $nowSw`r`n" +
                    "CREDENZIALI USATE: $usedCred`r`n" +
                    "OS RILEVATO: $osType`r`n" +
                    "======================================================================`r`n`r`n"
        Add-Content -Path $OutputReport -Value $swHeader -Encoding UTF8

        foreach ($cmd in $commandsToRun) {
            Write-Host "[$IP] Esecuzione: $cmd" -ForegroundColor Gray
            Send-TelnetCommand -Stream $stream -Command $cmd

            $rawOutput = ""
            $maxWait = if (($cmd -match "running-config") -or ($cmd -match "current-configuration")) { 25 } else { 5 }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            while ($sw.Elapsed.TotalSeconds -lt $maxWait) {
                Start-Sleep -Milliseconds 400
                $chunk = Read-TelnetStream -Stream $stream -WaitMs 200
                if ($chunk) {
                    $rawOutput += $chunk
                    if ($chunk -match "-- MORE --") { Send-TelnetCommand -Stream $stream -Command " " }
                    if ($rawOutput -match "(<[^>]+>|\[[^\]]+\]|[#>])\s*$") { break }
                }
            }

            $cleaned = Clean-TerminalOutput -Text $rawOutput
            $cmdBlock = ">>> COMANDO: $cmd`r`n$cleaned`r`n--------------------------------------------------`r`n`r`n"
            Add-Content -Path $OutputReport -Value $cmdBlock -Encoding UTF8
        }

        Write-Host "[$IP] Dati salvati con successo (Telnet)." -ForegroundColor Green
        return $true
    }
    finally {
        if ($tcp) { $tcp.Close() }
    }
}

# ----------------- COORDINATORE E CONTROLLO PORTE -----------------
function Audit-Switch {
    param ([string]$IP)

    Write-Host "`n--- Analisi Switch: $IP ---" -ForegroundColor Cyan

    $hasSSH = Test-TcpPort -IP $IP -Port 22 -TimeoutMs 1500
    $hasTelnet = $false

    if (-not $hasSSH) {
        $hasTelnet = Test-TcpPort -IP $IP -Port 23 -TimeoutMs 1500
    }

    $success = $false

    if ($hasSSH) {
        Write-Host "[$IP] Porta 22 aperta: Avvio procedura SSH..." -ForegroundColor Green
        $success = Audit-Switch-SSH -IP $IP
    }
    elseif ($hasTelnet) {
        Write-Host "[$IP] Porta 22 chiusa, porta 23 aperta: Avvio procedura TELNET..." -ForegroundColor Yellow
        $success = Audit-Switch-Telnet -IP $IP
    }
    else {
        Write-Host "[$IP] ERRORE: Porte 22 (SSH) e 23 (Telnet) irraggiungibili." -ForegroundColor Red
        $errText = "======================================================================`r`n" +
                   "SWITCH IP: $IP`r`n" +
                   "STATO: ERRORE - Porte SSH (22) e Telnet (23) chiuse o timeout rete`r`n" +
                   "======================================================================`r`n`r`n"
        Add-Content -Path $OutputReport -Value $errText -Encoding UTF8
        return
    }

    if (-not $success) {
        Write-Host "[$IP] ERRORE: Autenticazione fallita con tutti i set di credenziali." -ForegroundColor Red
        $errText = "======================================================================`r`n" +
                   "SWITCH IP: $IP`r`n" +
                   "STATO: ERRORE - Connessione/Autenticazione fallita con tutti i set`r`n" +
                   "======================================================================`r`n`r`n"
        Add-Content -Path $OutputReport -Value $errText -Encoding UTF8
    }
}

# ----------------- ESECUZIONE -----------------
foreach ($ip in $SwitchList) {
    Audit-Switch -IP $ip
}

Write-Host "`n======================================================================" -ForegroundColor Cyan
Write-Host "Operazione completata! Report salvato in: $OutputReport" -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Cyan

if (-not $NoPause) {
    for ($i = 15; $i -gt 0; $i--) {
        Write-Host "`rChiusura finestra in $i secondi... (CTRL+C per uscire) " -NoNewline
        Start-Sleep -Seconds 1
    }
}
