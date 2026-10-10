# What differs per Windows version when New-TestGuest builds a guest and
# Initialize-TestGuest prepares it. Everything else is shared.
#
#   Generation    Hyper-V VM generation. Windows 7 boots only on Generation 1.
#   Tpm           give the VM a virtual TPM (Windows 11 setup checks for one;
#                 the answer file also sets the LabConfig bypass, so a host
#                 that cannot make a key protector still installs).
#   Unattend      answer-file template under unattend\.
#   Transport     how the host reaches the guest: PowerShell Direct needs
#                 Windows 10 / Server 2016 or later inside the guest.
#   Devices       the virtual devices Initialize-TestGuest tries to install.
#                 What a guest really provides is measured afterwards, never
#                 assumed from this list.
#   Download      an evaluation ISO New-TestGuest -DownloadEval may fetch.
#                 Only Windows 11 has one; 7 and 10 need -Iso.
@{
    '11' = @{
        Generation = 2
        Tpm        = $true
        Unattend   = 'win10-11.xml'
        Transport  = 'hyperv'
        Devices    = @('audio', 'display', 'camera')
        Download   = @{
            # Windows 11 Enterprise, 90-day evaluation, en-US, from
            # https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise
            # (the link is on the page; the registration form does not gate it).
            Url  = 'https://go.microsoft.com/fwlink/?LinkId=2382600&clcid=0x409&culture=en-us&country=us'
            Name = 'Win11_EnterpriseEval_x64_en-us.iso'
        }
    }
    '10' = @{
        Generation = 2
        Tpm        = $false
        Unattend   = 'win10-11.xml'
        Transport  = 'hyperv'
        Devices    = @('audio', 'display', 'camera')
        Download   = $null
    }
    '7' = @{
        Generation = 1
        Tpm        = $false
        Unattend   = 'win7.xml'
        Transport  = 'winrm'
        # Indirect display drivers need Windows 10 1607; the audio and camera
        # drivers are untested there. A Windows 7 guest is a driver-free target.
        Devices    = @()
        Download   = $null
    }
}
