Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$defaultInstall = 'C:\Program Files (x86)\The4ThComing'
$configDir  = Join-Path $env:LOCALAPPDATA 'T4CDirectLauncher'
$configPath = Join-Path $configDir 'config.json'

if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Force -Path $configDir | Out-Null }

$defaults = @{
    InstallDir     = $defaultInstall
    Server         = 'Neerya'
    Host           = 'neerya.t4c.com'
    Port           = '12280'
    Account        = ''
    Password       = ''
    Remember       = $false
    RemoteVersion  = ''
    EnabledServers = @()
}
if (Test-Path $configPath) {
    try {
        $saved = Get-Content $configPath -Raw | ConvertFrom-Json
        foreach ($k in @('InstallDir','Server','Host','Port','Account','Password','Remember','RemoteVersion','EnabledServers')) {
            if ($null -ne $saved.$k) { $defaults[$k] = $saved.$k }
        }
        if ($defaults.Password -is [string] -and $defaults.Password.Length -gt 0) {
            try {
                $secure = ConvertTo-SecureString $defaults.Password
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
                $defaults.Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            } catch { $defaults.Password = '' }
        }
    } catch { }
}

function Test-T4CInstall([string]$Dir) {
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    try { return (Test-Path -LiteralPath ([IO.Path]::Combine($Dir, 'T4C Client.bin'))) }
    catch { return $false }
}

function Resolve-T4CInstall {
    foreach ($candidate in @($defaults.InstallDir, $defaultInstall) | Select-Object -Unique) {
        if (Test-T4CInstall $candidate) { return $candidate }
    }
    while ($true) {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = 'Locate T4C Client.bin'
        $dlg.Filter = 'T4C Client (T4C Client.bin)|T4C Client.bin'
        $dlg.CheckFileExists = $true
        if (Test-Path $defaults.InstallDir) { $dlg.InitialDirectory = $defaults.InstallDir }
        elseif (Test-Path 'C:\Program Files (x86)') { $dlg.InitialDirectory = 'C:\Program Files (x86)' }
        if (-not $dlg.ShowDialog()) { return $null }
        $picked = Split-Path $dlg.FileName -Parent
        if (Test-T4CInstall $picked) { return $picked }
        $r = [Windows.MessageBox]::Show(
            "The folder doesn't contain a valid T4C Client.bin.`nTry again?",
            'T4C Direct Launcher', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return $null }
    }
}

$installDir = Resolve-T4CInstall
if (-not $installDir) {
    [Windows.MessageBox]::Show(
        "Cannot continue without locating T4C Client.bin.",
        'T4C Direct Launcher', 'OK', 'Error') | Out-Null
    exit
}
if ($installDir -ne $defaults.InstallDir -or -not (Test-Path $configPath)) {
    $defaults.InstallDir = $installDir
    try {
        $persisted = @{}
        foreach ($k in $defaults.Keys) {
            if ($k -ne 'Password') { $persisted[$k] = $defaults[$k] }
        }
        $persisted.Password = ''
        if (Test-Path $configPath) {
            try {
                $existing = Get-Content $configPath -Raw | ConvertFrom-Json
                if ($existing.Password) { $persisted.Password = $existing.Password }
            } catch { }
        }
        $persisted | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
    } catch { }
}
$defaults.InstallDir = $installDir
$clientPath = Join-Path $installDir 'T4C Client.bin'
$workingDir = $installDir
$iconPath   = Join-Path $installDir 't4c.ico'

