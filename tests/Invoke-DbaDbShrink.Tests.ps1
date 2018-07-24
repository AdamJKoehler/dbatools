$CommandName = $MyInvocation.MyCommand.Name.Replace(".Tests.ps1", "")
Write-Host -Object "Running $PSCommandpath" -ForegroundColor Cyan
. "$PSScriptRoot\constants.ps1"

Describe "$CommandName Unit Tests" -Tag 'UnitTests' {
        Context "Validate parameters" {
            $paramCount = 14
            $defaultParamCount = 13
            [object[]]$params = (Get-ChildItem function:\Invoke-DbaDbShrink).Parameters.Keys
            $knownParameters = 'SqlInstance', 'SqlCredential','Database','ExcludeDatabase','AllUserDatabases','PercentFreeSpace','ShrinkMethod','StatementTimeout','LogsOnly','FileType','StepSizeMB','ExcludeIndexStats','ExcludeUpdateUsage','EnableException'
            It "Should contain our specific parameters" {
                ( (Compare-Object -ReferenceObject $knownParameters -DifferenceObject $params -IncludeEqual | Where-Object SideIndicator -eq "==").Count ) | Should Be $paramCount
            }
            It "Should only contain $paramCount parameters" {
                $params.Count - $defaultParamCount | Should Be $paramCount
            }
        }
    }

Describe "$CommandName Integration Tests" -Tags "IntegrationTests" {
    Context "Verifying Database is shrunk" {
        BeforeAll {
            $server = Connect-DbaInstance -SqlInstance $script:instance1
            $defaultPath = $server | Get-DbaDefaultPath
        }
        BeforeEach {
            # Create Database with small size and grow it
            $db = New-Object Microsoft.SqlServer.Management.SMO.Database($server, "dbatoolsci_shrinktest")

            $primaryFileGroup = New-Object Microsoft.SqlServer.Management.Smo.Filegroup($db, "PRIMARY")
            $db.FileGroups.Add($primaryFileGroup)
            $setFileSize = 1 * 1024

            $primaryFile = New-Object Microsoft.SqlServer.Management.Smo.DataFile($primaryFileGroup, $db.Name)
            $primaryFile.FileName = "$($defaultPath.Data)\$($db.Name).mdf"
            $primaryFile.Size = $setFileSize
            $primaryFile.Growth = 8 * 1024
            $primaryFile.GrowthType = "KB"
            $primaryFileGroup.Files.Add($primaryFile)

            $logFile = New-Object Microsoft.SqlServer.Management.Smo.LogFile($db, "$($db.Name)_log")
            $logFile.FileName = "$($defaultPath.Log)\$($db.Name)_log.ldf"
            $logFile.Size = $setFileSize
            $logFile.Growth = 8 * 1024
            $logFile.GrowthType = "KB"
            $db.LogFiles.Add($logFile)

            $db.Create()

            # Execute a bunch of inserts in a transaction to grow the data and log files
            $conn = $server.ConnectionContext
            $conn.ExecuteNonQuery("use $($db.Name);")
            $conn.BeginTransaction();
            $conn.ExecuteNonQuery("create table dbatoolsci_test1 (col1 char(8000));")
            1..1000 | ForEach-Object {
                $conn.ExecuteNonQuery("insert into dbatoolsci_test1 values('data');")
            }
            $conn.ExecuteNonQuery("drop table dbatoolsci_test1;")
            $conn.CommitTransaction();

            # Save the current file sizes
            $db.Refresh()
            $db.RecalculateSpaceUsage()
            $db.FileGroups[0].Files[0].Refresh()
            $db.LogFiles[0].Refresh()
            $oldLogSize = $db.LogFiles[0].Size
            $oldDataSize = $db.FileGroups[0].Files[0].Size
        }
        AfterEach {
            $db | Remove-DbaDatabase -Confirm:$false
        }

        It "Log file grew ready for shrink tests" {
            $oldLogSize | Should BeGreaterThan $setFileSize
        }

        It "Data file grew ready for shrink tests" {
            $oldLogSize | Should BeGreaterThan $setFileSize
        }

        It "Shrinks just the log file when FileType is Log" {
            Invoke-DbaDbShrink $server -Database $db.Name -FileType Log
            $db.Refresh()
            $db.RecalculateSpaceUsage()
            $db.FileGroups[0].Files[0].Refresh()
            $db.LogFiles[0].Refresh()
            $db.FileGroups[0].Files[0].Size | Should Be $oldDataSize
            $db.LogFiles[0].Size | Should BeLessThan $oldLogSize
        }

        It "Shrinks just the data file(s) when FileType is Data" {
            Invoke-DbaDbShrink $server -Database $db.Name -FileType Data
            $db.Refresh()
            $db.RecalculateSpaceUsage()
            $db.FileGroups[0].Files[0].Refresh()
            $db.LogFiles[0].Refresh()
            $db.FileGroups[0].Files[0].Size | Should BeLessThan $oldDataSize
            $db.LogFiles[0].Size | Should Be $oldLogSize
        }

        It "Shrinks the entire database when FileType is All" {
            Invoke-DbaDbShrink $server -Database $db.Name -FileType All
            $db.Refresh()
            $db.RecalculateSpaceUsage()
            $db.FileGroups[0].Files[0].Refresh()
            $db.LogFiles[0].Refresh()
            $db.LogFiles[0].Size | Should BeLessThan $oldLogSize
            $db.FileGroups[0].Files[0].Size | Should BeLessThan $oldDataSize
        }
    }
}