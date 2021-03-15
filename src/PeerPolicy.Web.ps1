<#
.SYNOPSIS
Hosts a single-threaded webserver for processing peer policy. Default page is a configuration.
.PARAMETER WebServer
Set to $true to run web server, alternatively use Register or Unregister
.PARAMETER Uri
Array of input http/https and file resources
.PARAMETER OpenBrowser
$true to open configuration page in the default web browser on start
.PARAMETER ShowWindow
$false to hide Powershell window. Does not applies immediately, modifies lnk instead
#>
Param (
    [switch] $WebServer,
    [switch] $Register,
    [switch] $Unregister,

    [String[]] $Uri,
    [bool] $OpenBrowser = $true,
    [bool] $ShowWindow = $true,

    [String] $HttpPrefix = 'http://localhost:8086/',
    [int] $CacheExpiresHours = 24
)

Set-StrictMode -Version Latest

try {
    . ("$PSScriptRoot\PeerPolicy.ps1") -Uri $Uri
}
catch {
    throw "Error while loading supporting PowerShell Scripts: $PSItem"
}

Function Get-PowershellPath {
    $PowershellExePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($PowershellExePath.Contains("_ISE")) {
        $PowershellExePath = (Get-Command powershell.exe).Definition
    }
    $PowershellExePath
}
Function Get-LnkPath ([String] $lnkFileNameAppendix = "") {
    $filename = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) + "$lnkFileNameAppendix.lnk"
    [Environment]::GetFolderPath('Startup') | Join-Path -ChildPath $filename
}

Function Save-Shortcut([String] $shortcutPath, [String] $targetPath, [String] $argument, [String] $description) {
    $WshShell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $WshShell.CreateShortcut($shortcutPath)
        try {
            $shortcut.TargetPath = $targetPath
            $shortcut.Arguments = $argument
            $shortcut.WindowStyle = 7 #Minimized
            $shortcut.Description = $description
            $shortcut.Save()
        }
        finally {
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shortcut) | Out-Null
        }
    }
    finally {
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($WshShell) | Out-Null
    }
}

Function Get-HtmlHomeTemplate() {
    $HtmlHomeFilename = $PSCommandPath.Replace(".ps1", ".html")
    [IO.File]::ReadAllText($HtmlHomeFilename)
}

Function Format-UriArgument([String[]] $uri) {
    if (($null -ne $uri) -and ($uri.Length -gt 0)) {
        [String[]] $enquoted = ($uri | ForEach-Object { $_ -replace "'", "''" -replace '"', '\"' })
        " -Uri @('" + ($enquoted -join "','") + "')"
    }
    else {
        ""
    }
}
Function RegisterAndStartTask {
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [WebSettings] $Settings,
        [String] $lnkFileNameAppendix = ""
    )

    $ScriptPath = $PSCommandPath
    $Argument = ""
    if ($Settings.IsShowWindow -eq $false) {
        $Argument += " -WindowStyle Hidden"
    }
    $Argument += " -ExecutionPolicy Bypass"
    $Argument += " -Command `"$ScriptPath`" -WebServer"
    $Argument += " -OpenBrowser `$$($Settings.IsOpenBrowser)"
    $Argument += " -ShowWindow `$$($Settings.IsShowWindow)"
    $Argument += Format-UriArgument $settings.Uri

    $ShortcutPath = Get-LnkPath $lnkFileNameAppendix
    if (Test-Path -Path $ShortcutPath) {
        $msg = "Updated"
    }
    else {
        $msg = "Created"
    }
    Write-Information "$msg $ShortcutPath with argument $Argument"

    Save-Shortcut -shortcutPath $ShortcutPath -targetPath (Get-PowershellPath) `
        -argument $Argument -description "PeerPolicy WebServer"

    "$msg ""$ShortcutPath"""
}

Function StopAndUnregisterTask {
    [OutputType([String])]
    [CmdletBinding()]
    Param (
        [String] $lnkFileNameAppendix = ""
    )
    $ShortcutPath = Get-LnkPath $lnkFileNameAppendix
    Remove-Item $ShortcutPath
    "Removed $($ShortcutPath)"
}

Function New-CacheObject ([String] $content = "", [DateTime] $lastModified = [DateTime]::MinValue, [String[]] $uri = @()) {
    [PSCustomObject]@{
        Content      = $content;
        LastModified = $lastModified;
        Uri          = $uri
    }
}

if ("WebSettings" -as [Type]) {} else {
    Add-Type @"
public class WebSettings {
    public string[] Uri;
    public bool IsShowWindow;
    public bool IsOpenBrowser;
    public int HistoryDepth;
    public int CacheExpiresHours;
}
"@
}

Function New-WebSettings ([String[]]$uri, $isShowWindow = $true, $isOpenBrowser = $true, $historyDepth = 10, $cacheExpiresHours = 24) {
    [PSCustomObject]@{
        PSTypeName        = "WebSettings"
        Uri               = $uri
        IsShowWindow      = $isShowWindow
        IsOpenBrowser     = $isOpenBrowser
        HistoryDepth      = $historyDepth
        CacheExpiresHours = $cacheExpiresHours
    }
}

$State = [PSCustomObject]@{
    Cache    = $null
    Settings = New-WebSettings $Uri $ShowWindow $OpenBrowser 10 $CacheExpiresHours;
    History  = New-Object System.Collections.ArrayList
}

Function Add-HistoryItem ([System.Net.HttpListenerContext] $context, [TimeSpan] $elapsed) {
    $Script:State.History.Insert(0, [PSCustomObject]@{
            Date = [DateTime]::Now; Method = $context.Request.HttpMethod;
            RawUrl = GetFirstChars $context.Request.RawUrl 50;
            UserAgent = (GetFirstChars $context.Request.UserAgent);
            Status = $context.Response.StatusCode;
            Elapsed = $stopwatch.Elapsed
        })

    if ($Script:State.History.Count -gt $Script:State.Settings.HistoryDepth) {
        $Script:State.History.RemoveAt($Script:State.History.Count - 1)
    }
}

Function WriteResponse([System.Net.HttpListenerContext] $context, [String] $output) {
    if (-not [String]::IsNullOrEmpty($output)) {
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($output)
        $context.Response.ContentLength64 = $buffer.Length
        if ($context.Request.HttpMethod -ne 'HEAD') {
            $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
    }
    Write-Host -NoNewline "`t[$($context.Response.StatusCode)]"
    $context.Response.OutputStream.Close()
}