function Apply-WatchdogPatch {
    param([string]$Path)
    $patchOffset = 0x147AF0
    $expected = [byte[]](0x0f,0x84,0xed,0x01,0x00,0x00)
    $patched  = [byte[]](0x90,0x90,0x90,0x90,0x90,0x90)

    if (-not (Test-Path $Path)) { return @{ Status='NotFound'; Message='client missing' } }

    try { $bytes = [IO.File]::ReadAllBytes($Path) }
    catch { return @{ Status='Error'; Message=("read failed: " + $_.Exception.Message) } }

    if ($bytes.Length -lt ($patchOffset + 6)) {
        return @{ Status='Unknown'; Message='file too small' }
    }
    $current = $bytes[$patchOffset..($patchOffset + 5)]
    if (-not (Compare-Object $current $patched -SyncWindow 0)) {
        return @{ Status='AlreadyPatched'; Message='watchdog already patched' }
    }
    if (Compare-Object $current $expected -SyncWindow 0) {
        $hex = ($current | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        return @{ Status='Unknown'; Message=("unexpected bytes [$hex] - patch skipped") }
    }

    $bak = "$Path.bak"
    try {
        if (-not (Test-Path $bak)) { Copy-Item -Path $Path -Destination $bak -Force }
    } catch { return @{ Status='Error'; Message=("backup failed: " + $_.Exception.Message) } }

    for ($i = 0; $i -lt 6; $i++) { $bytes[$patchOffset + $i] = $patched[$i] }
    try { [IO.File]::WriteAllBytes($Path, $bytes) }
    catch { return @{ Status='Error'; Message=("write failed: " + $_.Exception.Message) } }

    return @{ Status='Patched'; Message='watchdog patched - backup at .bak' }
}

$patchResult = Apply-WatchdogPatch -Path $clientPath

$webPatchBase = 'https://t4c-world.com/patch/__t4c_update_184__/'
$skipUpdatePaths = @('T4C Client_64.bin')   # no watchdog analysis for 64-bit yet
$clientBinaries  = @('T4C Client.bin')      # handled with special rename/download/patch/revert flow
$watchdogOffset  = 0x147AF0
$watchdogExpect  = [byte[]](0x0f,0x84,0xed,0x01,0x00,0x00)
$watchdogPatch   = [byte[]](0x90,0x90,0x90,0x90,0x90,0x90)

function Get-RemoteUrl([string]$Base, [string]$RelPath) {
    $segments = $RelPath -split '\\' | ForEach-Object { [Uri]::EscapeDataString($_) }
    return $Base.TrimEnd('/') + '/' + ($segments -join '/')
}

function Format-ByteSize([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ("$Bytes B")
}

function Get-LocalServerFolders([string]$InstallDir) {
    $sf = [IO.Path]::Combine($InstallDir, 'Server Files')
    if (-not (Test-Path -LiteralPath $sf)) { return @() }
    return @(Get-ChildItem -LiteralPath $sf -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}

# Shared state between GUI thread and update runspace (synchronized hashtable).
# Defined early so all GUI wiring sees the populated EnabledServers.
$shared = [hashtable]::Synchronized(@{
    AvailableServers = @()
    EnabledServers   = @($defaults.EnabledServers)
    ManifestVersion  = ''
    ServerList       = @()
    ServerListReady  = $false
    UpdateCompleted  = $false
})
if (-not $shared.EnabledServers -or $shared.EnabledServers.Count -eq 0) {
    $shared.EnabledServers = @(Get-LocalServerFolders $installDir)
}

$serverListUrl = 'https://t4c-world.com/launcher/server-list.php'

function Convert-FolderKey([string]$Name) {
    if (-not $Name) { return '' }
    return ($Name -replace '^\[T\]\s*','' -replace '\s+',' ').Trim().ToLower()
}

function Save-RemoteVersion([string]$ConfigPath, [string]$Version) {
    try {
        $existing = @{}
        if (Test-Path $ConfigPath) {
            try { (Get-Content $ConfigPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $existing[$_.Name] = $_.Value } } catch {}
        }
        $existing['RemoteVersion'] = $Version
        $existing | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch {}
}

function Invoke-T4CUpdate {
    param(
        [string]$InstallDir,
        [string]$ConfigPath,
        [string]$LocalVersion,
        [string]$BaseUrl,
        [string[]]$SkipPaths,
        [scriptblock]$Report
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    & $Report @{ Phase='Checking'; Message='checking version' }

    try {
        $remoteVersion = (Invoke-WebRequest -Uri ($BaseUrl + 't4c.version') -UseBasicParsing -TimeoutSec 8).Content
        if ($remoteVersion -is [byte[]]) { $remoteVersion = [Text.Encoding]::UTF8.GetString($remoteVersion) }
        $remoteVersion = $remoteVersion.Trim()
    } catch {
        return @{ Status='Offline'; Message=("offline: " + $_.Exception.Message) }
    }

    if ($LocalVersion -eq $remoteVersion -and -not [string]::IsNullOrEmpty($LocalVersion)) {
        return @{ Status='UpToDate'; Version=$remoteVersion }
    }

    & $Report @{ Phase='Manifest'; Message='fetching manifest' }
    try {
        $hashContent = (Invoke-WebRequest -Uri ($BaseUrl + 't4c.hash') -UseBasicParsing -TimeoutSec 30).Content
        if ($hashContent -is [byte[]]) { $hashContent = [Text.Encoding]::UTF8.GetString($hashContent) }
    } catch {
        return @{ Status='Offline'; Message=("manifest fetch failed: " + $_.Exception.Message) }
    }

    $lines = $hashContent -split '\r?\n' | Where-Object { $_ -ne '' }
    $skippedOutdated = @()
    $mismatches = @()
    $idx = 0; $total = $lines.Count
    foreach ($line in $lines) {
        $idx++
        $parts = $line.Split('|')
        if ($parts.Count -lt 3) { continue }
        $relPath = $parts[0]; $expectedMd5 = $parts[1].ToUpper()
        $localFile = [IO.Path]::Combine($InstallDir, $relPath)
        if ($idx % 25 -eq 0 -or $idx -eq $total) {
            & $Report @{ Phase='Verifying'; Current=$idx; Total=$total; Message=$relPath }
        }
        $needs = $false
        if (-not (Test-Path -LiteralPath $localFile)) { $needs = $true }
        else {
            try {
                $localMd5 = (Get-FileHash -LiteralPath $localFile -Algorithm MD5).Hash
                if ($localMd5 -ne $expectedMd5) { $needs = $true }
            } catch { $needs = $true }
        }
        if ($needs) {
            if ($SkipPaths -contains $relPath) { $skippedOutdated += $relPath }
            else { $mismatches += @{ Path=$relPath; Md5=$expectedMd5 } }
        }
    }

    if ($mismatches.Count -eq 0) {
        Save-RemoteVersion -ConfigPath $ConfigPath -Version $remoteVersion
        return @{ Status='UpToDate'; Version=$remoteVersion; SkippedOutdated=$skippedOutdated }
    }

    $idx = 0; $total = $mismatches.Count
    $failed = @()
    foreach ($m in $mismatches) {
        $idx++
        & $Report @{ Phase='Downloading'; Current=$idx; Total=$total; Message=$m.Path }
        $url = Get-RemoteUrl -Base $BaseUrl -RelPath $m.Path
        $localFile = [IO.Path]::Combine($InstallDir, $m.Path)
        $localDir = [IO.Path]::GetDirectoryName($localFile)
        if (-not (Test-Path -LiteralPath $localDir)) {
            try { New-Item -ItemType Directory -Force -Path $localDir | Out-Null } catch { $failed += $m.Path; continue }
        }
        try {
            $tmp = $localFile + '.partial'
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 120
            $dlMd5 = (Get-FileHash -LiteralPath $tmp -Algorithm MD5).Hash
            if ($dlMd5 -ne $m.Md5) { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue; $failed += $m.Path; continue }
            Move-Item -LiteralPath $tmp -Destination $localFile -Force
        } catch { $failed += $m.Path }
    }

    if ($failed.Count -eq 0) { Save-RemoteVersion -ConfigPath $ConfigPath -Version $remoteVersion }
    return @{
        Status        = if ($failed.Count -eq 0) { 'Updated' } else { 'PartiallyUpdated' }
        Version       = $remoteVersion
        UpdatedCount  = ($mismatches.Count - $failed.Count)
        FailedCount   = $failed.Count
        SkippedOutdated = $skippedOutdated
    }
}

function Build-Args {
    param([string]$Server,[string]$T4CHost,[string]$Port,[string]$Account,[string]$Password,[string]$PName)

    $plain = "-servername:$Server -host:$T4CHost -port:$Port -account:$Account -password:$Password -pname:$PName"

    $key = New-Object byte[] 32
    $iv  = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($key); $rng.GetBytes($iv); $rng.Dispose()

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256; $aes.BlockSize = 128
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $key; $aes.IV = $iv

    $enc = $aes.CreateEncryptor()
    $ptBytes = [Text.Encoding]::UTF8.GetBytes($plain)
    $ct = $enc.TransformFinalBlock($ptBytes, 0, $ptBytes.Length)
    $enc.Dispose(); $aes.Dispose()

    $ctB64  = [Convert]::ToBase64String($ct)
    $ivB64  = [Convert]::ToBase64String($iv)
    $keyB64 = [Convert]::ToBase64String($key)

    function Wrap([string]$s) {
        $lenBytes = [BitConverter]::GetBytes([int]$s.Length)
        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($lenBytes) }
        return [Convert]::ToBase64String($lenBytes) + $s
    }
    return (Wrap $ctB64) + (Wrap $ivB64) + (Wrap $keyB64)
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="T4C Direct Launcher"
        Width="440" Height="640"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize"
        FontFamily="Segoe UI"
        SnapsToDevicePixels="True"
        UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType">

    <Window.Resources>
        <SolidColorBrush x:Key="BgDeep"      Color="#0B0B11"/>
        <SolidColorBrush x:Key="BgPanel"     Color="#15151E"/>
        <SolidColorBrush x:Key="BgInput"     Color="#1A1A24"/>
        <SolidColorBrush x:Key="StrokeSubtle" Color="#2A2A38"/>
        <SolidColorBrush x:Key="StrokeStrong" Color="#3A3A4A"/>
        <SolidColorBrush x:Key="TextPrimary" Color="#ECECF0"/>
        <SolidColorBrush x:Key="TextMuted"   Color="#7E7E8C"/>
        <SolidColorBrush x:Key="TextLabel"   Color="#9A9AA8"/>
        <SolidColorBrush x:Key="Gold"        Color="#C8A55B"/>
        <SolidColorBrush x:Key="GoldSoft"    Color="#8A7340"/>
        <SolidColorBrush x:Key="GoldHover"   Color="#D9B66E"/>
        <SolidColorBrush x:Key="Danger"      Color="#C24A4A"/>

        <LinearGradientBrush x:Key="WindowGradient" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#13131C" Offset="0"/>
            <GradientStop Color="#0B0B11" Offset="1"/>
        </LinearGradientBrush>

        <LinearGradientBrush x:Key="GoldGradient" StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#D9B66E" Offset="0"/>
            <GradientStop Color="#B89148" Offset="1"/>
        </LinearGradientBrush>

        <LinearGradientBrush x:Key="GoldGradientHover" StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#E6C684" Offset="0"/>
            <GradientStop Color="#C9A458" Offset="1"/>
        </LinearGradientBrush>

        <Style x:Key="FieldLabel" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextLabel}"/>
            <Setter Property="FontSize" Value="10"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Margin" Value="0,0,0,6"/>
        </Style>

        <Style x:Key="FancyTextBox" TargetType="TextBox">
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="CaretBrush" Value="{StaticResource Gold}"/>
            <Setter Property="SelectionBrush" Value="{StaticResource GoldSoft}"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Padding" Value="12,10"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Background" Value="{StaticResource BgInput}"/>
            <Setter Property="BorderBrush" Value="{StaticResource StrokeSubtle}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="Bd"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6">
                            <ScrollViewer x:Name="PART_ContentHost"
                                          Margin="{TemplateBinding Padding}"
                                          VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource StrokeStrong}"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Gold}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="FancyComboItem" TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Padding" Value="12,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="ItBd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="ItBd" Property="Background" Value="#22222E"/>
                                <Setter Property="Foreground" Value="{StaticResource Gold}"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="ItBd" Property="Background" Value="#1A1A24"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="FancyComboBox" TargetType="ComboBox">
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="Background" Value="{StaticResource BgInput}"/>
            <Setter Property="BorderBrush" Value="{StaticResource StrokeSubtle}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Padding" Value="12,10"/>
            <Setter Property="IsEditable" Value="True"/>
            <Setter Property="ItemContainerStyle" Value="{StaticResource FancyComboItem}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6"/>
                            <ToggleButton x:Name="DropDown" Focusable="False" Background="Transparent"
                                          BorderThickness="0" ClickMode="Press"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Grid Background="Transparent">
                                            <Path x:Name="Arrow" Data="M 0,0 L 4,4 L 8,0 Z"
                                                  Fill="{StaticResource TextMuted}"
                                                  HorizontalAlignment="Right" VerticalAlignment="Center"
                                                  Margin="0,0,12,0" Width="8" Height="4"/>
                                        </Grid>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="Arrow" Property="Fill" Value="{StaticResource Gold}"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <TextBox x:Name="PART_EditableTextBox" Margin="{TemplateBinding Padding}"
                                     Background="Transparent" BorderThickness="0"
                                     Foreground="{TemplateBinding Foreground}"
                                     CaretBrush="{StaticResource Gold}"
                                     SelectionBrush="{StaticResource GoldSoft}"
                                     VerticalAlignment="Center"
                                     IsReadOnly="{TemplateBinding IsReadOnly}"
                                     Focusable="True">
                                <TextBox.Template>
                                    <ControlTemplate TargetType="TextBox">
                                        <ScrollViewer x:Name="PART_ContentHost"/>
                                    </ControlTemplate>
                                </TextBox.Template>
                            </TextBox>
                            <Popup x:Name="PART_Popup"
                                   Placement="Bottom"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                                <Border Background="#15151E"
                                        BorderBrush="{StaticResource StrokeStrong}"
                                        BorderThickness="1" CornerRadius="6"
                                        MinWidth="{TemplateBinding ActualWidth}"
                                        MaxHeight="240"
                                        Margin="0,4,0,0">
                                    <Border.Effect>
                                        <DropShadowEffect Color="Black" BlurRadius="14" ShadowDepth="0" Opacity="0.5"/>
                                    </Border.Effect>
                                    <ScrollViewer SnapsToDevicePixels="True">
                                        <StackPanel IsItemsHost="True"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource StrokeStrong}"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Gold}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="FancyPasswordBox" TargetType="PasswordBox">
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="CaretBrush" Value="{StaticResource Gold}"/>
            <Setter Property="SelectionBrush" Value="{StaticResource GoldSoft}"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Padding" Value="12,10"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Background" Value="{StaticResource BgInput}"/>
            <Setter Property="BorderBrush" Value="{StaticResource StrokeSubtle}"/>
            <Setter Property="PasswordChar" Value="&#x25CF;"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border x:Name="Bd"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6">
                            <ScrollViewer x:Name="PART_ContentHost"
                                          Margin="{TemplateBinding Padding}"
                                          VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource StrokeStrong}"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Gold}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ChromeButton" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Width" Value="34"/>
            <Setter Property="Height" Value="28"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#22222E"/>
                                <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="CloseButton" TargetType="Button" BasedOn="{StaticResource ChromeButton}">
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#3A1F1F"/>
                    <Setter Property="Foreground" Value="{StaticResource Danger}"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="LaunchButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource GoldGradient}"/>
            <Setter Property="Foreground" Value="#1A1408"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Height" Value="46"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd"
                                Background="{TemplateBinding Background}"
                                CornerRadius="8">
                            <Border.Effect>
                                <DropShadowEffect Color="#C8A55B" BlurRadius="14" ShadowDepth="0" Opacity="0.25"/>
                            </Border.Effect>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource GoldGradientHover}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource GoldSoft}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="GoldCheckBox" TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal">
                            <Border x:Name="Box"
                                    Width="16" Height="16"
                                    Background="{StaticResource BgInput}"
                                    BorderBrush="{StaticResource StrokeStrong}"
                                    BorderThickness="1"
                                    CornerRadius="3"
                                    VerticalAlignment="Center">
                                <Path x:Name="Check"
                                      Data="M 3,8 L 7,12 L 13,4"
                                      Stroke="{StaticResource Gold}"
                                      StrokeThickness="2"
                                      StrokeStartLineCap="Round"
                                      StrokeEndLineCap="Round"
                                      Visibility="Collapsed"/>
                            </Border>
                            <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Check" Property="Visibility" Value="Visible"/>
                                <Setter TargetName="Box"   Property="BorderBrush" Value="{StaticResource Gold}"/>
                                <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource GoldHover}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border Background="{StaticResource WindowGradient}"
            BorderBrush="{StaticResource StrokeSubtle}"
            BorderThickness="1"
            CornerRadius="12">
        <Border.Effect>
            <DropShadowEffect Color="Black" BlurRadius="20" ShadowDepth="0" Opacity="0.6"/>
        </Border.Effect>

        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- Title bar -->
            <Border x:Name="TitleBar" Grid.Row="0" Background="Transparent" Padding="20,14,12,10">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="&#x2694;" Foreground="{StaticResource Gold}" FontSize="22"
                                   VerticalAlignment="Center" Margin="0,0,12,0"/>
                        <StackPanel>
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="T4C" Foreground="{StaticResource TextPrimary}"
                                           FontSize="16" FontWeight="Bold" Margin="0,0,8,0"/>
                                <TextBlock Text="THE 4TH COMING" Foreground="{StaticResource TextMuted}"
                                           FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"
                                           Padding="6,2" Background="#1A1A24"/>
                            </StackPanel>
                            <TextBlock Text="Direct Launcher" Foreground="{StaticResource TextMuted}"
                                       FontSize="10" Margin="0,2,0,0"/>
                        </StackPanel>
                    </StackPanel>

                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
                        <Button x:Name="BtnAbout" Content="?" Style="{StaticResource ChromeButton}"
                                ToolTip="Why this launcher exists"/>
                        <Button x:Name="BtnClose" Content="&#x2715;" Style="{StaticResource CloseButton}"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- Content -->
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Disabled" Padding="0">
                <StackPanel Margin="28,8,28,24">

                    <!-- Server -->
                    <TextBlock Text="SERVER NAME" Style="{StaticResource FieldLabel}"/>
                    <ComboBox x:Name="CbServer" Style="{StaticResource FancyComboBox}"/>

                    <!-- Host + Port -->
                    <Grid Margin="0,16,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="14"/>
                            <ColumnDefinition Width="110"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="HOST" Style="{StaticResource FieldLabel}"/>
                        <TextBlock Grid.Row="0" Grid.Column="2" Text="PORT" Style="{StaticResource FieldLabel}"/>
                        <TextBox x:Name="TbHost" Grid.Row="1" Grid.Column="0" Style="{StaticResource FancyTextBox}"/>
                        <TextBox x:Name="TbPort" Grid.Row="1" Grid.Column="2" Style="{StaticResource FancyTextBox}"/>
                    </Grid>

                    <!-- Account -->
                    <TextBlock Text="ACCOUNT" Style="{StaticResource FieldLabel}" Margin="0,16,0,6"/>
                    <TextBox x:Name="TbAccount" Style="{StaticResource FancyTextBox}"/>

                    <!-- Password -->
                    <TextBlock Text="PASSWORD" Style="{StaticResource FieldLabel}" Margin="0,16,0,6"/>
                    <PasswordBox x:Name="PbPassword" Style="{StaticResource FancyPasswordBox}"/>

                    <!-- Remember -->
                    <CheckBox x:Name="CbRemember" Content="Remember credentials (DPAPI encrypted)"
                              Style="{StaticResource GoldCheckBox}" Margin="0,22,0,0"/>

                    <!-- Server packs row -->
                    <Grid Margin="0,12,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" VerticalAlignment="Center" FontSize="12">
                            <Run Text="Server packs " Foreground="#9A9AA8"/>
                            <Run x:Name="RunServerCount" Text="0 enabled" Foreground="#7E7E8C"/>
                        </TextBlock>
                        <Button x:Name="BtnServerPicker" Grid.Column="1" Content="Manage"
                                Background="Transparent" BorderThickness="1" BorderBrush="#3A3A4A"
                                Foreground="#9A9AA8" FontSize="11" Padding="12,4" Cursor="Hand">
                            <Button.Template>
                                <ControlTemplate TargetType="Button">
                                    <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                            BorderBrush="{TemplateBinding BorderBrush}"
                                            BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                                        <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="Bd" Property="BorderBrush" Value="#C8A55B"/>
                                            <Setter Property="Foreground" Value="#ECECF0"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Button.Template>
                        </Button>
                    </Grid>

                    <!-- Launch button -->
                    <Button x:Name="BtnLaunch" Style="{StaticResource LaunchButton}" Margin="0,24,0,0"
                            IsEnabled="False">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="LAUNCH GAME" Margin="0,0,10,0" VerticalAlignment="Center"
                                       FontFamily="Segoe UI" FontWeight="Bold"/>
                            <TextBlock Text="&#x25B6;" FontSize="11" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Button>

                    <!-- Footer hint -->
                    <TextBlock x:Name="TxtStatus" Text=""
                               Foreground="#5A5A66" FontSize="10" TextAlignment="Center"
                               TextWrapping="Wrap" Margin="0,16,0,0"/>
                </StackPanel>
            </ScrollViewer>
        </Grid>
    </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Window icon
