<#
    Polish - window (WPF)

    Threading note: actions run synchronously on the UI thread with a dispatcher
    pump between log lines. A background runspace would keep the window
    draggable during long operations, but it would need the whole Polish source
    marshalled into it, and when Polish is served through  irm <url> | iex
    there is no file on disk to hand to a child process. The pump keeps the log
    live and repainting, which is what actually matters. The two genuinely slow
    actions (component cleanup, integrity scan) say so on the label.
#>

function Show-PolishWindow {
    param($Sys, $Actions)

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore, WindowsBase -ErrorAction Stop
    } catch {
        Write-PolishLine "WPF is unavailable here: $($_.Exception.Message)" 'warn'
        return
    }

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Polish" Height="760" Width="1060" MinHeight="620" MinWidth="900"
        WindowStartupLocation="CenterScreen" Background="#FF17171A">
  <Window.Resources>
    <SolidColorBrush x:Key="Fg"      Color="#FFE7E7EA"/>
    <SolidColorBrush x:Key="Muted"   Color="#FF9A9AA4"/>
    <SolidColorBrush x:Key="Panel"   Color="#FF212126"/>
    <SolidColorBrush x:Key="Accent"  Color="#FF6C6CF5"/>
    <SolidColorBrush x:Key="Ok"      Color="#FF4ADE80"/>
    <SolidColorBrush x:Key="Warn"    Color="#FFFACC15"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Margin" Value="0,7,0,0"/>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Panel}"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,9"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
  </Window.Resources>

  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="190"/>
    </Grid.RowDefinitions>

    <!-- header -->
    <Grid Grid.Row="0">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="Polish" FontSize="26" FontWeight="Bold"/>
        <TextBlock x:Name="VerText" Foreground="{StaticResource Muted}" FontSize="12"
                   VerticalAlignment="Bottom" Margin="10,0,0,5"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnProcs"  Style="{StaticResource Btn}" Content="What's running" Margin="0,0,8,0"/>
        <Button x:Name="BtnUndo"   Style="{StaticResource Btn}" Content="Undo last run"  Margin="0,0,8,0"/>
        <Button x:Name="BtnRuns"   Style="{StaticResource Btn}" Content="History"/>
      </StackPanel>
    </Grid>

    <!-- machine summary -->
    <Border Grid.Row="1" Background="{StaticResource Panel}" CornerRadius="6" Padding="14" Margin="0,14,0,0">
      <StackPanel>
        <TextBlock x:Name="SysText" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap"/>
        <TextBlock x:Name="WarnText" Foreground="{StaticResource Warn}" FontSize="12"
                   TextWrapping="Wrap" Margin="0,8,0,0" Visibility="Collapsed"/>
      </StackPanel>
    </Border>

    <!-- modules + actions -->
    <Grid Grid.Row="2" Margin="0,14,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="190"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="{StaticResource Panel}" CornerRadius="6" Padding="6">
        <ListBox x:Name="ModuleList" Background="Transparent" BorderThickness="0"
                 Foreground="{StaticResource Fg}" FontFamily="Segoe UI" FontSize="13"/>
      </Border>

      <Border Grid.Column="1" Background="{StaticResource Panel}" CornerRadius="6"
              Padding="16" Margin="12,0,0,0">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="ActionPanel"/>
        </ScrollViewer>
      </Border>
    </Grid>

    <!-- buttons -->
    <Grid Grid.Row="3" Margin="0,14,0,0">
      <StackPanel Orientation="Horizontal">
        <Button x:Name="BtnOptimize" Style="{StaticResource BtnPrimary}" Content="OPTIMIZE NOW"
                FontSize="14" Padding="22,12" Margin="0,0,10,0"/>
        <Button x:Name="BtnRun"      Style="{StaticResource Btn}" Content="Run selected" Margin="0,0,10,0"/>
        <Button x:Name="BtnDry"      Style="{StaticResource Btn}" Content="Dry run"      Margin="0,0,10,0"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnSafe"  Style="{StaticResource Btn}" Content="Select safe"   Margin="0,0,8,0"/>
        <Button x:Name="BtnNone"  Style="{StaticResource Btn}" Content="Clear all"/>
      </StackPanel>
    </Grid>

    <!-- log -->
    <Border Grid.Row="4" Background="#FF101012" CornerRadius="6" Padding="10" Margin="0,12,0,0">
      <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto">
        <TextBox x:Name="LogBox" Background="Transparent" Foreground="#FFC8C8CD"
                 BorderThickness="0" FontFamily="Consolas" FontSize="12"
                 IsReadOnly="True" TextWrapping="NoWrap" AcceptsReturn="True"/>
      </ScrollViewer>
    </Border>
  </Grid>
