<#
    THIS MODULE CONTAINS FUNCTIONS RELATED TO PINGCASTLE V3.2.0.1

    Initial Score: 65/100 (Stale: 31, Priv Accounts: 40, Trust: 00, Anomalies:65)
    Release Score: ??/100 (Stale: 00, Priv Accounts: 40, Trust: 00, Anomalies:65)

    Fix list:
    > S-OldNtlm                 GPO Default Domain Security Policy
    > S-ADRegistration          Function Resolve-S-ADRegistration 
    > S-DC-SubnetMissing        Function Resolve-S-DC-SubnetMissing
    > S-PwdNeverExpires         Function Resolve-S-PwdNeverExpires
#>
#region S-ADRegistration
Function Resolve-S-ADRegistration {
    <#
        .SYNOPSIS
        Resolve the alert S-ADRegistration from PingCastle.

        .DESCRIPTION
        The purpose is to ensure that basic users cannot register extra computers in the domain.

        .NOTES
        Version 01.00.00 (2024/06/09 - Creation)
    #>

    Param()

    # Prepare for eventlog
    Test-EventLog | Out-Null
    $LogData = @('Fixing ms-DS-MachineAccountQuota to 0:')

    # Fixing the value
    Try {
        Set-ADDomain -Identity (Get-ADDomain) -Replace @{"ms-DS-MachineAccountQuota" = "0" } | Out-Null
        $LogData += '> Successfull <'
        $FlagRes = 'Info'
    }
    Catch {
        $LogData += @('! FAILED !',' ','Error message from stack:',$Error[0].ToString())
        $FlagRes = 'Error'
    }

    # Checking the new value - final check
    if ($FlagRes -eq 'Info') {
        $newValue = (Get-ADObject (Get-ADDomain).distinguishedName -Properties ms-DS-MachineAccountQuota).'ms-DS-MachineAccountQuota'

        if ($newValue -eq 0) {
            $LogData += @(' ','Value checked on AD: the value is as expected.')
        } 
        Else {
            $LogData += @(' ','Value checked on AD: the value is incorect!')
            $FlagRes = 'Warning'
        }
    }

    # Sending log and leaving with proper exit code
    Write-ToEventLog $FlagRes $LogData
    Return $FlagRes
}
#endregion
#region S-DC-SubnetMissing
Function Resolve-S-DC-SubnetMissing {
    <#
        .SYNOPSIS
        Resolve the S-DC-SubnetMissing alert from PingCastle.

        .DESCRIPTION
        Ensure that the minimum set of subnet(s) has been configured in the domain.

        .NOTES
        Version 01.00.00 (2024/06.09 - Creation)
    #>
    Param()

    #region INTERNAL FUNCTIONS
    function ConvertTo-IPv4MaskString {
        param(
          [Parameter(Mandatory = $true)]
          [ValidateRange(0, 32)]
          [Int] $MaskBits
        )
        $mask = ([Math]::Pow(2, $MaskBits) - 1) * [Math]::Pow(2, (32 - $MaskBits))
        $bytes = [BitConverter]::GetBytes([UInt32] $mask)
        (($bytes.Count - 1)..0 | ForEach-Object { [String] $bytes[$_] }) -join "."
      }
    #endregion
    # Init debug 
    Test-EventLog | Out-Null
    $LogData = @('Fixing missing DC subnet in AD Sites:')
    $FlagRes = "Info"

    # Get the DC IP address and subnet
    $DCIPs = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' }
    
    #region ADD SUBNET
    # Get IP PLAN ADDRESSES and add them to the default AD Site
    foreach ($DCIP in $DCIPs) {
        Try {
            $IPplan = "$(([IPAddress] (([IPAddress] "$($DCIP.IPAddress)").Address -band ([IPAddress] (ConvertTo-IPv4MaskString $DCIP.PrefixLength)).Address)).IPAddressToString)/$($DCIP.PrefixLength)"
            $LogData += @(" ","Checking for IP Plan: $IPplan")
        }
        Catch {
            $LogData += @("Checking for IP Plan: $IPplan - FATAL ERROR",' ','Error message from stack:',$Error[0].ToString())
            $FlagRes += "Error"
        }
        
        # Check if the subnet already exists
        Try {
            $findSubnet = Get-AdReplicationSubnet $IPplan -ErrorAction Stop
        }
        Catch {
            $findSubnet = $null
        }

        if ($findSubnet) {
            $LogData += "Subnet $IPplan already exists (no action)"
        }
        Else {
            $LogData += "Subnet $IPplan is missing."
            $DfltSite = (Get-AdReplicationSite).Name
            Try {
                New-AdReplicationSubnet -Site (Get-AdReplicationSite).Name -Name $IPplan -ErrorAction Stop | Out-Null
                $LogData += "Subnet $IPplan has been added to '$DfltSite'"
            }
            Catch {
                $LogData += @("Subnet $IPplan could not be added to '$DfltSite'!")
                $FlagRes = "Error"
            }
        }
    }
    #endregion
    # Sending log and leaving with proper exit code
    Write-ToEventLog $FlagRes $LogData
    Return $FlagRes
}
#endregion
#region S-PwdNeverExpires
Function Resolve-S-PwdNeverExpires {
    <#
        .SYNOPSIS
        Resolve the S-PwdNeverExpires alert from PingCastle.

        .DESCRIPTION
        Ensure that every account has a password which is compliant with password expiration policies.
        To achieve this goal, some PSO will be added to the domain, including one specific to the emergency accounts.

        PSO List:
        > PSO-EmergencyAccounts-LongLive......: 5 years,  complex, 30 characters, Weight is 105.
        > PSO-ServiceAccounts-Legacy..........: 5 years,  complex, 30 characters, Weight is 105.
        > PSO-EmergencyAccounts-Standard......: 1 year,   complex, 30 characters, Weight is 100.
        > PSO-Users-ChangeEvery3years.........: 3 year,   complex, 16 characters, Weight is 70.
        > PSO-Users-ChangeEvery1year..........: 1 year,   complex, 12 characters, Weight is 60.
        > PSO-Users-ChangeEvery3months........: 3 months, complex, 10 characters, Weight is 50.
        > PSO-ServiceAccounts-ExtendedLife....: 3 years,  complex, 18 characters, Weight is 35.
        > PSO-ServiceAccounts-Standard........: 1 year,   complex, 16 characters, Weight is 30.
        > PSO-AdminAccounts-SystemPriveleged..: 6 months, complex, 14 characters, Weight is 20.
        > PSO-AdminAccounts-ADdelegatedRight..: 6 months, complex, 16 characters, Weight is 15.
        > PSO-ServiceAccounts-ADdelegatedRight: 1 year,   complex, 24 characters, Weight is 15.
        > PSO-AdminAccounts-ADhighPrivileges..: 6 months, complex, 20 characters, Weight is 10.

        To learn how thos PSO should be used in production, please have a look to the documentation (PSO Managegement.md)

        .NOTES
        Version 01.00.00 (2024/06/10 - Creation)
    #>
    Param()
    # Prepare logging
    Test-EventLog | Out-Null
    $LogData = @('Adding PSO to the domain:')
    $FlagRes = "Info"

    # Load XML data
    $psoXml = Get-XmlContent .\Configuration\DomainSettings.xml

    # Retrieving SID 500 SamAccountName
    $Sid500 = (Get-ADUser -Identity "$((Get-AdDomain).domainSID)-500").SamAccountName

    # Looping on PSO list
    foreach ($PSO in $psoXml.Settings.PwdStrategyObjects.PSO) {
        #region Create AD Group
        $GrpExists = Get-ADGroup -LDAPFilter "(SAMAccountName=$($PSO.Name))"
        if ($GrpExists) {
            $LogData += "$($PSO.Name): Group already exists."
        }
        Else {
            Try {
                New-ADGroup -DisplayName $PSO.Name -Description "Group to assign the PSO: $($PSO.Name)"  -GroupCategory Security -GroupScope Global -Name $PSO.Name -ErrorAction Stop | Out-Null
                $LogData += "$($PSO.Name): Group created successfully."
            }
            Catch {
                $LogData += "$($PSO.Name): Group could not be created!"
                $FlagRes = "Error"
            }
        }
        #endregion
        #region Checking if member is to be added
        if ($PSO.Member) {
            foreach ($Member in $PSO.Member) {
                if ($Member -eq 'SID-500') {
                    $MbrSam = $Sid500
                }
                Else {
                    $MbrSam = $Member
                }
                Try {
                    Add-ADGroupMember -Identity $PSO.Name -Members $MbrSam -ErrorAction Stop | Out-Null
                    $LogData += "$($PSO.Name): successfully added $MbrSam to the PSO group."
                }
                Catch {
                    $LogData += "$($PSO.Name): failed to add $MbrSam to the PSO group!"
                    $FlagRes = "Error"
                }
                Try {
                    if ((Get-ADObject -Filter "SamAccountName -eq '$MbrSam'").ObjectClass -eq 'User') {
                        Set-AdUser $MbrSam -PasswordNeverExpires 0 | Out-Null
                        $LogData += "User $MbrSam has been set with PasswordNeverExpires to $False"
                    }
                }
                Catch {
                    $LogData += "Failed to set password expiration to $mbrSam!"
                }
            }
        }
        #endregion
        #region Create new PSO
        Try {
            new-adFineGrainedPasswordPolicy -ComplexityEnabled 1 `
                                            -Description ((($PSO.Name).Replace('PSO-','PSO for ')).Replace('-',' ')) `
                                            -DisplayName $PSO.Name `
                                            -LockOutDuration "0.0:30:0.0" `
                                            -LockoutObservationWindow "0.0:30:0:0.0" `
                                            -LockoutThreshold 5 `
                                            -MaxPasswordAge $PSO.MaxPwdAge `
                                            -MinPasswordAge "1.0:0:0.0" `
                                            -MinPasswordLength $PSO.PwdLength `
                                            -Name $PSO.Name `
                                            -PasswordHistoryCount 60 `
                                            -Precedence $PSO.Precedence `
                                            -ProtectFromAccidentalDeletion 1 `
                                            -ReversibleEncryptionEnabled 0 `
                                            -OtherAttributes @{'msDS-PSOAppliesTo'=(Get-AdGroup $PSO.Name).distinguishedName}
                                            -ErrorAction Stop | Out-Null

            $LogData += "PSO $($PSO.Name) successfully created."
        }
        Catch {
            $LogData += "PSO $($PSO.Name) could not be created!"
            $FlagRes = "Error"
        }
        #endregion
    }
    # Sending log and leaving with proper exit code
    Write-ToEventLog $FlagRes $LogData
    Return $FlagRes
}
#endregion