if (Test-Path $iconPath) {
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit(); $bmp.UriSource = New-Object System.Uri ($iconPath)
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        $window.Icon = $bmp
    } catch { }
}

# Resolve named controls
$titleBar = $window.FindName('TitleBar')
$btnClose = $window.FindName('BtnClose')
$btnAbout = $window.FindName('BtnAbout')
$cbServer = $window.FindName('CbServer')
$tbHost   = $window.FindName('TbHost')
$tbPort   = $window.FindName('TbPort')
$tbAcct   = $window.FindName('TbAccount')
$pbPass   = $window.FindName('PbPassword')
$cbRemem  = $window.FindName('CbRemember')
$btnLaunch = $window.FindName('BtnLaunch')
$txtStatus = $window.FindName('TxtStatus')
$btnServerPicker = $window.FindName('BtnServerPicker')
$runServerCount  = $window.FindName('RunServerCount')

function Update-ServerCountLabel {
    $n = @($shared.EnabledServers).Count
    if ($n -eq 0) {
        $runServerCount.Text = '0 enabled'
    } else {
        $names = @($shared.EnabledServers | Sort-Object)
        if ($n -le 2) { $runServerCount.Text = "$n enabled - " + ($names -join ', ') }
        else { $runServerCount.Text = "$n enabled - " + ($names[0..1] -join ', ') + ", +$($n-2)" }
    }
}
Update-ServerCountLabel

