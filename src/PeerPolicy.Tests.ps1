BeforeAll {
    . ("$PSScriptRoot\PeerPolicy.ps1")
}

describe "Unit tests" {
    context "Convert-TextToIpCidrList" {
        it "Should be able to parse" {
            $actual = ("192.168.0.0/24, 192.168.1.0/5,kadabra192.168.2.0/08" | Convert-TextToIpCidrList)
            $actual | should -be @("192.168.0.0/24", "192.168.1.0/5", "192.168.2.0/08")
        }
        it "Should not read incorrect values" {
            $actual = ("10.1.0.256/24, 10.2.0.-1/24, 10.3.0.0/0, 10.4z.0.0/24" | Convert-TextToIpCidrList)
            $actual | should -HaveCount 0
        }
    }
    context "check Convert-TextToPolicy dependencies" {

        it "Should create new IpRange" {
            $var = New-IpRange 1 2
            $var.start | should -be 1
            $var.end | should -be 2
        }
        it "Should Reverse Bytes" -TestCases @(
            @{ value = 0x00000000L; expected = 0x00000000L},
            @{ value = 0x00FF00FFL; expected = 0xFF00FF00L},
            @{ value = 0x04030201L; expected = 0x01020304L}
        ) {
            Convert-ReverseBytes($value) | should -be $expected
            Convert-ReverseBytes($value) | should -BeOfType UInt32
        }
        it "Should convert UInt To IPAddress" -TestCases @(
            @{ value = 0xFFFFFFFFL; expected = "255.255.255.255"}
            @{ value = 0x0A000001L; expected = "10.0.0.1"}
        ) {
            Convert-UIntToIPAddress($value) | should -be $expected
        }
        it "Should convert Cidr to Netmask" -TestCases @(
            @{ value = 08; expected = 0xFF000000L},
            @{ value = 24; expected = 0xFFFFFF00L},
            @{ value = 31; expected = 0xFFFFFFFEL}
        ){
            Convert-CidrToNetmask($value) | should -be $expected
            Convert-CidrToNetmask($value) | should -BeOfType UInt32
        }
        it "Should convert UInt To IPAddress" -TestCases (
            @{ inputValue = "192.168.0.0/24"; expectedStart = "192.168.0.0"; expectedEnd = "192.168.0.255"},
            @{ inputValue = "192.168.1.0/25"; expectedStart = "192.168.1.0"; expectedEnd = "192.168.1.127"},
            @{ inputValue = "192.168.2.10/30"; expectedStart = "192.168.2.8"; expectedEnd = "192.168.2.11"},
            @{ inputValue = "10.0.0.0/8"; expectedStart = "10.0.0.0"; expectedEnd = "10.255.255.255"},
            @{ inputValue = "10.0.0.0/08"; expectedStart = "10.0.0.0"; expectedEnd = "10.255.255.255"},
            @{ inputValue = "200.0.0.0/1"; expectedStart = "128.0.0.0"; expectedEnd = "255.255.255.255"}
            
        ) {
            $actualRange = ($inputValue | Convert-IpCidr-To-IpRange)
            Convert-UIntToIPAddress($actualRange.start) | should -be $expectedStart
            Convert-UIntToIPAddress($actualRange.end) | should -be $expectedEnd
        }

        it "Should Add IpRange As Xml Element" {
            [xml]$xml = "<x/>"
            $rootNode = $xml.FirstChild

            New-IpRange 7 15 | Add-IpRangeAsElement $xml $rootNode

            $rootNode.FirstChild.OuterXml | should -be '<iprange start="0.0.0.7" end="0.0.0.15" weight="10" />'
        }
        it "Should Convert XmlToFormattedString" {
            [xml]$xml = "<x><y/></x>"
            Convert-XmlToFormattedString $xml | should -MatchExactly '<x>[\r\n]* *<y \/>[\r\n]*<\/x>'
        }
        it "Should return new template" {
            $template = Get-PolicyTemplate

            #validate xml
            [xml]$xml = $template
            $root = $xml.SelectSingleNode("btpolicy")
            $null -ne $root | should -Be $true
            $null -ne $root.SelectSingleNode("revision") | should -Be $true
            $null -ne $root.SelectSingleNode("oper") | should -Be $true
        }
    }
    context "check Merge-IpRanges" {
        # line below is a fix for scoping issue: New-IpRange function not visible in TestCases clause. Even being defined at the top of the script
        . ("$PSScriptRoot\PeerPolicy.ps1")

        it "Should Merge IpRanges" -TestCases (
            @{ inputValue = @(); `
            expectedRanges = @() },
            @{ inputValue = , (New-IpRange 1 2); `
           expectedRanges = , (New-IpRange 1 2) },
            @{ inputValue = (New-IpRange 1 2), (New-IpRange 2 3); `
            expectedRanges = , (New-IpRange 1 3) },
            @{ inputValue = (New-IpRange 1 2), (New-IpRange 3 4); `
            expectedRanges = , (New-IpRange 1 4) },
            @{ inputValue = (New-IpRange 1 5), (New-IpRange 2 3); `
            expectedRanges = , (New-IpRange 1 5) },
            @{ inputValue = (New-IpRange 1 2), (New-IpRange 4 5); `
            expectedRanges = (New-IpRange 1 2), (New-IpRange 4 5) }
        ) {
            $actual = $inputValue | Merge-IpRanges

            $actual | Should -HaveCount $expectedRanges.Count 
            for ($i = 0; $i -lt $expectedRanges.Count; $i++) {
                $actual[$i] | should -BeOfType IpRange
                $actual[$i].start | should -be $expectedRanges[$i].start
                $actual[$i].end | should -be $expectedRanges[$i].end
            }
        }    
    }

    context "Check Convert-TextToPolicy" {
        it "basic" {
            [xml]$doc = "<btpolicy/>"
            "10.0.0.1/32" | Convert-TextToPolicy $doc "basic test"
            $doc.OuterXml | should -be '<btpolicy><!-- Generated from basic test --><iprange start="10.0.0.1" end="10.0.0.1" weight="10" /></btpolicy>'
        }
        it "combine" {
            [xml]$doc = "<btpolicy/>"
            "10.0.0.1/32_10.0.0.2/31" | Convert-TextToPolicy $doc "combine test"
            $doc.OuterXml | should -be '<btpolicy><!-- Generated from combine test --><iprange start="10.0.0.1" end="10.0.0.3" weight="10" /></btpolicy>'
        }
    }
}
Describe 'Integration Tests' {
    context "Check Get-PolicyXmlString" {
        it "Should work with empty parameter" {
            @() | Get-PolicyXmlString | should -Match '<btpolicy[\s\S]*<revision>[\s\S]*</btpolicy>' 
            @() | Get-PolicyXmlString | should -BeOfType String
        }
        it -Tag PS51 "Should throw error for non-existent server" {
            { Get-PolicyXmlString "file://\\nonserver1\file.txt" } | should -Throw "*The network path was not found*"
        }
        it -Tag PS51 "Should throw error for non-existent file" {
            $filename = Join-Path $PSScriptRoot 'nonexistentfile.txt'
            { Get-PolicyXmlString "file://$filename" } | should -Throw "*Could not find file *nonexistentfile.txt'*"
        }
        it -Tag PS51 "Should throw error for wrong url" {
            { Get-PolicyXmlString "http://zzz.comd" } | should -Throw "*The remote name could not be resolved: 'zzz.comd'*"
        }
        it -Tag PS51 "Should process input file" {
            $filename = Join-Path $TestDrive 'somefile.txt'
            "10.0.0.1/32`r 20.5.0.1/31 `n 100.15.10.1/08 " | Out-File -FilePath $filename -Encoding utf8

            $actual = Get-PolicyXmlString "file://$filename"
            $actual | should -Match '<iprange start="10.0.0.1" end="10.0.0.1" weight="10" '
            $actual | should -Match '<iprange start="20.5.0.0" end="20.5.0.1" weight="10" '
            $actual | should -Match '<iprange start="100.0.0.0" end="100.255.255.255" weight="10" '
        }
        it -Tag PS51 "Should process multiple input files" {
            $filename1 = Join-Path $TestDrive 'somefile1.txt'
            "10.0.0.1/32`r20.5.0.1/31" | Out-File -FilePath $filename1 -Encoding utf8
            $filename2 = Join-Path $TestDrive 'somefile2.txt'
            "100.15.10.1/08 " | Out-File -FilePath $filename2 -Encoding utf8

            $actual = ("file://$filename1", "file://$filename2" | Get-PolicyXmlString)
            $actual | should -Match (Split-Path $filename1 -Leaf)
            $actual | should -Match (Split-Path $filename2 -Leaf)
            $actual | should -Match '<iprange start="10.0.0.1" end="10.0.0.1" weight="10" '
            $actual | should -Match '<iprange start="20.5.0.0" end="20.5.0.1" weight="10" '
            $actual | should -Match '<iprange start="100.0.0.0" end="100.255.255.255" weight="10" '
        }
    }
}