Function Get-HeaderIfModified([System.Net.HttpListenerContext] $context) {
    [String] $ifModifiedSinceString = $context.Request.Headers["If-Modified-Since"]
    $ifModifiedSince = [DateTime]::MinValue
    if ($ifModifiedSinceString.Length -gt 0) {
        if (-not [DateTime]::TryParseExact(($ifModifiedSinceString -Replace "%3a", ":"), "r", $null,
                [System.Globalization.DateTimeStyles]::None, [ref]$ifModifiedSince)) {
            Write-Error "Unable to parse $ifModifiedSinceString as date"
        }
    }
    $ifModifiedSince
}

Function GetFirstChars([String] $inputString, [UInt16] $chars = 26) {
    if ($inputString.Length -gt $chars) {
        $inputString.Substring(0, $chars) + "..."
    }
    else {
        $inputString
    }
}

Function Get-Xml([System.Net.HttpListenerContext] $context) {
    $context.Response.ContentType = "application/xml"

    $uri = $Script:State.Settings.Uri

    if ($null -ne $context.Request.QueryString["Uri"]) {
        Add-Type -Assembly System.Web
        $uri = [System.Web.HttpUtility]::UrlDecode($context.Request.QueryString["Uri"]) -split '\r?\n' -match '\S'
    }

    if ($null -ne $Script:State.Cache -and ($uri -join ',') -eq ($Script:State.Cache.Uri -join ',')) {
        $expireDate = $Script:State.Cache.LastModified.AddHours($CacheExpiresHours)
        $cacheAvailable = ($expireDate -ge [DateTime]::Now)
        $isModified = Get-HeaderIfModified $context

        if ($cacheAvailable) {
            if ($isModified -ne [DateTime]::MinValue -and $expireDate -ge $isModified) {
                Write-Host -NoNewline "`tNotModified"
                $context.Response.StatusCode = 304 # Not Modified
                return ""
            }
            else {
                Write-Host -NoNewline "`tCached"
                return $Script:State.Cache.Content
            }
        }
    }

    $policy = ($uri | Get-PolicyXmlString) ####

    $Script:State.Cache = New-CacheObject $policy (Get-Date) $uri
    $context.Response.Headers["Last-Modified"] = $Script:State.Cache.LastModified.ToString("R")
    $policy
}

Function Get-Register([System.Net.HttpListenerContext] $context) {
    #            $context.Response.ContentType = "text/html"
    Add-Type -Assembly System.Web

    [String[]] $uri3 = [System.Web.HttpUtility]::UrlDecode($context.Request.QueryString["Uri"]) -split '\r?\n' -match '\S'
    $showWindow = $context.Request.QueryString["showWindow"] -ieq 'True'
    $openBrowser = $context.Request.QueryString["openBrowser"] -ieq 'true'

    $Script:State.Cache = New-CacheObject

    #Write-Warning $Script:Uri # -Join " + "

    $settings = $Script:State.Settings
    $settings.Uri = $uri3
    $settings.IsShowWindow = $showWindow
    $settings.IsOpenBrowser = $openBrowser
    $message = (RegisterAndStartTask $settings)
    "$message. Now restarting.. . Page should automatically refresh.'"
}

$routesHash = [ordered]@{}