function Invoke-ServerPicker {
    $result = Show-ServerPicker -Owner $window -Available $shared.AvailableServers `
                                -Enabled $shared.EnabledServers -LocalInstallDir $installDir
    if ($result.Changed) {
        $shared.EnabledServers = @($result.Servers)
        Save-EnabledServers -Path $configPath -Servers $shared.EnabledServers
        # Invalidate saved version so the verify pass actually runs against the new selection
        Save-RemoteVersion -ConfigPath $configPath -Version ''
        $defaults.RemoteVersion = ''
        Update-ServerCountLabel
        Show-Status 'server selection changed - rechecking...' '#9A9AA8'
        Start-UpdateRunspace
    }
}

$btnServerPicker.Add_Click({
    if ((@($shared.AvailableServers)).Count -gt 0) {
        Invoke-ServerPicker
        return
    }
    # Manifest not yet fetched -- wait up to 8s on a non-blocking timer
    $btnServerPicker.IsEnabled = $false
    Show-Status 'loading server list...' '#9A9AA8'
    $waitTimer = New-Object System.Windows.Threading.DispatcherTimer
    $waitTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $deadline = [DateTime]::Now.AddSeconds(8)
    $waitTimer.Add_Tick({
        $ready = (@($shared.AvailableServers)).Count -gt 0
        if ($ready -or [DateTime]::Now -ge $deadline) {
            $waitTimer.Stop()
            $btnServerPicker.IsEnabled = $true
            if ($ready) { Show-Status '' '#5A5A66'; Invoke-ServerPicker }
            else { Show-Status 'manifest unavailable - showing local folders only' '#C29A4A'; Invoke-ServerPicker }
        }
    })
    $waitTimer.Start()
})

# Defaults
$tbHost.Text   = $defaults.Host
$tbPort.Text   = $defaults.Port
$tbAcct.Text   = $defaults.Account
$pbPass.Password = $defaults.Password
$cbRemem.IsChecked = [bool]$defaults.Remember

# Initial dropdown population from local folders (server-list fetch will refine later)
foreach ($folder in (Get-LocalServerFolders $installDir)) {
    $cbi = New-Object System.Windows.Controls.ComboBoxItem
    $cbi.Content = $folder
    $cbi.Tag = @{ Name=$folder; Host=''; Port=''; FolderKey=$folder.ToLower() }
    [void]$cbServer.Items.Add($cbi)
}
$cbServer.Text = $defaults.Server

$cbServer.Add_SelectionChanged({
    $sel = $cbServer.SelectedItem
    if ($sel -and $sel.Tag -is [hashtable]) {
        if ($sel.Tag.Host) { $tbHost.Text = $sel.Tag.Host }
        if ($sel.Tag.Port) { $tbPort.Text = $sel.Tag.Port }
    }
})

function Refresh-ServerDropdownFromShared {
    $current = $cbServer.Text
    $localFolders = @(Get-LocalServerFolders $installDir | ForEach-Object { $_.ToLower() })
    $folderSet = @{}
    foreach ($f in $localFolders) { $folderSet[$f] = $true }

    $picks = @()
    foreach ($s in $shared.ServerList) {
        if ($s.Name -match '^\[T\]') { continue }   # skip test-only variants
        if ($folderSet[$s.FolderKey]) { $picks += $s }
    }
    $picks = @($picks | Sort-Object Name)

    $cbServer.Items.Clear()
    foreach ($p in $picks) {
        $cbi = New-Object System.Windows.Controls.ComboBoxItem
        $cbi.Content = $p.Name
        $cbi.Tag = @{ Name=$p.Name; Host=$p.Host; Port=$p.Port; FolderKey=$p.FolderKey }
        [void]$cbServer.Items.Add($cbi)
    }
    $cbServer.Text = $current
}

# Poll shared signals from UI thread instead of cross-thread script-block dispatch
$timerState = @{ ServerListConsumed = $false }
$dropdownTimer = New-Object System.Windows.Threading.DispatcherTimer
$dropdownTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$dropdownTimer.Add_Tick({
    $refresh = $false
    if ($shared.ServerListReady -and -not $timerState.ServerListConsumed) {
        $timerState.ServerListConsumed = $true
        $refresh = $true
    }
    if ($shared.UpdateCompleted) {
        $shared.UpdateCompleted = $false
        $refresh = $true
    }
    if ($refresh) { Refresh-ServerDropdownFromShared }
})
$dropdownTimer.Start()

# Drag the window from the title bar
$titleBar.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch {} })

# Close button
$btnClose.Add_Click({ $window.Close() })
$btnAbout.Add_Click({ Show-AboutDialog -Owner $window })

# Esc to close
$window.Add_KeyDown({
    param($s,$e)
    if ($e.Key -eq 'Escape') { $window.Close() }
    elseif ($e.Key -eq 'Enter' -and $btnLaunch.IsEnabled) { $btnLaunch.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent))) }
})

function Show-Status([string]$msg, [string]$color) {
    $txtStatus.Text = $msg
    $txtStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($color))
}

function Save-EnabledServers([string]$Path, [string[]]$Servers) {
    try {
        $existing = @{}
        if (Test-Path $Path) {
            try { (Get-Content $Path -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $existing[$_.Name] = $_.Value } } catch {}
        }
        $existing['EnabledServers'] = @($Servers)
        $existing | ConvertTo-Json | Set-Content -Path $Path -Encoding UTF8
    } catch {}
}

function Show-ServerPicker {
    param(
        [object]$Owner,
        [array]$Available,
        [string[]]$Enabled,
        [string]$LocalInstallDir
    )

    # Build a unified list: anything in $Available, plus locally-present folders
    # not yet in the manifest (so user can disable an old folder).
    $byName = @{}
    foreach ($s in $Available) {
        $byName[$s.Name] = @{ Name=$s.Name; FileCount=[int]$s.FileCount; TotalSize=[long]$s.TotalSize; Source='manifest' }
    }
    foreach ($n in (Get-LocalServerFolders $LocalInstallDir)) {
        if (-not $byName.ContainsKey($n)) {
            $byName[$n] = @{ Name=$n; FileCount=0; TotalSize=0L; Source='local-only' }
        }
    }
    $items = @($byName.Values | Sort-Object Name)
    if ($items.Count -eq 0) { return @{ Changed = $false; Servers = $Enabled } }

    [xml]$pickerXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Server packs"
        Width="400" Height="500"
        WindowStartupLocation="CenterOwner"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize"
        FontFamily="Segoe UI"
        SnapsToDevicePixels="True"
        UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType">
    <Window.Resources>
        <SolidColorBrush x:Key="BgPanel"      Color="#15151E"/>
        <SolidColorBrush x:Key="BgInput"      Color="#1A1A24"/>
        <SolidColorBrush x:Key="StrokeSubtle" Color="#2A2A38"/>
        <SolidColorBrush x:Key="StrokeStrong" Color="#3A3A4A"/>
        <SolidColorBrush x:Key="TextPrimary"  Color="#ECECF0"/>
        <SolidColorBrush x:Key="TextMuted"    Color="#7E7E8C"/>
        <SolidColorBrush x:Key="TextLabel"    Color="#9A9AA8"/>
        <SolidColorBrush x:Key="Gold"         Color="#C8A55B"/>
        <SolidColorBrush x:Key="GoldSoft"     Color="#8A7340"/>
        <SolidColorBrush x:Key="GoldHover"    Color="#D9B66E"/>
        <SolidColorBrush x:Key="Danger"       Color="#C24A4A"/>
        <LinearGradientBrush x:Key="WindowGradient" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#13131C" Offset="0"/>
            <GradientStop Color="#0B0B11" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="GoldGradient" StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#D9B66E" Offset="0"/>
            <GradientStop Color="#B89148" Offset="1"/>
        </LinearGradientBrush>
        <Style x:Key="ChromeButton" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Width" Value="34"/><Setter Property="Height" Value="28"/>
            <Setter Property="FontSize" Value="13"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#3A1F1F"/>
                                <Setter Property="Foreground" Value="{StaticResource Danger}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="GoldCheckBox" TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal">
                            <Border x:Name="Box" Width="16" Height="16"
                                    Background="{StaticResource BgInput}"
                                    BorderBrush="{StaticResource StrokeStrong}"
                                    BorderThickness="1" CornerRadius="3"
                                    VerticalAlignment="Center">
                                <Path x:Name="Check" Data="M 3,8 L 7,12 L 13,4"
                                      Stroke="{StaticResource Gold}" StrokeThickness="2"
                                      StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                                      Visibility="Collapsed"/>
                            </Border>
                            <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Check" Property="Visibility" Value="Visible"/>
                                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Gold}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource GoldHover}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="OkButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource GoldGradient}"/>
            <Setter Property="Foreground" Value="#1A1408"/>
            <Setter Property="FontSize" Value="12"/><Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="20,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6">
                            <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="GhostButton" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
            <Setter Property="FontSize" Value="12"/><Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="{StaticResource StrokeStrong}"/>
            <Setter Property="Padding" Value="20,8"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Gold}"/>
                                <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Border Background="{StaticResource WindowGradient}" BorderBrush="{StaticResource StrokeSubtle}"
            BorderThickness="1" CornerRadius="12">
        <Border.Effect>
            <DropShadowEffect Color="Black" BlurRadius="20" ShadowDepth="0" Opacity="0.6"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border x:Name="TitleBar" Grid.Row="0" Background="Transparent" Padding="22,16,12,4">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel>
                        <TextBlock Text="SERVER PACKS" Foreground="{StaticResource TextLabel}" FontSize="10" FontWeight="SemiBold"/>
                        <TextBlock Text="Select which server data to keep updated"
                                   Foreground="{StaticResource TextMuted}" FontSize="11" Margin="0,2,0,0"/>
                    </StackPanel>
                    <Button x:Name="BtnPickerClose" Grid.Column="1" Content="&#x2715;" Style="{StaticResource ChromeButton}"
                            VerticalAlignment="Top"/>
                </Grid>
            </Border>
            <ScrollViewer Grid.Row="1" Margin="22,12,22,12" VerticalScrollBarVisibility="Auto">
                <ItemsControl x:Name="LbServers"/>
            </ScrollViewer>
            <Grid Grid.Row="2" Margin="22,8,22,22">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="TxtSummary" Foreground="{StaticResource TextMuted}" FontSize="11"
                           VerticalAlignment="Center" Grid.Column="0"/>
                <Button x:Name="BtnCancel" Grid.Column="2" Content="Cancel" Style="{StaticResource GhostButton}"/>
                <Button x:Name="BtnOk" Grid.Column="4" Content="OK" Style="{StaticResource OkButton}"/>
            </Grid>
        </Grid>
    </Border>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader $pickerXaml
    $dlg = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { $dlg.Owner = $Owner }
    $titleBar  = $dlg.FindName('TitleBar')
    $btnPickerClose = $dlg.FindName('BtnPickerClose')
    $lb        = $dlg.FindName('LbServers')
    $btnOk     = $dlg.FindName('BtnOk')
    $btnCancel = $dlg.FindName('BtnCancel')
    $txtSummary = $dlg.FindName('TxtSummary')

    $titleBar.Add_MouseLeftButtonDown({ try { $dlg.DragMove() } catch {} })
    $btnPickerClose.Add_Click({ $dlg.Tag = 'cancel'; $dlg.Close() })
    $btnCancel.Add_Click({ $dlg.Tag = 'cancel'; $dlg.Close() })

    $checks = @{}
    $totalChecked = [ref]0
    $totalCheckedSize = [ref]([long]0)
    function Refresh-Summary {
        $n = $totalChecked.Value
        $sz = $totalCheckedSize.Value
        if ($n -eq 0) { $txtSummary.Text = 'nothing selected' }
        else { $txtSummary.Text = "$n selected - " + (Format-ByteSize $sz) }
    }

    $enabledLookup = @{}
    foreach ($s in $Enabled) { $enabledLookup[$s] = $true }

    foreach ($it in $items) {
        $row = New-Object Windows.Controls.Grid
        $row.Margin = '0,4,0,4'
        $row.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))
        $row.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))

        $cb = New-Object Windows.Controls.CheckBox
        $cb.Style = $dlg.Resources['GoldCheckBox']
        $cb.Content = $it.Name
        $cb.Tag = $it
        $cb.IsChecked = [bool]$enabledLookup[$it.Name]

        $tbSize = New-Object Windows.Controls.TextBlock
        $tbSize.Foreground = $dlg.Resources['TextMuted']
        $tbSize.FontSize = 11
        $tbSize.VerticalAlignment = 'Center'
        if ($it.Source -eq 'local-only') { $tbSize.Text = '(local only)' }
        elseif ($it.TotalSize -gt 0) { $tbSize.Text = (Format-ByteSize $it.TotalSize) + " - $($it.FileCount) files" }
        else { $tbSize.Text = "$($it.FileCount) files" }
        [Windows.Controls.Grid]::SetColumn($tbSize, 1)

        if ($cb.IsChecked) {
            $totalChecked.Value++
            $totalCheckedSize.Value += [long]$it.TotalSize
        }

        $cb.Add_Checked({
            param($s,$e)
            $totalChecked.Value++
            $totalCheckedSize.Value += [long]$s.Tag.TotalSize
            Refresh-Summary
        }.GetNewClosure())
        $cb.Add_Unchecked({
            param($s,$e)
            $totalChecked.Value--
            $totalCheckedSize.Value -= [long]$s.Tag.TotalSize
            Refresh-Summary
        }.GetNewClosure())

        $row.Children.Add($cb) | Out-Null
        $row.Children.Add($tbSize) | Out-Null
        $checks[$it.Name] = $cb
        $lb.Items.Add($row) | Out-Null
    }
    Refresh-Summary

    $btnOk.Add_Click({
        $picked = @()
        foreach ($k in $checks.Keys) { if ($checks[$k].IsChecked) { $picked += $k } }
        $dlg.Tag = $picked
        $dlg.Close()
    })

    $dlg.Add_KeyDown({
        param($s,$e)
        if ($e.Key -eq 'Escape') { $s.Tag = 'cancel'; $s.Close() }
    })

    [void]$dlg.ShowDialog()

    if ($dlg.Tag -eq 'cancel' -or $dlg.Tag -eq $null) {
        return @{ Changed = $false; Servers = $Enabled }
    }
    $newSet = @($dlg.Tag)
    $oldSorted = ($Enabled | Sort-Object) -join '|'
    $newSorted = ($newSet | Sort-Object) -join '|'
    return @{ Changed = ($oldSorted -ne $newSorted); Servers = $newSet }
}

function Show-AboutDialog {
    param([object]$Owner)

    [xml]$aboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="About"
        Width="460" Height="500"
        WindowStartupLocation="CenterOwner"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize"
        FontFamily="Segoe UI"
        SnapsToDevicePixels="True"
        UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType">
    <Window.Resources>
        <SolidColorBrush x:Key="TextPrimary"  Color="#ECECF0"/>
        <SolidColorBrush x:Key="TextMuted"    Color="#7E7E8C"/>
        <SolidColorBrush x:Key="TextLabel"    Color="#9A9AA8"/>
        <SolidColorBrush x:Key="StrokeSubtle" Color="#2A2A38"/>
        <SolidColorBrush x:Key="StrokeStrong" Color="#3A3A4A"/>
        <SolidColorBrush x:Key="Gold"         Color="#C8A55B"/>
        <SolidColorBrush x:Key="Danger"       Color="#C24A4A"/>
        <LinearGradientBrush x:Key="WindowGradient" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#13131C" Offset="0"/>
            <GradientStop Color="#0B0B11" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="GoldGradient" StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#D9B66E" Offset="0"/>
            <GradientStop Color="#B89148" Offset="1"/>
        </LinearGradientBrush>
        <Style x:Key="ChromeBtn" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Width" Value="34"/><Setter Property="Height" Value="28"/>
            <Setter Property="FontSize" Value="13"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#3A1F1F"/>
                                <Setter Property="Foreground" Value="{StaticResource Danger}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="OkBtn" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource GoldGradient}"/>
            <Setter Property="Foreground" Value="#1A1408"/>
            <Setter Property="FontSize" Value="12"/><Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="22,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="6">
                            <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="BulletPara" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="Margin" Value="0,0,0,10"/>
        </Style>
    </Window.Resources>
    <Border Background="{StaticResource WindowGradient}" BorderBrush="{StaticResource StrokeSubtle}"
            BorderThickness="1" CornerRadius="12">
        <Border.Effect>
            <DropShadowEffect Color="Black" BlurRadius="20" ShadowDepth="0" Opacity="0.6"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border x:Name="AboutTitleBar" Grid.Row="0" Background="Transparent" Padding="22,16,12,4">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel>
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#x2694;" Foreground="{StaticResource Gold}" FontSize="18"
                                       VerticalAlignment="Center" Margin="0,0,10,0"/>
                            <TextBlock Text="WHY THIS LAUNCHER" Foreground="{StaticResource TextLabel}"
                                       FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center"/>
                        </StackPanel>
                        <TextBlock Text="An alternative to t4c.exe that respects your machine"
                                   Foreground="{StaticResource TextMuted}" FontSize="11" Margin="0,4,0,0"/>
                    </StackPanel>
                    <Button x:Name="AboutClose" Grid.Column="1" Content="&#x2715;" Style="{StaticResource ChromeBtn}"
                            VerticalAlignment="Top"/>
                </Grid>
            </Border>
            <ScrollViewer Grid.Row="1" Margin="22,12,22,12" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                    <TextBlock Style="{StaticResource BulletPara}">
                        <Run Foreground="#C8A55B" FontWeight="Bold">The original launcher (t4c.exe)</Run>
                        <Run xml:space="preserve"> does two things it shouldn't do:</Run>
                    </TextBlock>
                    <TextBlock Style="{StaticResource BulletPara}">
                        <Run Foreground="#C8A55B" FontWeight="Bold">1. It scans your files.</Run>
                        <Run xml:space="preserve">  It inspects the contents of other processes and files on your PC under the banner of "anti-cheat", without saying what it collects or where it goes.</Run>
                    </TextBlock>
                    <TextBlock Style="{StaticResource BulletPara}">
                        <Run Foreground="#C8A55B" FontWeight="Bold">2. It kills your processes.</Run>
                        <Run xml:space="preserve">  The client (T4C Client.bin) runs a watchdog thread that, every 5 seconds, enumerates your Windows processes and calls ExitProcess on itself if t4c.exe is not there. There is no legitimate technical reason to require the launcher to keep running for the game to work.</Run>
                    </TextBlock>
                    <TextBlock Style="{StaticResource BulletPara}">
                        <Run Foreground="#ECECF0" xml:space="preserve">This launcher does the essentials -- login, updates, starting the client -- without any of that:</Run>
                    </TextBlock>
                    <TextBlock Style="{StaticResource BulletPara}" Margin="12,0,0,10">
                        <Run Foreground="#C8A55B">-</Run>
                        <Run xml:space="preserve">  no scanning of third-party processes or files</Run>
                    </TextBlock>
                    <TextBlock Style="{StaticResource BulletPara}" Margin="12,0,0,10">
                        <Run Foreground="#C8A55B">-</Run>
                        <Run xml:space="preserve">  local 6-byte patch of the watchdog in T4C Client.bin (with reversible .bak backup)</Run>
                    </TextBlock>
                    <TextBlock Style="{StaticResource BulletPara}" Margin="12,0,0,10">
                        <Run Foreground="#C8A55B">-</Run>
                        <Run xml:space="preserve">  same official update mechanism (t4c.hash + t4c.version via t4c-world.com)</Run>
                    </TextBlock>
                    <TextBlock Style="{StaticResource BulletPara}" Margin="12,0,0,10">
                        <Run Foreground="#C8A55B">-</Run>
                        <Run xml:space="preserve">  credentials encrypted with Windows DPAPI (tied to your Windows account only)</Run>
                    </TextBlock>
                    <TextBlock Style="{StaticResource BulletPara}" Margin="0,12,0,0">
                        <Run Foreground="#C8A55B" FontWeight="Bold">Open source, nothing to hide.</Run>
                        <Run Foreground="#7E7E8C" FontStyle="Italic" xml:space="preserve">  Every line lives in t4c-direct.ps1 -- read it, audit it, change it.</Run>
                    </TextBlock>
                </StackPanel>
            </ScrollViewer>
            <Grid Grid.Row="2" Margin="22,8,22,22">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="AboutOk" Grid.Column="1" Content="OK" Style="{StaticResource OkBtn}"/>
            </Grid>
        </Grid>
    </Border>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader $aboutXaml
    $dlg = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { $dlg.Owner = $Owner }
    $tb       = $dlg.FindName('AboutTitleBar')
    $btnX     = $dlg.FindName('AboutClose')
    $btnOk    = $dlg.FindName('AboutOk')
    $tb.Add_MouseLeftButtonDown({ try { $dlg.DragMove() } catch {} })
    $btnX.Add_Click({ $dlg.Close() })
    $btnOk.Add_Click({ $dlg.Close() })
    $dlg.Add_KeyDown({ param($s,$e) if ($e.Key -eq 'Escape' -or $e.Key -eq 'Enter') { $s.Close() } })
    [void]$dlg.ShowDialog()
}

switch ($patchResult.Status) {
    'Patched' { Show-Status $patchResult.Message '#C8A55B' }
    'Unknown' { Show-Status ($patchResult.Message + ' (running with -pname fallback)') '#C29A4A' }
    'NotFound' { Show-Status $patchResult.Message '#C24A4A' }
    'Error'   { Show-Status ('patch error: ' + $patchResult.Message) '#C24A4A' }
}

$btnLaunch.Add_Click({
    $missing = @()
    foreach ($p in @(@($cbServer,'Server name'),@($tbHost,'Host'),@($tbPort,'Port'),@($tbAcct,'Account'))) {
        if ([string]::IsNullOrWhiteSpace($p[0].Text)) { $missing += $p[1] }
    }
    if ([string]::IsNullOrWhiteSpace($pbPass.Password)) { $missing += 'Password' }
    if ($missing.Count -gt 0) {
        Show-Status ("Missing: {0}" -f ($missing -join ', ')) '#C24A4A'
        return
    }
    if (-not (Test-Path $clientPath)) {
        Show-Status "Client not found at $clientPath" '#C24A4A'
        return
    }

    $cfg = @{
        InstallDir     = $installDir
        Server         = $cbServer.Text
        Host           = $tbHost.Text
        Port           = $tbPort.Text
        Account        = $tbAcct.Text
        Remember       = [bool]$cbRemem.IsChecked
        EnabledServers = @($shared.EnabledServers)
    }
    if ($cbRemem.IsChecked) {
        $secure = ConvertTo-SecureString $pbPass.Password -AsPlainText -Force
        $cfg.Password = ConvertFrom-SecureString $secure
    } else {
        $cfg.Password = ''
    }
    try { $cfg | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8 } catch { }

    try {
        $clientArgs = Build-Args -Server $cbServer.Text -T4CHost $tbHost.Text -Port $tbPort.Text `
                                 -Account $tbAcct.Text -Password $pbPass.Password -PName 'explorer.exe'
    } catch {
        Show-Status ("Encryption failed: {0}" -f $_.Exception.Message) '#C24A4A'
        return
    }

    Show-Status "Launching..." '#C8A55B'
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $clientPath
        $psi.Arguments = $clientArgs
        $psi.WorkingDirectory = $workingDir
        $psi.UseShellExecute = $false
        [void][System.Diagnostics.Process]::Start($psi)
        $window.Close()
    } catch {
        Show-Status ("Launch failed: {0}" -f $_.Exception.Message) '#C24A4A'
    }
})

