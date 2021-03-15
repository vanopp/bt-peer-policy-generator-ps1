<#
.SYNOPSIS
Processes common IP/CIDR format input to bt peer policy xml format
.PARAMETER Process
If switch not provided script does nothing and exits
.PARAMETER Uri
Array of input http/https and file resources.
.PARAMETER Destination
Output filename. If not provided output printed on the console.
#>
Param (
    [switch] $Process,
    [String[]] $Uri, # = @(),
    [String] $Destination
)

Set-StrictMode -Version Latest

if (-not (Test-Path variable:global:PSVersionTable) -or $PSVersionTable.PSVersion.Major -le 2) {
    throw "Script requires Powershell version 3 or greater (5.1 is recommended). Try this update https://www.microsoft.com/download/details.aspx?id=54616"
}

if ("IpRange" -as [Type]) {} else {
    Add-Type @"
public struct IpRange {
   public uint start;
   public uint end;
}
"@
}

Function New-IpRange (
    [Parameter(Mandatory = $true)][UInt32] $start,
    [Parameter(Mandatory = $true)][UInt32] $end) {
    [PSCustomObject]@{
        PSTypeName = "IpRange"
        start      = $start
        end        = $end
    }
}

Function Convert-TextToIpCidrList {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [String] $inputText
    )
    Begin {
        New-Variable -Name ipcidrRegex -Value '((?:(?:0?0?\d|0?[1-9]\d|1\d\d|2[0-5][0-5]|2[0-4]\d)\.){3}(?:0?0?\d|0?[1-9]\d|1\d\d|2[0-5][0-5]|2[0-4]\d))(\/(3[0-2]|[0-2]\d|[1-9]))' -Option Constant
    }
    Process {
        $inputText `
        | Select-String -Pattern $ipcidrRegex -AllMatches `
        | ForEach-Object { $_.Matches.Value }
    }
}

Function Convert-ReverseBytes([Parameter(Mandatory = $true)][uint32] $value) {
    $bytes = [BitConverter]::GetBytes($value)
    $bytesRev = ([Byte]$bytes[3], $bytes[2], $bytes[1], $bytes[0], 0, 0, 0, 0)
    [BitConverter]::ToUInt32($bytesRev, 0)
}

Function Convert-UIntToIPAddress([Parameter(Mandatory = $true)][uint32] $value) {
    New-Object Net.IPAddress (Convert-ReverseBytes($value))
}

Function Convert-CidrToNetmask([Parameter(Mandatory = $true)][String] $value) {
    $intValue = [Int32]::Parse( $value )
    [UInt32]((0x1L -shl 32) - (0x1L -shl (32 - $intValue)))
}

Function Convert-IpCidr-To-IpRange {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [String] $inputIpCidr
    )

    Process {
        $index = $inputIpCidr.IndexOf('/')
        $ip = [IPAddress] $inputIpCidr.Substring(0, $index)
        [UInt32]$ipR = Convert-ReverseBytes ($ip.Address)
        [UInt32]$netmaskR = Convert-CidrToNetmask ($inputIpCidr.Substring($index + 1))
        $rangeStartR = $ipR -band $netmaskR
        $rangeEndR = (-bnot $netmaskR) -bor ($rangeStartR -band $netmaskR)

        New-IpRange -start $rangeStartR -end $rangeEndR
    }
}


Function Merge-IpRanges {
    [CmdletBinding()]
    Param (
        # to group properly input should be sorted by start
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [IpRange] $range
    )

    Begin {
        $item = $null
    }
    Process {
        if ($null -eq $item) {
            $item = $range
        }
        elseif (($range.start -ge $item.start -and $range.start -le ($item.end + 1)) `
                -or ($range.end -ge $item.start -and $range.end -le ($item.end + 1))) {
            $item.start = [Math]::Min($item.start, $range.start)
            $item.end = [Math]::Max($item.end, $range.end)
        }
        else {
            $item
            $item = $range
        }
    }
    End {
        if ($null -ne $item) {
            $item
        }
    }
}

Function Add-IpRangeAsElement {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [xml]$doc,
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlElement]$btpolicy,

        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [IpRange] $ipRange
    )
    Process {
        $start = Convert-UIntToIPAddress($ipRange.start)
        $end = Convert-UIntToIPAddress($ipRange.end)
        $ce = $btpolicy.AppendChild($doc.CreateElement("iprange"))
        $ce.SetAttribute("start", $start)
        $ce.SetAttribute("end", $end)
        $ce.SetAttribute("weight", "10")
    }
}

Function Convert-TextToPolicy {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [xml]$doc,
        [Parameter(Mandatory = $true)]
        [String] $sourceName,

        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [String] $inputText
    )
    Process {
        $btpolicy = $doc.SelectSingleNode("btpolicy")
        $btpolicy.AppendChild($doc.CreateComment(" Generated from $sourceName ")) | Out-Null

        $inputText `
        | Convert-TextToIpCidrList `
        | Convert-IpCidr-To-IpRange `
        | Sort-Object -Property start `
        | Merge-IpRanges `
        | Add-IpRangeAsElement $doc $btpolicy
    }
}

Function Convert-XmlToFormattedString([Parameter(Mandatory = $true)][xml]$doc) {
    $sw = New-Object System.Io.Stringwriter
    try {
        $writer = New-Object System.Xml.XmlTextWriter($sw)
        try {
            $writer.Formatting = [System.Xml.Formatting]::Indented
            $doc.WriteContentTo($writer)
            return $sw.ToString()
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $sw.Dispose()
    }
}

Function Get-PolicyTemplate() {
    $filename = $PSCommandPath.Replace(".ps1", ".Template.xml")
    [IO.File]::ReadAllText($filename)
}

Function Invoke-WebRequestWrapper($uri) {
    if ($PSVersionTable.PSVersion.Major -le 5) {
        Invoke-WebRequest -Uri $uri
    }
    else {
        if ($uri.StartsWith("http://") -or $uri.StartsWith("https://")) {
            Invoke-WebRequest -Uri $uri
        }
        else {
            $filename = $uri -replace "file://", "" # complete rfc8089 not needed for now
            Get-Content -Path $filename -ErrorAction Stop
        }
    }
}

Function Get-PolicyXmlString {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [String] $uri
    )
    Begin {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 #fixes WebException: The request was aborted: Could not create SSL/TLS secure channel.

        [xml]$doc = Get-PolicyTemplate
        $btpolicy = $doc.SelectSingleNode("btpolicy")
        if ($null -eq $btpolicy) {
            throw "btpolicy node is not found in the template xml doc"
        }
        $revisionNode = $btpolicy.SelectSingleNode("./revision")
        if ($null -ne $revisionNode) {
            $revisionNode.InnerText = Get-Date -Format "yyyy.MMdd.HHMM.ssSS"
        }
        $operNode = $btpolicy.SelectSingleNode("./oper")
        if ($null -ne $operNode) {
            $operNode.InnerText = (Split-Path $PSCommandPath -Leaf).ToString()
        }
    }
    Process {
        try {
            Invoke-WebRequestWrapper -Uri $uri | Convert-TextToPolicy $doc $uri
        }
        catch {
            #[System.Net.WebException] {
            throw ( New-Object System.ApplicationException( "Error loading $uri` [$PSItem]", $_.Exception ) )
        }
    }
    End {
        Convert-XmlToFormattedString $doc
    }
}

if ($Process) {
    if ($Destination) {
        $Uri | Get-PolicyXmlString | Out-File -FilePath $Destination -Encoding UTF8
    }
    else {
        $Uri | Get-PolicyXmlString
    }
}