Function RegisterRoute([String] $httpMethod, [String] $url, [scriptblock] $func) {
    $key = "$httpMethod@$url"
    $routesHash[$key] = @{ httpMethod = $httpMethod; url = $url; func = $func }
}
Function GetRoute([System.Net.HttpListenerContext] $context) {
    $key = $context.Request.HttpMethod + "@" + $context.Request.Url.AbsolutePath
    if ($routesHash.PSBase.Contains($key)) {
        $routesHash[$key]
    }
    else {
        $null
    }
}

Function RegisterRoutes {
    $GetXml = {
        Param ([System.Net.HttpListenerContext] $context)
        WriteResponse $context (Get-Xml $context)
    }
    RegisterRoute 'GET' '/xml' $GetXml
    RegisterRoute 'HEAD' '/xml' $GetXml
    RegisterRoute 'GET' '/Settings' {
        Param ([System.Net.HttpListenerContext] $context)
        $context.Response.ContentType = "application/json"
        WriteResponse $context ($Script:State.Settings | ConvertTo-Json)
    }
    RegisterRoute 'GET' '/' {
        Param ([System.Net.HttpListenerContext] $context)
        $context.Response.ContentType = "text/html"
        WriteResponse $context (Get-HtmlHomeTemplate)
    }
    RegisterRoute 'GET' '/Stop' {
        Param ([System.Net.HttpListenerContext] $context)
        WriteResponse $context 'Exited, now you can close this page'
        $http.Stop()
    }
    RegisterRoute 'GET' '/Register' {
        Param ([System.Net.HttpListenerContext] $context)
        WriteResponse $context (Get-Register $context)

        $http.Stop()
        $Script:Restart = $true
    }
    RegisterRoute 'GET' '/Unregister' {
        Param ([System.Net.HttpListenerContext] $context)

        WriteResponse $context (StopAndUnregisterTask)
    }
    RegisterRoute 'GET' '/History' {
        Param ([System.Net.HttpListenerContext] $context)
        WriteResponse $context ($Script:State.History | ConvertTo-Html)
    }
}

Function ProcessHttpRequest {
    [CmdletBinding()]
    Param (
        [System.Net.HttpListener] $http
    )

    $context = $http.GetContext()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $context.Response.Headers["Access-Control-Allow-Origin"] = "*"
    $context.Response.Headers["Access-Control-Allow-Methods"] = "POST, GET"

    Write-Host -NoNewline "$(Get-Date -Format "yyyy.MM.dd HH:mm:ss") $($context.Request.HttpMethod) $($context.Request.RawUrl)"

    $route = GetRoute($context)
    if ($null -ne $route) {
        try {
            $route.func.Invoke($context)
        }
        catch {
            $context.Response.ContentType = "text/plain";
            $context.Response.StatusCode = 400

            [Exception]$ex = $PSItem.Exception
            while ($null -ne $ex.InnerException -and $ex -is [System.Management.Automation.MethodInvocationException]) {
                $ex = $ex.InnerException
            }

            Write-Error "$ex"
            WriteResponse $context $ex.Message
        }
    }
    else {
        $context.Response.StatusCode = 404
        WriteResponse $context
    }

    Add-HistoryItem $context $stopwatch.Elapsed

    Write-Host "`t$($stopwatch.Elapsed)"
}

Function StartWebServer() {
    $Script:Restart = $false

    $http = New-Object System.Net.HttpListener
    $http.Prefixes.Add($HttpPrefix)
    try {
        $http.Start()
    }
    catch [System.Net.HttpListenerException] {
        if ($PSItem -match 'Failed to listen on prefix .* because it conflicts with an existing registration on the machine') {

            $url = $HttpPrefix.Replace("*", "localhost") + "Stop"
            $res = Invoke-WebRequest -URI $url -TimeoutSec 1
            if ($res.StatusCode -ne 200) { throw "Unable to stop service on $HttpPrefix`: $res" }

            #previous http instance were disposed
            $http = New-Object System.Net.HttpListener
            $http.Prefixes.Add($HttpPrefix)
            try {
                $http.Start()
            }
            catch {
                throw "Second try http Start has failed: $PSItem"
            }
        }
        else {
            throw
        }
    }
    RegisterRoutes

    if ($http.IsListening) {
        Write-Host "Web server is listening $($http.Prefixes) powershell version $($PSVersionTable.PSVersion.Major)"
    }

    if ($OpenBrowser) {
        Start-Process $HttpPrefix.Replace("*", "localhost")
    }

    while ($http.IsListening) {
        ProcessHttpRequest -http $http
    }
    if ($Script:Restart) {
        $Script:Restart = $false
        Start-Process (Get-LnkPath)
    }
}


if ($Register) {
    RegisterAndStartTask $Uri
}
elseif ($Unregister) {
    StopAndUnregisterTask
}
elseif ($WebServer) {
    StartWebServer $Uri
}
else {
}