# Initial focus
if ([string]::IsNullOrEmpty($tbAcct.Text)) { $tbAcct.Focus() | Out-Null }
elseif ([string]::IsNullOrEmpty($pbPass.Password)) { $pbPass.Focus() | Out-Null }
else { $btnLaunch.Focus() | Out-Null }

$updateScript = {
    function Set-Footer([string]$msg, [string]$color) {
        $canLaunch = ($msg -match '^(up to date|updated )')
        $Window.Dispatcher.Invoke([Action]{
            $TxtStatus.Text = $msg
            $TxtStatus.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($color))
            $BtnLaunch.IsEnabled = $canLaunch
        })
    }

    function Get-RemoteUrl([string]$Base, [string]$RelPath) {
        $segments = $RelPath -split '\\' | ForEach-Object { [Uri]::EscapeDataString($_) }
        return $Base.TrimEnd('/') + '/' + ($segments -join '/')
    }

    function Save-RemoteVersion([string]$Path, [string]$Version) {
        try {
            $existing = @{}
            if (Test-Path $Path) {
                try { (Get-Content $Path -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $existing[$_.Name] = $_.Value } } catch {}
            }
            $existing['RemoteVersion'] = $Version
            $existing | ConvertTo-Json | Set-Content -Path $Path -Encoding UTF8
        } catch {}
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Fetch server list (best-effort, doesn't block update flow on failure)
    try {
        $slRaw = (Invoke-WebRequest -Uri $ServerListUrl -UseBasicParsing -TimeoutSec 8).Content
        if ($slRaw -is [byte[]]) { $slRaw = [Text.Encoding]::UTF8.GetString($slRaw) }
        $entries = @()
        foreach ($e in ($slRaw -split '#')) {
            $parts = $e -split '\|'
            if ($parts.Count -lt 3) { continue }
            $name = $parts[0].Trim(); if (-not $name) { continue }
            $folderKey = ($name -replace '^\[T\]\s*','' -replace '\s+',' ').Trim().ToLower()
            $entries += @{ Name=$name; Host=$parts[1]; Port=$parts[2]; FolderKey=$folderKey }
        }
        $Shared.ServerList = @($entries)
        $Shared.ServerListReady = $true
    } catch { $Shared.ServerListReady = $true }

    Set-Footer 'checking for updates...' '#9A9AA8'
    try {
        $remoteVersion = (Invoke-WebRequest -Uri ($BaseUrl + 't4c.version') -UseBasicParsing -TimeoutSec 8).Content
        if ($remoteVersion -is [byte[]]) { $remoteVersion = [Text.Encoding]::UTF8.GetString($remoteVersion) }
        $remoteVersion = $remoteVersion.Trim()
    } catch {
        Set-Footer 'update server unreachable - skipped' '#C29A4A'
        $Shared.UpdateCompleted = $true
        return
    }

    # Always fetch the manifest so the server picker can list every available server pack,
    # even when the user is otherwise up-to-date.
    Set-Footer 'fetching manifest...' '#9A9AA8'
    try {
        $hashContent = (Invoke-WebRequest -Uri ($BaseUrl + 't4c.hash') -UseBasicParsing -TimeoutSec 30).Content
        if ($hashContent -is [byte[]]) { $hashContent = [Text.Encoding]::UTF8.GetString($hashContent) }
    } catch {
        Set-Footer 'manifest fetch failed' '#C29A4A'
        $Shared.UpdateCompleted = $true
        return
    }

    $lines = $hashContent -split '\r?\n' | Where-Object { $_ -ne '' }

    # Discover all servers in the manifest, expose to GUI (regardless of version match)
    $serverInfo = @{}
    foreach ($line in $lines) {
        if ($line -notmatch '^Server Files\\([^\\]+)\\') { continue }
        $name = $matches[1]
        $parts = $line.Split('|')
        if ($parts.Count -lt 3) { continue }
        if (-not $serverInfo.ContainsKey($name)) { $serverInfo[$name] = @{ FileCount = 0; TotalSize = 0L } }
        $serverInfo[$name].FileCount++
        try { $serverInfo[$name].TotalSize += [long]$parts[2] } catch {}
    }
    $Shared.AvailableServers = @(
        $serverInfo.GetEnumerator() | Sort-Object Name | ForEach-Object {
            @{ Name = $_.Key; FileCount = $_.Value.FileCount; TotalSize = $_.Value.TotalSize }
        }
    )
    $Shared.ManifestVersion = $remoteVersion

    # Now that AvailableServers is populated, decide whether full verification is needed
    if ($LocalVersion -eq $remoteVersion -and -not [string]::IsNullOrEmpty($LocalVersion)) {
        Set-Footer ("up to date - v" + $remoteVersion.Substring([Math]::Max(0, $remoteVersion.Length-6))) '#5A5A66'
        $Shared.UpdateCompleted = $true
        return
    }

    $enabledLookup = @{}
    foreach ($s in $Shared.EnabledServers) { $enabledLookup[$s] = $true }

    # Returns $true if local file (when un-patched in memory) matches manifest hash
    # -- i.e. we're at the manifest version, just patched.
    function Test-PatchedMatchesManifest([string]$Path, [string]$ExpectedMd5) {
        try {
            $b = [IO.File]::ReadAllBytes($Path)
            if ($b.Length -lt ($PatchOffset + 6)) { return $false }
            for ($i = 0; $i -lt 6; $i++) {
                if ($b[$PatchOffset + $i] -ne $PatchBytes[$i]) { return $false }
            }
            for ($i = 0; $i -lt 6; $i++) { $b[$PatchOffset + $i] = $PatchExpect[$i] }
            $md = [Security.Cryptography.MD5]::Create()
            $h = -join ($md.ComputeHash($b) | ForEach-Object { '{0:X2}' -f $_ })
            $md.Dispose()
            return ($h -eq $ExpectedMd5.ToUpper())
        } catch { return $false }
    }

    $skippedOutdated = @(); $mismatches = @(); $clientUpdates = @(); $skippedDisabled = 0
    $idx = 0; $total = $lines.Count

    foreach ($line in $lines) {
        $idx++
        $parts = $line.Split('|')
        if ($parts.Count -lt 3) { continue }
        $relPath = $parts[0]; $expectedMd5 = $parts[1].ToUpper()

        # Filter by enabled servers -- skip Server Files\X\... where X is not enabled
        if ($relPath -match '^Server Files\\([^\\]+)\\') {
            if (-not $enabledLookup[$matches[1]]) { $skippedDisabled++; continue }
        }

        $localFile = [IO.Path]::Combine($InstallDir, $relPath)
        if ($idx % 30 -eq 0 -or $idx -eq $total) {
            Set-Footer ("verifying {0}/{1}" -f $idx, $total) '#9A9AA8'
        }

        # Special handling: client binaries we manage with rename/patch/revert
        if ($ClientBinaries -contains $relPath) {
            $needs = $false
            if (-not (Test-Path -LiteralPath $localFile)) { $needs = $true }
            else {
                try {
                    $h = (Get-FileHash -LiteralPath $localFile -Algorithm MD5).Hash
                    if ($h -ne $expectedMd5) {
                        # Maybe it's just our patched version of this same manifest
                        if (-not (Test-PatchedMatchesManifest $localFile $expectedMd5)) { $needs = $true }
                    }
                } catch { $needs = $true }
            }
            if ($needs) { $clientUpdates += @{ Path=$relPath; Md5=$expectedMd5 } }
            continue
        }

        $needs = $false
        if (-not (Test-Path -LiteralPath $localFile)) { $needs = $true }
        else {
            try {
                $h = (Get-FileHash -LiteralPath $localFile -Algorithm MD5).Hash
                if ($h -ne $expectedMd5) { $needs = $true }
            } catch { $needs = $true }
        }
        if ($needs) {
            if ($SkipPaths -contains $relPath) { $skippedOutdated += $relPath }
            else { $mismatches += @{ Path=$relPath; Md5=$expectedMd5 } }
        }
    }

    if ($mismatches.Count -eq 0 -and $clientUpdates.Count -eq 0) {
        Save-RemoteVersion -Path $ConfigPath -Version $remoteVersion
        if ($skippedOutdated.Count -gt 0) {
            Set-Footer ("up to date - {0} file(s) skipped (no auto-update)" -f $skippedOutdated.Count) '#C29A4A'
        } else {
            Set-Footer ("up to date - v" + $remoteVersion.Substring([Math]::Max(0, $remoteVersion.Length-6))) '#5A5A66'
        }
        $Shared.UpdateCompleted = $true
        return
    }

    # Phase 1: standard files
    $totalDl = $mismatches.Count; $idx = 0; $failed = 0
    foreach ($m in $mismatches) {
        $idx++
        Set-Footer ("downloading {0}/{1} - {2}" -f $idx, $totalDl, $m.Path) '#C8A55B'
        $url = (Get-RemoteUrl -Base $BaseUrl -RelPath $m.Path) + '.gz'
        $localFile = [IO.Path]::Combine($InstallDir, $m.Path)
        $localDir = [IO.Path]::GetDirectoryName($localFile)
        if (-not (Test-Path -LiteralPath $localDir)) {
            try { New-Item -ItemType Directory -Force -Path $localDir | Out-Null } catch { $failed++; continue }
        }
        try {
            $tmp = $localFile + '.partial'
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 180
            $dlMd5 = (Get-FileHash -LiteralPath $tmp -Algorithm MD5).Hash
            if ($dlMd5 -ne $m.Md5) {
                Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
                $failed++; continue
            }
            Move-Item -LiteralPath $tmp -Destination $localFile -Force
        } catch { $failed++ }
    }

    # Phase 2: client binaries -- rename -> download -> patch -> cleanup-or-revert
    $clientOk = 0; $clientReverted = 0; $clientLost = 0
    foreach ($cu in $clientUpdates) {
        $localFile = [IO.Path]::Combine($InstallDir, $cu.Path)
        $bak = $localFile + '.bak'

        # Recovery: bin missing but .bak present (e.g. interrupted prior update) -> restore first
        if (-not (Test-Path -LiteralPath $localFile) -and (Test-Path -LiteralPath $bak)) {
            try { Move-Item -LiteralPath $bak -Destination $localFile -Force } catch {}
        }

        $hadBin = Test-Path -LiteralPath $localFile

        Set-Footer ("client update: backing up {0}" -f $cu.Path) '#C8A55B'
        if ($hadBin) {
            try {
                if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
                Move-Item -LiteralPath $localFile -Destination $bak -Force
            } catch {
                Set-Footer ("client update: cannot move to .bak - {0}" -f $_.Exception.Message) '#C24A4A'
                continue
            }
        }

        Set-Footer ("client update: downloading {0}" -f $cu.Path) '#C8A55B'
        $url = (Get-RemoteUrl -Base $BaseUrl -RelPath $cu.Path) + '.gz'
        $downloadOk = $false
        try {
            Invoke-WebRequest -Uri $url -OutFile $localFile -UseBasicParsing -TimeoutSec 240
            $dlMd5 = (Get-FileHash -LiteralPath $localFile -Algorithm MD5).Hash
            if ($dlMd5 -eq $cu.Md5) { $downloadOk = $true }
        } catch {}

        if (-not $downloadOk) {
            Set-Footer 'client update: download failed - reverting' '#C29A4A'
            try { if (Test-Path -LiteralPath $localFile) { Remove-Item -LiteralPath $localFile -Force } } catch {}
            if ($hadBin) {
                try { Move-Item -LiteralPath $bak -Destination $localFile -Force; $clientReverted++ }
                catch { $clientLost++ }
            } else { $clientReverted++ }
            continue
        }

        # Patch the new binary
        $patched = $false
        try {
            $bytes = [IO.File]::ReadAllBytes($localFile)
            if ($bytes.Length -ge ($PatchOffset + 6)) {
                $matches = $true
                for ($i = 0; $i -lt 6; $i++) {
                    if ($bytes[$PatchOffset + $i] -ne $PatchExpect[$i]) { $matches = $false; break }
                }
                if ($matches) {
                    for ($i = 0; $i -lt 6; $i++) { $bytes[$PatchOffset + $i] = $PatchBytes[$i] }
                    [IO.File]::WriteAllBytes($localFile, $bytes)
                    $patched = $true
                }
            }
        } catch {}

        if ($patched) {
            Set-Footer 'client update: patched - cleaning up' '#C8A55B'
            try { if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue } } catch {}
            $clientOk++
        } else {
            Set-Footer 'client update: cannot patch new version - reverting' '#C29A4A'
            try { if (Test-Path -LiteralPath $localFile) { Remove-Item -LiteralPath $localFile -Force } } catch {}
            if ($hadBin) {
                try { Move-Item -LiteralPath $bak -Destination $localFile -Force; $clientReverted++ }
                catch { $clientLost++ }
            } else { $clientReverted++ }
        }
    }

    # Final status
    if ($failed -eq 0 -and $clientReverted -eq 0 -and $clientLost -eq 0) {
        Save-RemoteVersion -Path $ConfigPath -Version $remoteVersion
        $parts = @()
        if ($totalDl -gt 0)  { $parts += "{0} file(s)" -f $totalDl }
        if ($clientOk -gt 0) { $parts += "client patched" }
        $msg = if ($parts.Count -gt 0) { 'updated ' + ($parts -join ', ') } else { 'up to date' }
        Set-Footer $msg '#C8A55B'
    } elseif ($clientLost -gt 0) {
        Set-Footer 'client update FAILED and revert lost binary - run original t4c.exe to recover' '#C24A4A'
    } else {
        $bits = @()
        if ($failed -gt 0)          { $bits += "{0} file(s) failed" -f $failed }
        if ($clientReverted -gt 0)  { $bits += "client kept previous (new patch incompatible)" }
        Set-Footer ("partial: " + ($bits -join ' - ')) '#C29A4A'
    }
    $Shared.UpdateCompleted = $true
}

