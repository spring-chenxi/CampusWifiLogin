#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Help', 'Setup', 'Check', 'Run', 'Install', 'Uninstall')]
    [string]$Mode = 'Help',
    [string]$Ssid,
    [string]$WifiProfile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Net.Http

$probeUri = [uri]'http://www.msftconnecttest.com/connecttest.txt'
$redirectUri = [uri]'http://www.msftconnecttest.com/redirect'
$alternateProbeUri = [uri]'http://www.msftncsi.com/ncsi.txt'
$mobileHost = 'wlan.jsyd139.com'
$unicomHost = '58.240.51.118'
$unicomSsid = 'Unicom'
$unicomProvince = 'wlan.js.chinaunicom.cn'
$dataDir = Join-Path $env:LOCALAPPDATA 'CampusWifiLogin'
$configPath = Join-Path $dataDir 'profile.xml'
$attemptPath = Join-Path $dataDir 'last-attempt.txt'
$statusPath = Join-Path $dataDir 'status.txt'
$netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'

function Write-Status([string]$Message) {
    $line = '{0:s}  {1}' -f (Get-Date), $Message
    if (Test-Path -LiteralPath $dataDir) {
        Set-Content -LiteralPath $statusPath -Value $line -Encoding UTF8
    }
    Write-Output $line
}

function Get-ConnectedSsids {
    $output = & $netsh wlan show interfaces 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'WLAN status is unavailable. Check that Wi-Fi is on and Windows allows desktop apps to access location if required.'
    }
    foreach ($line in $output) {
        if ([string]$line -match '^\s*SSID\s*:\s*(.+?)\s*$') {
            $Matches[1]
        }
    }
}

function Wait-ForWifi($Config, [bool]$Connect) {
    $deadline = (Get-Date).AddSeconds(40)
    $requested = $false
    do {
        $active = @(Get-ConnectedSsids)
        if ($active -ccontains $Config.Ssid) { return 'Ready' }
        if ($active.Count -gt 0) { return 'OtherWifi' }
        if (-not $Connect) { return 'Disconnected' }
        if (-not $requested) {
            & $netsh wlan connect "name=$($Config.WifiProfile)" "ssid=$($Config.Ssid)" 2>&1 | Out-Null
            $requested = ($LASTEXITCODE -eq 0)
        }
        Start-Sleep -Seconds 4
    } while ((Get-Date) -lt $deadline)
    return 'Disconnected'
}