</Window>
'@

    try {
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
        $win = [Windows.Markup.XamlReader]::Load($reader)
    } catch {
        Write-PolishLine "could not build the window: $($_.Exception.Message)" 'warn'
        return
    }

    # grab named elements
    $ui = @{}
    foreach ($n in @('VerText', 'SysText', 'WarnText', 'ModuleList', 'ActionPanel', 'LogBox', 'LogScroll',
                     'BtnOptimize', 'BtnRun', 'BtnDry', 'BtnSafe', 'BtnNone',
                     'BtnProcs', 'BtnUndo', 'BtnRuns')) {
        $ui[$n] = $win.FindName($n)
    }

    $ui.VerText.Text = "v$script:PolishVersion"
    $ui.SysText.Text = (Get-PolishSystemSummary -Sys $Sys) -join '   |   '

    $warnings = @()
    if (-not $Sys.IsAdmin) {
        $warnings += 'Not running as administrator: actions marked (admin) are hidden or skipped, and no system restore point can be created. Right-click Polish and Run as administrator for the full set.'
    }
    if ($Sys.MemoryLayout -eq 'SingleChannel') {
        $warnings += 'This machine has one memory stick in a multi-slot board. Adding a matching stick would do more for performance than anything in this tool.'
    }
    if ($Sys.IsVM) { $warnings += 'Virtual machine detected: hardware actions are hidden.' }
    if ($warnings.Count -gt 0) {
        $ui.WarnText.Text = ($warnings -join "`n")
        $ui.WarnText.Visibility = 'Visible'
    }

    # ---- logging into the TextBox, with a pump so it repaints -----------
    $script:PolishUiWin = $win
    $script:PolishUiLog = $ui.LogBox
    $script:PolishUiScroll = $ui.LogScroll

    $uiLogger = {
        param([string]$Message, [string]$Level = 'info')

        $tag = '       '
        switch ($Level) {
            'ok'    { $tag = '  ok   ' }
            'warn'  { $tag = '  !    ' }
            'skip'  { $tag = '  -    ' }
            'head'  { $tag = '' }
            'title' { $tag = '' }
        }
        $script:PolishUiLog.AppendText($tag + $Message + "`r`n")
        $script:PolishUiScroll.ScrollToEnd()

        # also to the day log on disk
        if ($script:PolishLogFile) {
            Add-Content -LiteralPath $script:PolishLogFile -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $tag + $Message) -Encoding utf8 -ErrorAction SilentlyContinue
        }

        # let WPF process pending paint messages
        $script:PolishUiWin.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action] {}) | Out-Null
    }

    # ---- build the action rows -----------------------------------------
    $script:PolishChecks = @{}   # action id -> CheckBox

    $riskBrush = @{
        'Safe'     = '#FF4ADE80'
        'Moderate' = '#FFFACC15'
        'Advanced' = '#FFF87171'
    }

    $renderModule = {
        param([string]$ModuleName)

        $ui.ActionPanel.Children.Clear()
        $list = @($Actions | Where-Object { $_.Module -eq $ModuleName })

        foreach ($a in $list) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.FontSize = 13
            $cb.FontWeight = 'SemiBold'

            # reuse an existing tick state if the user already set one
            if ($script:PolishChecks.ContainsKey($a.Id)) {
                $cb.IsChecked = $script:PolishChecks[$a.Id].IsChecked
            } else {
                $cb.IsChecked = [bool]$a.Default
            }

            $header = New-Object System.Windows.Controls.StackPanel
            $header.Orientation = 'Horizontal'

            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = $a.Name
            $t.Foreground = 'White'
            $header.Children.Add($t) | Out-Null

            $badge = New-Object System.Windows.Controls.TextBlock
            $bits = @($a.Risk, "undo: $($a.Undo)")
            if ($a.Reboot)     { $bits += 'needs restart' }
            if ($a.NeedsAdmin) { $bits += 'admin' }
            $badge.Text = '   ' + ($bits -join ' / ')
            $badge.FontSize = 11
            $badge.FontWeight = 'Normal'
            $badge.Foreground = $riskBrush[$a.Risk]
            $badge.VerticalAlignment = 'Center'
            $header.Children.Add($badge) | Out-Null

            $cb.Content = $header
            $ui.ActionPanel.Children.Add($cb) | Out-Null

            $d = New-Object System.Windows.Controls.TextBlock
            $d.Text = $a.Detail
            $d.FontSize = 11.5
            $d.Foreground = '#FF9A9AA4'
            $d.TextWrapping = 'Wrap'
            $d.Margin = '26,3,0,10'
            $ui.ActionPanel.Children.Add($d) | Out-Null

            $script:PolishChecks[$a.Id] = $cb
        }
    }

    foreach ($m in (Get-PolishModules -Actions $Actions)) { [void]$ui.ModuleList.Items.Add($m) }
    $ui.ModuleList.Add_SelectionChanged({
        if ($ui.ModuleList.SelectedItem) { & $renderModule $ui.ModuleList.SelectedItem }
    })
    $ui.ModuleList.SelectedIndex = 0

    # ---- helpers --------------------------------------------------------
    $getSelected = {
        $ids = @()
        foreach ($k in $script:PolishChecks.Keys) {
            if ($script:PolishChecks[$k].IsChecked) { $ids += $k }
        }
        return @($Actions | Where-Object { $ids -contains $_.Id })
    }

    $setBusy = {
        param([bool]$Busy)
        foreach ($b in @('BtnOptimize', 'BtnRun', 'BtnDry', 'BtnUndo', 'BtnProcs', 'BtnSafe', 'BtnNone', 'BtnRuns')) {
            $ui[$b].IsEnabled = -not $Busy
        }
    }

    $runThese = {
        param($Selected, [bool]$Dry, [string]$ModeName)

        if ($Selected.Count -eq 0) {
            $ui.LogBox.AppendText("  !    nothing ticked`r`n")
            return
        }
        $ui.LogBox.Clear()
        & $setBusy $true
        try {
            [void](Invoke-PolishRun -Sys $Sys -Selected $Selected -DryRun:$Dry -Logger $uiLogger -Mode $ModeName)
        } catch {
            & $uiLogger ("run failed: " + $_.Exception.Message) 'warn'
        } finally {
            & $setBusy $false
        }
    }

    # ---- wiring ---------------------------------------------------------
    $ui.BtnOptimize.Add_Click({
        # the one-click, no-restart path: close idle background apps, free RAM,
        # flush DNS, make sure Game Mode is on. Nothing destructive.
        $ids = @('optimize.closebg', 'optimize.trimram', 'optimize.flushdns', 'gaming.gamemode')
        $sel = @($Actions | Where-Object { $ids -contains $_.Id })
        & $runThese $sel $false 'optimize-now'
    })

    $ui.BtnRun.Add_Click({ & $runThese (& $getSelected) $false 'gui-custom' })
    $ui.BtnDry.Add_Click({ & $runThese (& $getSelected) $true  'gui-dryrun' })

    $ui.BtnSafe.Add_Click({
        foreach ($a in $Actions) {
            if ($script:PolishChecks.ContainsKey($a.Id)) {
                $script:PolishChecks[$a.Id].IsChecked = ($a.Risk -eq 'Safe' -and -not $a.Reboot)
            }
        }
    })
    $ui.BtnNone.Add_Click({
        foreach ($k in $script:PolishChecks.Keys) { $script:PolishChecks[$k].IsChecked = $false }
    })

    $ui.BtnProcs.Add_Click({
        $ui.LogBox.Clear()
        & $setBusy $true
        try {
            $rows = Get-PolishProcessReport
            $reap = Get-PolishReapSummary -Rows $rows
            & $uiLogger '=== What is running ===' 'head'
            & $uiLogger ('{0,-30} {1,5} {2,10}  {3}' -f 'PROCESS', '#', 'RAM', 'VERDICT') 'info'
            foreach ($r in $rows) {
                $v = switch ($r.Class) {
                    'Reapable'  { 'will close' }
                    'Protected' { 'protected' }
                    'Service'   { 'service, use Services module' }
                    'InUse'     { 'in use, left alone' }
                    'Sync'      { 'cloud sync' }
                    default     { 'background' }
                }
                $lvl = 'info'
                if ($r.Class -eq 'Reapable')  { $lvl = 'ok' }
                if ($r.Class -eq 'Protected' -or $r.Class -eq 'Service') { $lvl = 'skip' }
                & $uiLogger ('{0,-30} {1,5} {2,10}  {3}' -f $r.Name, $r.Count, (Format-PolishSize $r.Bytes), $v) $lvl
            }
            & $uiLogger '' 'head'
            if ($reap.Count -gt 0) {
                & $uiLogger ("OPTIMIZE NOW would close {0} app(s) holding {1}" -f $reap.Count, (Format-PolishSize $reap.Bytes)) 'ok'
            } else {
                & $uiLogger 'nothing reapable is running' 'ok'
            }
        } finally { & $setBusy $false }
    })

    $ui.BtnUndo.Add_Click({
        $runs = Get-PolishRuns
        if ($runs.Count -eq 0) {
            $ui.LogBox.Clear()
            & $uiLogger 'no Polish runs recorded yet, nothing to undo' 'warn'
            return
        }
        $m = Import-PolishRun -Path $runs[0].FullName
        $n = 0
        if ($m) { $n = @($m.Entries).Count }
        $r = [System.Windows.MessageBox]::Show(
            "Undo the most recent Polish run?`n`nRun: $($m.RunId)`nReversible items: $n`n`nStore apps that were removed and caches that were deleted cannot be restored this way; everything else goes back exactly as it was.",
            'Polish - undo', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }

        $ui.LogBox.Clear()
        & $setBusy $true
        try { Invoke-PolishUndo -Which 'Last' -Logger $uiLogger }
        finally { & $setBusy $false }
    })

    $ui.BtnRuns.Add_Click({
        $ui.LogBox.Clear()
        & $uiLogger '=== Run history ===' 'head'
        $runs = Get-PolishRuns
        if ($runs.Count -eq 0) { & $uiLogger 'none yet' 'skip'; return }
        foreach ($r in $runs) {
            $m = Import-PolishRun -Path $r.FullName
            if (-not $m) { continue }
            $undone = ''
            if ($m.PSObject.Properties.Name -contains 'UndoneAt' -and $m.UndoneAt) { $undone = '   (already undone)' }
            & $uiLogger ('{0}   {1,-14} {2,3} item(s){3}' -f $m.RunId, $m.Mode, @($m.Entries).Count, $undone) 'info'
        }
        & $uiLogger '' 'head'
        & $uiLogger ('manifests live in ' + (Join-Path (Get-PolishDataDir) 'runs')) 'skip'
    })

    # opening message
    $ui.LogBox.AppendText("Polish is ready.`r`n")
    $ui.LogBox.AppendText("OPTIMIZE NOW closes idle background apps and frees RAM. No restart, nothing deleted.`r`n")
    $ui.LogBox.AppendText("Everything else is opt-in. Tick what you want and use Dry run first if unsure.`r`n")
    $ui.LogBox.AppendText("Every reversible change is recorded, so Undo last run puts it back.`r`n")

    [void]$win.ShowDialog()
}