$updateState = @{ Runspace = $null; PS = $null; Handle = $null }

function Stop-UpdateRunspace {
    try {
        if ($updateState.PS -and -not $updateState.Handle.IsCompleted) { $updateState.PS.Stop() }
        if ($updateState.PS) { $updateState.PS.Dispose() }
        if ($updateState.Runspace) { $updateState.Runspace.Close(); $updateState.Runspace.Dispose() }
    } catch {}
    $updateState.Runspace = $null; $updateState.PS = $null; $updateState.Handle = $null
}

function Start-UpdateRunspace {
    Stop-UpdateRunspace

    # Block launches while a verify/update cycle is running
    $btnLaunch.IsEnabled = $false

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Window',         $window)
    $rs.SessionStateProxy.SetVariable('TxtStatus',      $txtStatus)
    $rs.SessionStateProxy.SetVariable('BtnLaunch',      $btnLaunch)
    $rs.SessionStateProxy.SetVariable('CbServer',       $cbServer)
    $rs.SessionStateProxy.SetVariable('TbHost',         $tbHost)
    $rs.SessionStateProxy.SetVariable('TbPort',         $tbPort)
    $rs.SessionStateProxy.SetVariable('InstallDir',     $installDir)
    $rs.SessionStateProxy.SetVariable('ConfigPath',     $configPath)
    $rs.SessionStateProxy.SetVariable('LocalVersion',   [string]$defaults.RemoteVersion)
    $rs.SessionStateProxy.SetVariable('BaseUrl',        $webPatchBase)
    $rs.SessionStateProxy.SetVariable('SkipPaths',      $skipUpdatePaths)
    $rs.SessionStateProxy.SetVariable('ClientBinaries', $clientBinaries)
    $rs.SessionStateProxy.SetVariable('PatchOffset',    $watchdogOffset)
    $rs.SessionStateProxy.SetVariable('PatchExpect',    $watchdogExpect)
    $rs.SessionStateProxy.SetVariable('PatchBytes',     $watchdogPatch)
    $rs.SessionStateProxy.SetVariable('ServerListUrl',  $serverListUrl)
    $rs.SessionStateProxy.SetVariable('Shared',         $shared)

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($updateScript)

    $updateState.Runspace = $rs
    $updateState.PS       = $ps
    $updateState.Handle   = $ps.BeginInvoke()
}

Start-UpdateRunspace

$window.Add_Closed({ Stop-UpdateRunspace })

[void]$window.ShowDialog()
