#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string[]]$DashboardIp = @(),
    [Security.SecureString]$ApiToken,
    [switch]$ExigirToken
)

$ErrorActionPreference = "Stop"
$serviceName = "AgenteCRM"
$firewallName = "Agente CRM - Porta 5003"
$targetDir = "C:\AgenteCRM"
$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$requiredPythonVersion = "3.14.5"
$pythonDownloadUrl = "https://www.python.org/ftp/python/3.14.5/python-3.14.5-amd64.exe"
$pythonSha256 = "f9c09f5ed6f796fd1a8bc5ddfa41715a494b453c4781f0e35d5077cf9fa58f6d"

function Test-PythonCandidate([string]$candidate) {
    if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { return $null }
    try {
        $version = (& $candidate -c "import platform; print(platform.python_version())" 2>$null).Trim()
        if ($version -eq $requiredPythonVersion) { return (Resolve-Path -LiteralPath $candidate).Path }
    } catch {}
    return $null
}

function Find-PythonExecutable {
    $candidates = New-Object System.Collections.Generic.List[string]
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        try {
            $launcherPython = (& $launcher.Source -3.14 -c "import sys; print(sys.executable)" 2>$null).Trim()
            if ($launcherPython) { $candidates.Add($launcherPython) }
        } catch {}
    }
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCommand) { $candidates.Add($pythonCommand.Source) }

    $registryKeys = @(
        "HKLM:\SOFTWARE\Python\PythonCore\3.14\InstallPath",
        "HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore\3.14\InstallPath",
        "HKCU:\SOFTWARE\Python\PythonCore\3.14\InstallPath"
    )
    foreach ($key in $registryKeys) {
        if (Test-Path -LiteralPath $key) {
            $installPath = (Get-Item -LiteralPath $key).GetValue("")
            if ($installPath) { $candidates.Add((Join-Path $installPath "python.exe")) }
        }
    }

    $candidates.Add((Join-Path $env:ProgramFiles "Python314\python.exe"))
    $candidates.Add((Join-Path $env:ProgramFiles "Python3145\python.exe"))
    $candidates.Add((Join-Path $env:LOCALAPPDATA "Programs\Python\Python314\python.exe"))
    $candidates.Add("C:\Python314\python.exe")

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        $valid = Test-PythonCandidate $candidate
        if ($valid) { return $valid }
    }
    return $null
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " INSTALADOR ONLINE DO AGENTE CRM" -ForegroundColor Cyan
Write-Host " Python 3.14.5 - Servico Windows" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

$pythonExe = Find-PythonExecutable
if (-not $pythonExe) {
    Write-Host "Python 3.14.5 nao localizado. Baixando do python.org..." -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $tempInstaller = Join-Path $env:TEMP "python-3.14.5-amd64.exe"
    Invoke-WebRequest -Uri $pythonDownloadUrl -OutFile $tempInstaller -UseBasicParsing
    $downloadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $tempInstaller).Hash.ToLower()
    if ($downloadHash -ne $pythonSha256) { throw "Falha na verificacao de seguranca SHA-256 do Python." }

    Write-Host "Download validado. Instalando Python 3.14.5..." -ForegroundColor Yellow
    $arguments = @("/quiet", "InstallAllUsers=1", "PrependPath=1", "Include_pip=1", "Include_test=0", "Include_doc=0", "Include_launcher=1", "InstallLauncherAllUsers=1")
    $installation = Start-Process -FilePath $tempInstaller -ArgumentList $arguments -Wait -PassThru
    if ($installation.ExitCode -notin @(0, 3010)) { throw "Falha ao instalar o Python. Codigo: $($installation.ExitCode)" }
    Start-Sleep -Seconds 2
    $pythonExe = Find-PythonExecutable
    if (-not $pythonExe) { throw "Python 3.14.5 foi instalado, mas nao foi localizado no registro ou nos caminhos padrao." }
    Write-Host "Python 3.14.5 instalado: $pythonExe" -ForegroundColor Green
} else {
    Write-Host "Python 3.14.5 encontrado: $pythonExe" -ForegroundColor Green
}