function Read-Page($Client, [uri]$Uri) {
    $response = $Client.GetAsync($Uri).GetAwaiter().GetResult()
    try {
        $status = [int]$response.StatusCode
        $location = $null
        if ($status -in 301, 302, 303, 307, 308 -and $response.Headers.Location) {
            $location = [uri]::new($Uri, $response.Headers.Location)
        }
        $body = ''
        if ($status -eq 200) {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        [pscustomobject]@{ Status = $status; Location = $location; Body = $body; Uri = $Uri }
    } finally {
        $response.Dispose()
    }
}

function Test-PortalUri([uri]$Uri, [string]$PortalHost) {
    return ($null -ne $Uri -and $Uri.IsAbsoluteUri -and
        $Uri.IdnHost -eq $PortalHost -and $Uri.Scheme -in 'http', 'https' -and
        $Uri.IsDefaultPort -and -not $Uri.UserInfo)
}

function Get-Connectivity($Client, [string]$PortalHost = $mobileHost) {
    $probes = @(
        @{ Uri = $probeUri; Expected = 'Microsoft Connect Test' }
        @{ Uri = $redirectUri; Expected = $null }
        @{ Uri = $alternateProbeUri; Expected = 'Microsoft NCSI' }
    )
    $online = $false
    $portal = $null
    $receivedResponse = $false
    $lastFailure = $null
    foreach ($probe in $probes) {
        if ($online -and $probe.Uri -eq $alternateProbeUri) { break }
        try {
            $page = Read-Page $Client $probe.Uri
        } catch {
            $lastFailure = $_
            continue
        }
        $receivedResponse = $true
        if (Test-PortalUri $page.Location $PortalHost) {
            return [pscustomobject]@{ Online = $false; Portal = $page.Location }
        }
        if (-not $portal) { $portal = $page.Location }
        if ($probe.Expected -and $page.Status -eq 200 -and $page.Body.Trim() -ceq $probe.Expected) {
            $online = $true
        }
    }
    if (-not $receivedResponse) { throw $lastFailure }
    if ($online) {
        return [pscustomobject]@{ Online = $true; Portal = $null }
    }
    [pscustomobject]@{ Online = $false; Portal = $portal }
}

function Read-PortalPage($Client, [uri]$Uri, [string]$PortalHost, [string]$Provider, [bool]$RequireTls = $false) {
    for ($hop = 0; $hop -lt 4; $hop++) {
        if (-not (Test-PortalUri $Uri $PortalHost) -or ($RequireTls -and $Uri.Scheme -ne 'https')) {
            throw "Unexpected $Provider portal destination."
        }
        $RequireTls = ($Uri.Scheme -eq 'https')
        $page = Read-Page $Client $Uri
        if ($page.Status -eq 200) { return $page }
        if (-not $page.Location) { break }
        $Uri = $page.Location
    }
    throw "$Provider login page is unavailable."
}

function Read-HtmlAttributes([string]$Tag) {
    $attributes = @{}
    $pattern = '(?<name>[\w:-]+)\s*=\s*(?:"(?<value>[^"]*)"|''(?<value>[^'']*)''|(?<value>[^\s>]+))'
    foreach ($match in [regex]::Matches($Tag, $pattern)) {
        $attributes[$match.Groups['name'].Value] = [System.Net.WebUtility]::HtmlDecode($match.Groups['value'].Value)
    }
    return $attributes
}

function Find-MobileFrame([string]$Html, [uri]$BaseUri) {
    foreach ($match in [regex]::Matches($Html, '(?is)<i?frame\b[^>]+>')) {
        $attributes = Read-HtmlAttributes $match.Value
        if ($attributes['name'] -eq 'mainFrame' -and $attributes['src']) {
            return [uri]::new($BaseUri, $attributes['src'])
        }
    }
    return $null
}

function Read-MobileForm([string]$Html) {
    $fields = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($match in [regex]::Matches($Html, '(?is)<input\b[^>]+>')) {
        $attributes = Read-HtmlAttributes $match.Value
        $name = $attributes['name']
        if ($attributes['type'] -eq 'hidden' -and $name -and $name -notin 'UserName', 'PassWord') {
            $fields[$name] = [string]$attributes['value']
        }
    }
    if (-not $fields.ContainsKey('paramStr') -or [string]::IsNullOrWhiteSpace($fields['paramStr']) -or
        -not $fields.ContainsKey('serviceType') -or $fields['serviceType'] -ne '301') {
        throw 'Unrecognized Jiangsu Mobile login form.'
    }
    return ,$fields
}

function Read-UnicomForm($Page) {
    $pattern = '(?is)<form\b(?<opening>[^>]*)>(?<body>.*?)</form\s*>'
    foreach ($form in [regex]::Matches($Page.Body, $pattern)) {
        $attributes = Read-HtmlAttributes $form.Groups['opening'].Value
        if ($attributes['method'] -and $attributes['method'] -ne 'post') { continue }
        if ($attributes['action']) {
            $action = [uri]::new($Page.Uri, $attributes['action'])
            if (-not (Test-PortalUri $action $unicomHost) -or $action.Scheme -ne $Page.Uri.Scheme -or
                $action.AbsolutePath -cne '/authServlet' -or $action.Query -or $action.Fragment) { continue }
        }

        $fields = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
        $inputs = @{}
        foreach ($inputTag in [regex]::Matches($form.Groups['body'].Value, '(?is)<input\b[^>]+>')) {
            $inputAttributes = Read-HtmlAttributes $inputTag.Value
            $name = $inputAttributes['name']
            if (-not $name -or $inputTag.Value -match '\sdisabled(?:\s|=|>)') { continue }
            $inputs[$name] = $inputAttributes['type']
            if ($inputAttributes['type'] -eq 'hidden' -and $name -notin 'UserName', 'PassWord') {
                $fields[$name] = [string]$inputAttributes['value']
            }
        }
        if (-not $inputs.ContainsKey('UserName') -or $inputs['PassWord'] -ne 'password') { continue }
        foreach ($name in $inputs.Keys) {
            if ($inputs[$name] -ne 'hidden' -and $name -match 'captcha|verify.?code|validat(e|ion).?code|check.?code|rand.?code|vcode') {
                throw 'Jiangsu Unicom login needs manual verification.'
            }
        }
        if (-not $fields.ContainsKey('paramStr') -or [string]::IsNullOrWhiteSpace($fields['paramStr'])) { continue }
        if ($fields.ContainsKey('province') -and $fields['province'] -and $fields['province'] -ne $unicomProvince) { continue }
        $fields['province'] = $unicomProvince
        return ,$fields
    }
    throw 'Unrecognized Jiangsu Unicom login form.'
}

function Get-UnicomLogin($Client, [uri]$Portal) {
    $provider = 'Jiangsu Unicom'
    $page = Read-PortalPage $Client $Portal $unicomHost $provider
    foreach ($frameTag in [regex]::Matches($page.Body, '(?is)<i?frame\b[^>]+>')) {
        $attributes = Read-HtmlAttributes $frameTag.Value
        if (-not $attributes['src']) { continue }
        $frame = [uri]::new($page.Uri, $attributes['src'])
        if ((Test-PortalUri $frame $unicomHost) -and $frame.AbsolutePath -ceq '/style/school/index.jsp') {
            $page = Read-PortalPage $Client $frame $unicomHost $provider ($page.Uri.Scheme -eq 'https')
            break
        }
    }
    [pscustomobject]@{
        Provider = $provider
        Action = [uri]::new($page.Uri, '/authServlet')
        Referer = $page.Uri
        Fields = (Read-UnicomForm $page)
        UserField = 'UserName'
        PasswordField = 'PassWord'
    }
}

function Get-PortalLogin($Client, [uri]$Portal, [string]$PortalHost = $mobileHost) {
    if (-not (Test-PortalUri $Portal $PortalHost)) { return $null }
    if ($PortalHost -eq $unicomHost) { return (Get-UnicomLogin $Client $Portal) }

    $provider = 'Jiangsu Mobile'
    $page = Read-PortalPage $Client $Portal $mobileHost $provider
    $frame = Find-MobileFrame $page.Body $page.Uri
    if ($frame) {
        $page = Read-PortalPage $Client $frame $mobileHost $provider ($page.Uri.Scheme -eq 'https')
    }
    $fields = Read-MobileForm $page.Body
    $fields['isCookie'] = 'false'
    $fields['cookieType'] = '-1'
    [pscustomobject]@{
        Provider = $provider
        Action = [uri]::new($page.Uri, '/authServlet')
        Referer = $page.Uri
        Fields = $fields
        UserField = 'UserName'
        PasswordField = 'PassWord'
    }
}

function Send-PortalLogin($Client, $Login, [pscredential]$Credential) {
    $fields = $Login.Fields
    $fields[$Login.UserField] = $Credential.UserName
    $fields[$Login.PasswordField] = $Credential.GetNetworkCredential().Password
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Login.Action)
    try {
        $request.Headers.Referrer = $Login.Referer
        if ($Login.Provider -eq 'Jiangsu Unicom') {
            $request.Headers.Add('Origin', $Login.Referer.GetLeftPart([UriPartial]::Authority))
        }
        $request.Content = [System.Net.Http.FormUrlEncodedContent]::new($fields)
        $fields.Remove($Login.PasswordField) | Out-Null
        $fields.Remove($Login.UserField) | Out-Null
        $response = $Client.SendAsync($request).GetAwaiter().GetResult()
        $response.Dispose()
    } finally {
        $request.Dispose()
    }
}

