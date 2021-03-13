describe "Unit tests" {
    BeforeAll {
        . ("$PSScriptRoot\PeerPolicy.Web.ps1")
    }
    context "Check util"  {
        it "Should format argument" -TestCases @(
            @{ value = @(); expected = ""},
            @{ value = @("123"); expected = " -Uri @('123')"},
            @{ value = @("234", "abc"); expected = " -Uri @('234','abc')"},
            @{ value = @("aa'bb"); expected = " -Uri @('aa''bb')"},
            @{ value = @('aa"bb'); expected = " -Uri @('aa\""bb')"},
            @{ value = $null; expected = ""}
        ){
            Format-UriArgument $value | should -be $expected
        }
    }
    context "Check" {
        it "Should create shortcut without uri" {
            $uniqueString = [Guid]::NewGuid()
            try {
                $res = RegisterAndStartTask -settings (New-WebSettings @()) -lnkFileNameAppendix $uniqueString
                $res | should -Match 'Created.*".*lnk"'
            }
            finally {
                Remove-Item (Get-LnkPath $uniqueString)
            }
        }
        it "Should create and update shortcut" {
            $uniqueString = [Guid]::NewGuid()
            try {
                $res = RegisterAndStartTask -settings (New-WebSettings -uri @()) -lnkFileNameAppendix $uniqueString
                $res | should -Match 'Created.*".*lnk"'
                (Get-LnkPath $uniqueString) | should -Exist

                $res = RegisterAndStartTask -settings (New-WebSettings -uri @($uniqueString)) -lnkFileNameAppendix $uniqueString
                $res | should -Match 'Updated.*".*lnk"'

                (Get-LnkPath $uniqueString) | should -Exist
            }
            finally {
                Remove-Item (Get-LnkPath $uniqueString)
            }
        }
        it "Should create shortcut with uri" {
            $uniqueString = [Guid]::NewGuid()
            $res = RegisterAndStartTask -settings (New-WebSettings -uri @('123')) -lnkFileNameAppendix $uniqueString
            try {
                $res | should -Match '".*lnk"'
                if ($res -match '".*lnk"') {
                    [String]$filename = $Matches[0]
                    $filename = $filename.Substring(1, $filename.Length - 2)
                    $filename | should -Exist
                    $filename | should -be (Get-LnkPath $uniqueString)
                }
                else {
                    throw "Result should contain .lnk fullpath. Actual result is '$res'"
                }
            }
            finally {
                Remove-Item (Get-LnkPath $uniqueString)
            }
        }
    }
}
describe ("Integration Tests") {
    BeforeEach {
        $port = Get-Random -Minimum 50000 -Maximum 60000
        $httpPrefix = "http://localhost:$port/"
        $ScriptPath = "$PSScriptRoot\PeerPolicy.Web.ps1"
        $job = (Start-Job {
            $inputObj = ($input | ConvertTo-Json | ConvertFrom-Json)
            
            & "$($inputObj.ScriptPath)" -WebServer $true -Uri @() -OpenBrowser $false -HttpPrefix $inputObj.HttpPrefix
        } -InputObject @{ HttpPrefix = $httpPrefix; ScriptPath = $ScriptPath } )
    }
    context ("Check Web Server") {
        it "Should start-stop" {
        }
        it "Should get /" {
            $html = Invoke-WebRequest "$($httpPrefix)" -TimeoutSec 5
            $html | should -Match '<html'
        }
        it "Should get /xml (default empty Uri list)" {
            $xmlText = Invoke-WebRequest "$($httpPrefix)xml" -TimeoutSec 5
            [xml]$xml = $xmlText
            $nodes = $xml.SelectNodes('//iprange')
            $nodes.Count | should -Be 3
        }
        it -Tag PS51 "Should get /xml?Uri (Custom input file)" {
            $filename = Join-Path $TestDrive 'somefile.txt'
            "10.0.0.1/32`r 20.5.0.1/31 `n 100.15.10.1/08 " | Out-File -FilePath $filename -Encoding utf8

            $xmlText = Invoke-WebRequest "$($httpPrefix)xml?Uri=$filename"  -TimeoutSec 5
            [xml]$xml = $xmlText
            $xml.SelectNodes('//iprange').Count | should -be 6
        }
        it "Should get /Settings" {
            $json = Invoke-WebRequest "$($httpPrefix)Settings" -TimeoutSec 5
            $settings = ($json | ConvertFrom-Json)
            Write-Information $settings
            $settings.Uri | should -HaveCount 0
        }
        it "Should get /History" {
            $html = Invoke-WebRequest "$($httpPrefix)History" -TimeoutSec 5
            $html | should -Match '<html'
            Write-Information "/History: $html"
        }
    }
    AfterEach { 
        Invoke-WebRequest "$($httpPrefix)Stop" -TimeoutSec 5
        if ($job -ne $null) {
            if ($job.Finished -eq $false) {
                Write-Warning "Stopping job $job"
                Stop-job -job $job
            }

            #(Receive-Job -Job $job) 
            #6>$null - TODO can't suppress Write-Host from job
        } else {
            Write-Warning "`$job is null"
        }
    }
    AfterAll {
        # just to make sure
        Get-Job | Where-Object {$_.Finished -eq $false} | % { 
            Write-Warning "Job was not stopped before. Stopping job.. $_"
            Stop-job -job $_ 
        }
    }
}