Write-Host "[1/6] Preparando C:\AgenteCRM..." -ForegroundColor Yellow
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
$sourceResolved = (Resolve-Path -LiteralPath $sourceDir).Path.TrimEnd('\')
$targetResolved = (Resolve-Path -LiteralPath $targetDir).Path.TrimEnd('\')
if ($sourceResolved -ne $targetResolved) {
    foreach ($file in @("agente_crm.py", "agente_crm_service.py", "security_config.py", "requirements.txt", "instalar_agente.ps1", "INSTALAR_COMO_SERVICO.cmd", "LEIA-ME-SEGURANCA.txt")) {
        Copy-Item -LiteralPath (Join-Path $sourceDir $file) -Destination (Join-Path $targetDir $file) -Force
    }
}

Write-Host "[2/6] Instalando dependencias online..." -ForegroundColor Yellow
& $pythonExe -m pip install --disable-pip-version-check --upgrade pip
if ($LASTEXITCODE -ne 0) { throw "Falha ao atualizar o pip. Verifique a internet ou proxy." }
& $pythonExe -m pip install --disable-pip-version-check -r (Join-Path $targetDir "requirements.txt")
if ($LASTEXITCODE -ne 0) { throw "Falha ao instalar psutil e pywin32. Verifique a internet ou proxy." }
$pywin32PostInstall = Join-Path (Split-Path -Parent $pythonExe) "Scripts\pywin32_postinstall.py"
if (Test-Path -LiteralPath $pywin32PostInstall) {
    & $pythonExe $pywin32PostInstall -install
    if ($LASTEXITCODE -ne 0) { throw "Falha na configuracao final do pywin32." }
}

Write-Host "[2/6] Protegendo configuracao e permissoes..." -ForegroundColor Yellow
$configPath = Join-Path $targetDir ".security_config.dpapi"
$configuracaoInformada = (
    $PSBoundParameters.ContainsKey("DashboardIp") -or
    $PSBoundParameters.ContainsKey("ApiToken") -or
    $PSBoundParameters.ContainsKey("ExigirToken")
)
$usarToken = $ExigirToken -or [bool]$ApiToken
$gravarConfiguracao = -not (Test-Path -LiteralPath $configPath) -or $configuracaoInformada

if (-not $gravarConfiguracao) {
    Push-Location $targetDir
    try {
        $segurancaExistente = (& $pythonExe -c "import json; from security_config import carregar_configuracao; c=carregar_configuracao(); print(json.dumps({'allowed_ips':c.get('allowed_ips',[]),'require_token':bool(c.get('require_token'))}))") | ConvertFrom-Json
    } finally {
        Pop-Location
    }
    $DashboardIp = @($segurancaExistente.allowed_ips)
    $usarToken = [bool]$segurancaExistente.require_token
    Write-Host "Configuracao DPAPI existente preservada." -ForegroundColor Green
}

if ($usarToken -and -not $ApiToken) {
    $ApiToken = Read-Host "Informe o token compartilhado com o dashboard (minimo 20 caracteres)" -AsSecureString
}
$tokenTexto = ""
if ($ApiToken) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiToken)
    try {
        $tokenTexto = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}
if ($gravarConfiguracao) {
    $configSeguranca = @{
        allowed_ips = @($DashboardIp)
        require_token = [bool]$usarToken
        token = $tokenTexto
    } | ConvertTo-Json -Compress
    $configSeguranca | & $pythonExe (Join-Path $targetDir "agente_crm.py") --configure-security-stdin
    if ($LASTEXITCODE -ne 0) { throw "Falha ao proteger a configuracao de seguranca com DPAPI." }
}

& icacls.exe $targetDir /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Falha ao restringir as permissoes de C:\AgenteCRM." }

Write-Host "[3/6] Registrando o servico Windows..." -ForegroundColor Yellow
$service = Get-Service $serviceName -ErrorAction SilentlyContinue
if ($service) {
    if ($service.Status -ne "Stopped") {
        Stop-Service $serviceName -Force
        (Get-Service $serviceName).WaitForStatus("Stopped", [TimeSpan]::FromSeconds(20))
    }
    & $pythonExe (Join-Path $targetDir "agente_crm_service.py") update
} else {
    & $pythonExe (Join-Path $targetDir "agente_crm_service.py") install
}
if ($LASTEXITCODE -ne 0) { throw "Falha ao registrar o servico AgenteCRM." }
Set-Service $serviceName -StartupType Automatic

Write-Host "[4/6] Configurando recuperacao automatica..." -ForegroundColor Yellow
& sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/15000/restart/30000 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Falha ao configurar a recuperacao automatica." }
& sc.exe failureflag $serviceName 1 | Out-Null

Write-Host "[5/6] Liberando a porta TCP 5003 no firewall..." -ForegroundColor Yellow
Get-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$parametrosFirewall = @{
    DisplayName = $firewallName
    Direction = "Inbound"
    Action = "Allow"
    Protocol = "TCP"
    LocalPort = 5003
    Profile = "Domain,Private"
}
if ($DashboardIp.Count -gt 0) {
    $parametrosFirewall.RemoteAddress = $DashboardIp
}
New-NetFirewallRule @parametrosFirewall | Out-Null

Write-Host "[6/6] Iniciando e testando o agente..." -ForegroundColor Yellow
$service = Get-Service $serviceName
if ($service.Status -ne "Running") { Start-Service $serviceName }
(Get-Service $serviceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(30))
Start-Sleep -Seconds 2
$headersTeste = @{}
if ($usarToken) { $headersTeste["X-Agente-Token"] = $tokenTexto }
$status = Invoke-RestMethod -Uri "http://127.0.0.1:5003/status" -Headers $headersTeste -TimeoutSec 15
$tokenTexto = $null
$configSeguranca = $null

Write-Host ""
Write-Host "AGENTE CRM INSTALADO COM SUCESSO" -ForegroundColor Green
Write-Host "Python: $requiredPythonVersion" -ForegroundColor Green
Write-Host "Servico: $serviceName (Automatico)" -ForegroundColor Green
Write-Host "Hostname: $($status.hostname)" -ForegroundColor Green
Write-Host "Porta: TCP 5003" -ForegroundColor Green
Write-Host "crm_messok.exe: $($status.processo.status)" -ForegroundColor Green
Write-Host "Configuracao: DPAPI + ACL restritiva" -ForegroundColor Green
if ($DashboardIp.Count -gt 0) {
    Write-Host "IPs autorizados: $($DashboardIp -join ', ')" -ForegroundColor Green
} else {
    Write-Warning "Nenhum DashboardIp informado: o agente aceita redes privadas. Para restringir, reinstale com -DashboardIp IP_DO_DASHBOARD."
}
if ($usarToken) {
    Write-Host "Autenticacao por token: ATIVA" -ForegroundColor Green
} else {
    Write-Warning "Autenticacao por token desativada para manter compatibilidade com o dashboard atual."
}