function Save-Profile {
    $network = $Ssid
    if (-not $network) { $network = Read-Host 'Wi-Fi name as shown in Windows' }
    if ([string]::IsNullOrWhiteSpace($network) -or $network -match '[\x00-\x1f"]' -or
        [System.Text.Encoding]::UTF8.GetByteCount($network) -gt 32) {
        throw 'Enter the exact WLAN name shown in Windows.'
    }
    $profileName = $WifiProfile
    if (-not $profileName) { $profileName = $network }
    if ($profileName -match '[\x00-\x1f"]') { throw 'Invalid Windows Wi-Fi profile name.' }
    $provider = 'Jiangsu Mobile'
    if ($network -ceq $unicomSsid) { $provider = 'Jiangsu Unicom' }
    Write-Host "Use your $provider Wi-Fi service credentials. This portal may transmit them over HTTP."
    $account = Read-Host 'Mobile phone number'
    if ($account -notmatch '^\d{11}$') { throw 'Enter an 11-digit mobile phone number.' }
    $password = Read-Host 'Wi-Fi service password' -AsSecureString
    if (-not $password.Length) { throw 'A password is required.' }

    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    $temporary = Join-Path $dataDir ('profile-{0}.tmp' -f [guid]::NewGuid())
    try {
        [pscustomobject]@{
            Ssid = $network
            WifiProfile = $profileName
            Account = $account
            Password = $password
        } | Export-Clixml -LiteralPath $temporary
        if (Test-Path -LiteralPath $configPath) {
            [IO.File]::Replace($temporary, $configPath, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $configPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
    Write-Status 'Saved locally. Run Check while connected to the target Wi-Fi, then Run to try authentication.'
}

function Invoke-WifiLogin($Config, [bool]$CheckOnly) {
    $wifi = Wait-ForWifi $Config (-not $CheckOnly)
    if ($wifi -ne 'Ready') {
        Write-Status "Target Wi-Fi unavailable ($wifi). Connect manually once so Windows saves its profile."
        return
    }
    $portalHost = $mobileHost
    if ($Config.Ssid -ceq $unicomSsid) { $portalHost = $unicomHost }
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]'GZip, Deflate'
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(8)
    $client.MaxResponseContentBufferSize = 1048576
    try {
        $state = $null
        $probeFailure = $null
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try { $state = Get-Connectivity $client $portalHost } catch {
                $probeFailure = $_.Exception.GetBaseException()
            }
            if ($state -and ($state.Online -or $state.Portal)) { break }
            if ($attempt -lt 2) { Start-Sleep -Seconds 3 }
        }
        if (-not $state) {
            $reason = $probeFailure.GetType().Name
            if ($probeFailure -is [System.Net.WebException]) { $reason = $probeFailure.Status }
            Write-Status "Could not reach the connectivity probes ($reason)."
            return
        }
        if ($state.Online) {
            Write-Status 'Internet already available. No login needed.'
            return
        }
        if (-not $state.Portal) {
            Write-Status 'No portal redirect found. Open the Windows Wi-Fi sign-in page manually.'
            return
        }
        $login = Get-PortalLogin $client $state.Portal $portalHost
        if (-not $login) {
            Write-Status ('No matching provider for portal host {0}. Credentials were not sent.' -f $state.Portal.IdnHost)
            return
        }
        if ($CheckOnly) {
            Write-Status ('{0} login form detected. Credentials were not sent.' -f $login.Provider)
            return
        }
        if ((Test-Path -LiteralPath $attemptPath) -and
            (Get-Item -LiteralPath $attemptPath).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddMinutes(-3)) {
            Write-Status 'A login was recently submitted. Wait three minutes before retrying.'
            return
        }
        if (@(Get-ConnectedSsids) -cnotcontains $Config.Ssid) {
            Write-Status 'Wi-Fi changed before authentication. Credentials were not sent.'
            return
        }
        $credential = [pscredential]::new($Config.Account, $Config.Password)
        Set-Content -LiteralPath $attemptPath -Value ([DateTime]::UtcNow.ToString('o'))
        Send-PortalLogin $client $login $credential
        foreach ($delay in 2, 4, 6) {
            Start-Sleep -Seconds $delay
            $online = $false
            try { $online = (Get-Connectivity $client $portalHost).Online } catch { }
            if ($online) {
                Write-Status 'Login succeeded. Internet connectivity verified.'
                return
            }
        }
        Write-Status 'Login submitted, but internet access was not verified. Check the account and portal manually.'
    } finally {
        $client.Dispose()
    }
}

function Register-LoginTask([string]$TaskName, [string]$UserSid) {
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "{0}" -Mode Run' -f $PSCommandPath
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments -WorkingDirectory $PSScriptRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserSid
    $principal = New-ScheduledTaskPrincipal -UserId $UserSid -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Status 'Automatic login scheduled for your next Windows sign-in.'
}

if ($MyInvocation.InvocationName -eq '.') { return }

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
try { $userSid = $identity.User.Value } finally { $identity.Dispose() }
$taskName = "CampusWifiLogin-$userSid"

try {
    switch ($Mode) {
        'Help' { Write-Output 'Use -Mode Setup, Check, Run, Install, or Uninstall. See README.md.' }
        'Setup' { Save-Profile }
        'Uninstall' {
            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            }
            Write-Status 'Automatic login disabled. Local configuration is retained.'
        }
        default {
            if ($Mode -eq 'Check' -and $Ssid) {
                Invoke-WifiLogin ([pscustomobject]@{ Ssid = $Ssid }) $true
                break
            }
            if (-not (Test-Path -LiteralPath $configPath)) { throw 'Run -Mode Setup first.' }
            if ($Mode -eq 'Install') {
                Register-LoginTask $taskName $userSid
                break
            }
            $config = Import-Clixml -LiteralPath $configPath
            if ($Mode -eq 'Check') {
                Invoke-WifiLogin $config $true
                break
            }
            $mutex = [System.Threading.Mutex]::new($false, "Local\CampusWifiLogin-$userSid")
            $acquired = $false
            try {
                try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
                if ($acquired) { Invoke-WifiLogin $config $false }
            } finally {
                if ($acquired) { $mutex.ReleaseMutex() }
                $mutex.Dispose()
            }
        }
    }
} catch {
    if ($Mode -in 'Run', 'Check') {
        $reason = $_.Exception.Message
        $known = @(
            'WLAN status is unavailable. Check that Wi-Fi is on and Windows allows desktop apps to access location if required.',
            'Unexpected Jiangsu Mobile portal destination.',
            'Jiangsu Mobile login page is unavailable.',
            'Unrecognized Jiangsu Mobile login form.',
            'Unexpected Jiangsu Unicom portal destination.',
            'Jiangsu Unicom login page is unavailable.',
            'Unrecognized Jiangsu Unicom login form.',
            'Jiangsu Unicom login needs manual verification.',
            'Run -Mode Setup first.'
        )
        if ($reason -notin $known) { $reason = "Operation failed ($($_.Exception.GetType().Name))." }
        Write-Status $reason
    } else {
        Write-Error $_.Exception.Message -ErrorAction Continue
    }
    exit 1
}
