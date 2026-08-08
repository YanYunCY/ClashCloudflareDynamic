#requires -Version 5.1

function Initialize-WpfRuntime {
    if ([string]::IsNullOrWhiteSpace([string]$env:WINDIR) -and
        -not [string]::IsNullOrWhiteSpace([string]$env:SystemRoot)) {
        $env:WINDIR = $env:SystemRoot
    }
    if (-not ("Cfdyn.WpfNativeMethods" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Cfdyn {
    public static class WpfNativeMethods {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("shcore.dll")]
        public static extern int SetProcessDpiAwareness(int value);

        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();
    }
}
"@
    }

    if (-not $script:WpfDpiInitialized) {
        $DpiApplied = $false
        try {
            # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
            $DpiApplied = [Cfdyn.WpfNativeMethods]::SetProcessDpiAwarenessContext(
                [IntPtr](-4)
            )
        } catch { }
        if (-not $DpiApplied) {
            try {
                # PROCESS_PER_MONITOR_DPI_AWARE
                $DpiApplied = [Cfdyn.WpfNativeMethods]::SetProcessDpiAwareness(2) -eq 0
            } catch { }
        }
        if (-not $DpiApplied) {
            try { $DpiApplied = [Cfdyn.WpfNativeMethods]::SetProcessDPIAware() } catch { }
        }
        $script:WpfDpiInitialized = $true
    }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Xaml
}

function ConvertFrom-WpfXaml([string]$Xaml) {
    $XmlDocument = New-Object Xml.XmlDocument
    $XmlDocument.PreserveWhitespace = $true
    $XmlDocument.LoadXml($Xaml)
    $Reader = New-Object Xml.XmlNodeReader $XmlDocument
    try {
        return [Windows.Markup.XamlReader]::Load($Reader)
    } finally {
        $Reader.Close()
    }
}

function Get-WindowsAppTheme {
    try {
        $AppsUseLightTheme = Get-ItemPropertyValue `
            -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" `
            -Name "AppsUseLightTheme" `
            -ErrorAction Stop
        if ([int]$AppsUseLightTheme -eq 0) {
            return "dark"
        }
    } catch {
        # Windows 10/11 defaults to a light application theme when this value is absent.
    }
    return "light"
}

function ConvertTo-WpfColor([string]$Value) {
    return [Windows.Media.ColorConverter]::ConvertFromString($Value)
}

function New-WpfBrush([Windows.Media.Color]$Color) {
    $Brush = New-Object Windows.Media.SolidColorBrush
    $Brush.Color = $Color
    return $Brush
}

function Blend-WpfColor(
    [Windows.Media.Color]$Color,
    [byte]$Target,
    [double]$Amount
) {
    $Amount = [Math]::Min(1.0, [Math]::Max(0.0, $Amount))
    return [Windows.Media.Color]::FromRgb(
        [byte][Math]::Round($Color.R + (($Target - $Color.R) * $Amount)),
        [byte][Math]::Round($Color.G + (($Target - $Color.G) * $Amount)),
        [byte][Math]::Round($Color.B + (($Target - $Color.B) * $Amount))
    )
}

function Get-WpfRelativeLuminance([Windows.Media.Color]$Color) {
    $Channels = foreach ($Value in @($Color.R, $Color.G, $Color.B)) {
        $Normalized = $Value / 255.0
        if ($Normalized -le 0.04045) {
            $Normalized / 12.92
        } else {
            [Math]::Pow(($Normalized + 0.055) / 1.055, 2.4)
        }
    }
    return (0.2126 * $Channels[0]) + (0.7152 * $Channels[1]) + (0.0722 * $Channels[2])
}

function Get-ContrastingWpfColor([Windows.Media.Color]$Background) {
    $Luminance = Get-WpfRelativeLuminance $Background
    $WhiteContrast = 1.05 / ($Luminance + 0.05)
    $BlackContrast = ($Luminance + 0.05) / 0.05
    if ($WhiteContrast -ge $BlackContrast) {
        return ConvertTo-WpfColor "#FFFFFF"
    }
    return ConvertTo-WpfColor "#000000"
}

function Get-WindowsAccentColor {
    try {
        $Color = [Windows.SystemParameters]::WindowGlassColor
        if ($Color.A -gt 0 -and ($Color.R + $Color.G + $Color.B) -gt 24) {
            return [Windows.Media.Color]::FromRgb($Color.R, $Color.G, $Color.B)
        }
    } catch { }
    return ConvertTo-WpfColor "#0067C0"
}

function Set-WpfThemeResources(
    [Windows.Window]$Window,
    [ValidateSet("system", "light", "dark")]
    [string]$ThemeMode = "system"
) {
    $ResolvedTheme = if ($ThemeMode -eq "system") {
        Get-WindowsAppTheme
    } else {
        $ThemeMode
    }
    $Dark = $ResolvedTheme -eq "dark"
    $Palette = if ($Dark) {
        @{
            AppBackgroundBrush = "#202020"
            SurfaceBrush = "#2B2B2B"
            SummarySurfaceBrush = "#252525"
            ControlBackgroundBrush = "#323232"
            FooterBackgroundBrush = "#272727"
            TextBrush = "#F5F5F5"
            MutedBrush = "#C2C2C2"
            ControlBorderBrush = "#646464"
            DividerBrush = "#3A3A3A"
            ButtonBackgroundBrush = "#333333"
            ButtonHoverBrush = "#3D3D3D"
            ButtonPressedBrush = "#474747"
            DisabledBackgroundBrush = "#292929"
            DisabledTextBrush = "#858585"
            ScrollThumbBrush = "#4A4A4A"
            ScrollThumbHoverBrush = "#666666"
            SubtleAccentBrush = "#173A55"
            SubtleAccentBorderBrush = "#285C82"
            WarningBackgroundBrush = "#4C3A12"
            WarningBorderBrush = "#8A6A1D"
            SuccessBackgroundBrush = "#173B1B"
            SuccessBorderBrush = "#477A4A"
            SuccessTextBrush = "#8ED28C"
            ErrorTextBrush = "#FFB4AB"
            ErrorBorderBrush = "#FF897D"
        }
    } else {
        @{
            AppBackgroundBrush = "#F3F3F3"
            SurfaceBrush = "#FBFBFB"
            SummarySurfaceBrush = "#F7F7F7"
            ControlBackgroundBrush = "#FFFFFF"
            FooterBackgroundBrush = "#F9F9F9"
            TextBrush = "#1A1A1A"
            MutedBrush = "#5D5D5D"
            ControlBorderBrush = "#B8B8B8"
            DividerBrush = "#E5E5E5"
            ButtonBackgroundBrush = "#FBFBFB"
            ButtonHoverBrush = "#F4F4F4"
            ButtonPressedBrush = "#ECECEC"
            DisabledBackgroundBrush = "#F7F7F7"
            DisabledTextBrush = "#8A8A8A"
            ScrollThumbBrush = "#8A8A8A"
            ScrollThumbHoverBrush = "#666666"
            SubtleAccentBrush = "#E8F3FB"
            SubtleAccentBorderBrush = "#C6E4F5"
            WarningBackgroundBrush = "#FFF4CE"
            WarningBorderBrush = "#F2C94C"
            SuccessBackgroundBrush = "#DFF6DD"
            SuccessBorderBrush = "#6BA368"
            SuccessTextBrush = "#2D7027"
            ErrorTextBrush = "#9D3F00"
            ErrorBorderBrush = "#C42B1C"
        }
    }

    foreach ($Entry in $Palette.GetEnumerator()) {
        $Window.Resources.Remove($Entry.Key)
        $Window.Resources.Add(
            $Entry.Key,
            [object](New-WpfBrush (ConvertTo-WpfColor $Entry.Value))
        )
    }
    $Accent = Get-WindowsAccentColor
    $AccentHover = Blend-WpfColor $Accent $(if ($Dark) { 255 } else { 0 }) 0.12
    $AccentForeground = Get-ContrastingWpfColor $Accent
    $AccentHoverForeground = Get-ContrastingWpfColor $AccentHover
    $SubtleAccent = [Windows.Media.Color]::FromArgb(
        [byte]$(if ($Dark) { 72 } else { 30 }),
        $Accent.R,
        $Accent.G,
        $Accent.B
    )
    $SubtleAccentBorder = [Windows.Media.Color]::FromArgb(
        [byte]$(if ($Dark) { 170 } else { 115 }),
        $Accent.R,
        $Accent.G,
        $Accent.B
    )
    foreach ($AccentEntry in @{
        AccentBrush = $Accent
        AccentHoverBrush = $AccentHover
        AccentForegroundBrush = $AccentForeground
        AccentHoverForegroundBrush = $AccentHoverForeground
        SubtleAccentBrush = $SubtleAccent
        SubtleAccentBorderBrush = $SubtleAccentBorder
    }.GetEnumerator()) {
        $Window.Resources.Remove($AccentEntry.Key)
        $Window.Resources.Add(
            $AccentEntry.Key,
            [object](New-WpfBrush $AccentEntry.Value)
        )
    }
    return $ResolvedTheme
}

function Add-WpfScrollBarResources([Windows.Window]$Window) {
    $Xaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style x:Key="VerticalScrollThumbStyle" TargetType="Thumb">
    <Setter Property="Background" Value="{DynamicResource ScrollThumbBrush}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Border x:Name="ThumbBody" Width="4" HorizontalAlignment="Center"
                  Background="{TemplateBinding Background}" CornerRadius="2"
                  SnapsToDevicePixels="True"/>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="ThumbBody" Property="Width" Value="6"/>
              <Setter TargetName="ThumbBody" Property="Background"
                      Value="{DynamicResource ScrollThumbHoverBrush}"/>
            </Trigger>
            <Trigger Property="IsDragging" Value="True">
              <Setter TargetName="ThumbBody" Property="Width" Value="6"/>
              <Setter TargetName="ThumbBody" Property="Background"
                      Value="{DynamicResource AccentBrush}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="HorizontalScrollThumbStyle" TargetType="Thumb">
    <Setter Property="Background" Value="{DynamicResource ScrollThumbBrush}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Border x:Name="ThumbBody" Height="4" VerticalAlignment="Center"
                  Background="{TemplateBinding Background}" CornerRadius="2"
                  SnapsToDevicePixels="True"/>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="ThumbBody" Property="Height" Value="6"/>
              <Setter TargetName="ThumbBody" Property="Background"
                      Value="{DynamicResource ScrollThumbHoverBrush}"/>
            </Trigger>
            <Trigger Property="IsDragging" Value="True">
              <Setter TargetName="ThumbBody" Property="Height" Value="6"/>
              <Setter TargetName="ThumbBody" Property="Background"
                      Value="{DynamicResource AccentBrush}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <ControlTemplate x:Key="VerticalScrollBarTemplate" TargetType="ScrollBar">
    <Grid Background="Transparent">
      <Track x:Name="PART_Track" IsDirectionReversed="True" Focusable="False"
             Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}"
             Value="{Binding Value, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}"
             ViewportSize="{TemplateBinding ViewportSize}">
        <Track.DecreaseRepeatButton>
          <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}"
                        Focusable="False" Opacity="0"/>
        </Track.DecreaseRepeatButton>
        <Track.Thumb>
          <Thumb Style="{StaticResource VerticalScrollThumbStyle}" MinHeight="24"/>
        </Track.Thumb>
        <Track.IncreaseRepeatButton>
          <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}"
                        Focusable="False" Opacity="0"/>
        </Track.IncreaseRepeatButton>
      </Track>
    </Grid>
  </ControlTemplate>
  <ControlTemplate x:Key="HorizontalScrollBarTemplate" TargetType="ScrollBar">
    <Grid Background="Transparent">
      <Track x:Name="PART_Track" IsDirectionReversed="False" Focusable="False"
             Orientation="Horizontal" Minimum="{TemplateBinding Minimum}"
             Maximum="{TemplateBinding Maximum}"
             Value="{Binding Value, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}"
             ViewportSize="{TemplateBinding ViewportSize}">
        <Track.DecreaseRepeatButton>
          <RepeatButton Command="{x:Static ScrollBar.PageLeftCommand}"
                        Focusable="False" Opacity="0"/>
        </Track.DecreaseRepeatButton>
        <Track.Thumb>
          <Thumb Style="{StaticResource HorizontalScrollThumbStyle}" MinWidth="24"/>
        </Track.Thumb>
        <Track.IncreaseRepeatButton>
          <RepeatButton Command="{x:Static ScrollBar.PageRightCommand}"
                        Focusable="False" Opacity="0"/>
        </Track.IncreaseRepeatButton>
      </Track>
    </Grid>
  </ControlTemplate>
  <Style TargetType="ScrollBar">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Width" Value="12"/>
    <Setter Property="Template" Value="{StaticResource VerticalScrollBarTemplate}"/>
    <Style.Triggers>
      <Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Width" Value="Auto"/>
        <Setter Property="Height" Value="12"/>
        <Setter Property="Template" Value="{StaticResource HorizontalScrollBarTemplate}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
</ResourceDictionary>
'@
    $Window.Resources.MergedDictionaries.Add((ConvertFrom-WpfXaml $Xaml))
}

if ($script:PreferredWpfThemeMode -notin @("system", "light", "dark")) {
    $script:PreferredWpfThemeMode = "system"
}

function Show-InstallForm {
    Initialize-WpfRuntime
    $Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Clash Cloudflare Dynamic"
        Width="1120" Height="780" MinWidth="700" MinHeight="360"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource AppBackgroundBrush}"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>
    <SolidColorBrush x:Key="AccentBrush" Color="#0067C0"/>
    <SolidColorBrush x:Key="AccentHoverBrush" Color="#1975C5"/>
    <SolidColorBrush x:Key="AccentForegroundBrush" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="AccentHoverForegroundBrush" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="AppBackgroundBrush" Color="#F3F3F3"/>
    <SolidColorBrush x:Key="SurfaceBrush" Color="#FBFBFB"/>
    <SolidColorBrush x:Key="SummarySurfaceBrush" Color="#F7F7F7"/>
    <SolidColorBrush x:Key="ControlBackgroundBrush" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="FooterBackgroundBrush" Color="#F9F9F9"/>
    <SolidColorBrush x:Key="TextBrush" Color="#1A1A1A"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#5D5D5D"/>
    <SolidColorBrush x:Key="ControlBorderBrush" Color="#B8B8B8"/>
    <SolidColorBrush x:Key="DividerBrush" Color="#E5E5E5"/>
    <SolidColorBrush x:Key="ButtonBackgroundBrush" Color="#FBFBFB"/>
    <SolidColorBrush x:Key="ButtonHoverBrush" Color="#F4F4F4"/>
    <SolidColorBrush x:Key="ButtonPressedBrush" Color="#ECECEC"/>
    <SolidColorBrush x:Key="DisabledBackgroundBrush" Color="#F7F7F7"/>
    <SolidColorBrush x:Key="DisabledTextBrush" Color="#8A8A8A"/>
    <SolidColorBrush x:Key="ScrollThumbBrush" Color="#8A8A8A"/>
    <SolidColorBrush x:Key="ScrollThumbHoverBrush" Color="#666666"/>
    <SolidColorBrush x:Key="SubtleAccentBrush" Color="#E8F3FB"/>
    <SolidColorBrush x:Key="SubtleAccentBorderBrush" Color="#C6E4F5"/>
    <SolidColorBrush x:Key="WarningBackgroundBrush" Color="#FFF4CE"/>
    <SolidColorBrush x:Key="WarningBorderBrush" Color="#F2C94C"/>
    <SolidColorBrush x:Key="SuccessBackgroundBrush" Color="#DFF6DD"/>
    <SolidColorBrush x:Key="SuccessBorderBrush" Color="#6BA368"/>
    <SolidColorBrush x:Key="SuccessTextBrush" Color="#2D7027"/>
    <SolidColorBrush x:Key="ErrorTextBrush" Color="#9D3F00"/>
    <SolidColorBrush x:Key="ErrorBorderBrush" Color="#C42B1C"/>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
    </Style>
    <Style x:Key="FieldTextBoxStyle" TargetType="TextBox">
      <Setter Property="Height" Value="42"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Background" Value="{DynamicResource ControlBackgroundBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="FieldBorder" CornerRadius="6"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="FieldBorder" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
                <Setter TargetName="FieldBorder" Property="BorderThickness" Value="2"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="FieldBorder" Property="Background" Value="{DynamicResource DisabledBackgroundBrush}"/>
                <Setter Property="Foreground" Value="{DynamicResource DisabledTextBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FieldPasswordBoxStyle" TargetType="PasswordBox">
      <Setter Property="Height" Value="42"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Background" Value="{DynamicResource ControlBackgroundBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="FieldBorder" CornerRadius="6"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="FieldBorder" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
                <Setter TargetName="FieldBorder" Property="BorderThickness" Value="2"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="FieldBorder" Property="Background" Value="{DynamicResource DisabledBackgroundBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FieldComboBoxStyle" TargetType="ComboBox">
      <Setter Property="Height" Value="42"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Background" Value="{DynamicResource ControlBackgroundBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
      <Setter Property="ItemContainerStyle">
        <Setter.Value>
          <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Padding" Value="10,7"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="ComboBoxItem">
                  <Border x:Name="ItemBorder" Background="{TemplateBinding Background}"
                          CornerRadius="3" Padding="{TemplateBinding Padding}">
                    <ContentPresenter/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsHighlighted" Value="True">
                      <Setter TargetName="ItemBorder" Property="Background" Value="{DynamicResource ButtonHoverBrush}"/>
                    </Trigger>
                    <Trigger Property="IsSelected" Value="True">
                      <Setter TargetName="ItemBorder" Property="Background" Value="{DynamicResource SubtleAccentBrush}"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </Setter.Value>
      </Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="ComboBorder" CornerRadius="6"
                      Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}"/>
              <ToggleButton x:Name="DropDownToggle" Grid.ColumnSpan="2"
                            Background="Transparent" BorderThickness="0" Focusable="False"
                            IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent">
                      <Path Data="M 0 0 L 4 4 L 8 0" Stroke="{DynamicResource TextBrush}"
                            StrokeThickness="1.3" HorizontalAlignment="Right"
                            VerticalAlignment="Center" Margin="0,0,13,0"/>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="ContentSite" Margin="10,0,38,0"
                                VerticalAlignment="Center" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"/>
              <TextBox x:Name="PART_EditableTextBox" Visibility="Collapsed"
                       Margin="2,1,38,1" Padding="8,0" VerticalContentAlignment="Center"
                       Background="Transparent" Foreground="{DynamicResource TextBrush}"
                       CaretBrush="{DynamicResource TextBrush}" BorderThickness="0"/>
              <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}"
                     Placement="Bottom" AllowsTransparency="True" Focusable="False"
                     PopupAnimation="Fade" Width="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                <Border Margin="0,4,0,0" Padding="4" CornerRadius="5"
                        Background="{DynamicResource SurfaceBrush}"
                        BorderBrush="{DynamicResource ControlBorderBrush}" BorderThickness="1">
                  <ScrollViewer MaxHeight="280" VerticalScrollBarVisibility="Auto">
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEditable" Value="True">
                <Setter TargetName="ContentSite" Property="Visibility" Value="Collapsed"/>
                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
                <Setter TargetName="ComboBorder" Property="BorderThickness" Value="2"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="ComboBorder" Property="Background" Value="{DynamicResource DisabledBackgroundBrush}"/>
                <Setter Property="Foreground" Value="{DynamicResource DisabledTextBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SecondaryButtonStyle" TargetType="Button">
      <Setter Property="Height" Value="40"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Background" Value="{DynamicResource ButtonBackgroundBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" CornerRadius="6"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ButtonBorder" Property="Background" Value="{DynamicResource ButtonHoverBrush}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="ButtonBorder" Property="Background" Value="{DynamicResource ButtonPressedBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryButtonStyle" TargetType="Button" BasedOn="{StaticResource SecondaryButtonStyle}">
      <Setter Property="Background" Value="{DynamicResource AccentBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentForegroundBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="PrimaryBorder" CornerRadius="6"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="PrimaryBorder" Property="Background" Value="{DynamicResource AccentHoverBrush}"/>
                <Setter Property="Foreground" Value="{DynamicResource AccentHoverForegroundBrush}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="PrimaryBorder" Property="Opacity" Value="0.82"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ThemeChoiceStyle" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="ChoiceBorder" Background="Transparent" BorderBrush="Transparent"
                    BorderThickness="1" CornerRadius="5" Padding="12,6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ChoiceBorder" Property="Background" Value="{DynamicResource ButtonHoverBrush}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="ChoiceBorder" Property="Background" Value="{DynamicResource AccentBrush}"/>
                <Setter TargetName="ChoiceBorder" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
                <Setter Property="Foreground" Value="{DynamicResource AccentForegroundBrush}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="ChoiceBorder" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SettingsExpanderStyle" TargetType="Expander">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Expander">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <ToggleButton x:Name="HeaderToggle" Content="{TemplateBinding Header}"
                            IsChecked="{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}"
                            Background="Transparent" BorderThickness="0" Cursor="Hand"
                            HorizontalContentAlignment="Stretch">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="HeaderHover" Background="Transparent" CornerRadius="6" Padding="2">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="28"/>
                        </Grid.ColumnDefinitions>
                        <Path x:Name="DisclosureArrow" Data="M 0 0 L 4 4 L 0 8"
                              Stroke="{DynamicResource TextBrush}" StrokeThickness="1.4"
                              HorizontalAlignment="Center" VerticalAlignment="Center"
                              Grid.Column="1" RenderTransformOrigin="0.5,0.5">
                          <Path.RenderTransform>
                            <RotateTransform Angle="0"/>
                          </Path.RenderTransform>
                        </Path>
                        <ContentPresenter VerticalAlignment="Center"/>
                      </Grid>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="HeaderHover" Property="Background" Value="{DynamicResource ButtonHoverBrush}"/>
                      </Trigger>
                      <Trigger Property="IsChecked" Value="True">
                        <Setter TargetName="DisclosureArrow" Property="RenderTransform">
                          <Setter.Value><RotateTransform Angle="90"/></Setter.Value>
                        </Setter>
                      </Trigger>
                      <Trigger Property="IsKeyboardFocused" Value="True">
                        <Setter TargetName="HeaderHover" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
                        <Setter TargetName="HeaderHover" Property="BorderThickness" Value="1"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="ExpandSite" Grid.Row="1" Visibility="Collapsed"
                                ContentSource="Content"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsExpanded" Value="True">
                <Setter TargetName="ExpandSite" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FieldLabelStyle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Margin" Value="0,0,0,7"/>
    </Style>
    <Style x:Key="SettingsCardStyle" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource SurfaceBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource DividerBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="9"/>
      <Setter Property="Padding" Value="18,16"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
    </Style>
    <Style x:Key="SectionTitleStyle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,13"/>
    </Style>
    <Style x:Key="SummaryLabelStyle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,0,0,3"/>
    </Style>
    <Style x:Key="SummaryValueStyle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
  </Window.Resources>

  <Grid Background="{DynamicResource AppBackgroundBrush}">
    <Grid.RowDefinitions>
      <RowDefinition Height="118"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="84"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="36,24,36,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock x:Name="HeaderTitle" Text="Clash Cloudflare Dynamic" FontSize="26" FontWeight="SemiBold"/>
        <TextBlock x:Name="HeaderSubtitle" Text="配置真实代理链路，并安装自动发现与优选任务" Margin="0,8,0,0"
                   Foreground="{DynamicResource MutedBrush}" FontSize="13"/>
      </StackPanel>
      <StackPanel x:Name="AppearancePanel" Grid.Column="1" Margin="20,0,0,0" HorizontalAlignment="Right">
        <TextBlock Text="外观" Margin="5,0,0,5" HorizontalAlignment="Left"
                   Foreground="{DynamicResource MutedBrush}" FontSize="11"/>
        <Border Background="{DynamicResource SurfaceBrush}"
                BorderBrush="{DynamicResource DividerBrush}"
                BorderThickness="1" CornerRadius="8" Padding="4">
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="SystemThemeButton" GroupName="Appearance"
                         Content="跟随系统" IsChecked="True"
                         Style="{StaticResource ThemeChoiceStyle}"/>
            <RadioButton x:Name="LightThemeButton" GroupName="Appearance"
                         Content="浅色" Style="{StaticResource ThemeChoiceStyle}"/>
            <RadioButton x:Name="DarkThemeButton" GroupName="Appearance"
                         Content="深色" Style="{StaticResource ThemeChoiceStyle}"/>
          </StackPanel>
        </Border>
        <TextBlock x:Name="PrivacyText" Text="凭据仅在本机保存" Margin="0,6,5,0" HorizontalAlignment="Right"
                   Foreground="{DynamicResource MutedBrush}" FontSize="11"/>
      </StackPanel>
    </Grid>

    <Grid x:Name="ContentGrid" Grid.Row="1" Margin="36,0,36,24">
      <Grid.ColumnDefinitions>
        <ColumnDefinition x:Name="FormColumn" Width="*" MinWidth="500"/>
        <ColumnDefinition x:Name="ContentGapColumn" Width="24"/>
        <ColumnDefinition x:Name="SummaryColumn" Width="320"/>
      </Grid.ColumnDefinitions>

      <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto"
                    HorizontalScrollBarVisibility="Disabled" Padding="0,0,14,0">
        <StackPanel>
          <Grid Margin="2,0,0,18">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="4"/>
              <ColumnDefinition Width="14"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Background="{DynamicResource AccentBrush}" CornerRadius="2"/>
            <StackPanel Grid.Column="2">
          <TextBlock Text="节点配置" FontSize="18" FontWeight="SemiBold"/>
          <TextBlock Text="程序只替换 Cloudflare IP；以下认证、域名与传输参数会原样保留。"
                     Foreground="{DynamicResource MutedBrush}" FontSize="12"
                     Margin="0,6,0,0" TextWrapping="Wrap"/>
            </StackPanel>
          </Grid>

          <Border x:Name="ConnectionCard" Style="{StaticResource SettingsCardStyle}">
            <StackPanel>
          <TextBlock Text="连接方式" Style="{StaticResource SectionTitleStyle}"/>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="18"/>
              <ColumnDefinition Width="190"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock Text="协议" Style="{StaticResource FieldLabelStyle}"/>
              <ComboBox x:Name="ProtocolBox" Style="{StaticResource FieldComboBoxStyle}"
                        SelectedIndex="0" AutomationProperties.Name="协议">
                <sys:String>VMess</sys:String>
                <sys:String>VLESS</sys:String>
                <sys:String>Trojan</sys:String>
                <sys:String>自定义 Mihomo 模板</sys:String>
              </ComboBox>
            </StackPanel>
            <StackPanel Grid.Column="2">
              <TextBlock Text="Cloudflare 入口端口" Style="{StaticResource FieldLabelStyle}"/>
              <ComboBox x:Name="PortBox" Style="{StaticResource FieldComboBoxStyle}"
                        IsEditable="True" Text="443" AutomationProperties.Name="Cloudflare 入口端口">
                <sys:String>443</sys:String>
                <sys:String>2053</sys:String>
                <sys:String>2083</sys:String>
                <sys:String>2087</sys:String>
                <sys:String>2096</sys:String>
                <sys:String>8443</sys:String>
              </ComboBox>
            </StackPanel>
          </Grid>
            </StackPanel>
          </Border>

          <Border x:Name="NodeCard" Style="{StaticResource SettingsCardStyle}">
            <StackPanel>
          <TextBlock Text="节点与传输" Style="{StaticResource SectionTitleStyle}"/>
          <StackPanel x:Name="BuiltInPanel">
            <TextBlock x:Name="CredentialLabel" Text="VMess UUID"
                       Style="{StaticResource FieldLabelStyle}"/>
            <PasswordBox x:Name="CredentialBox" Style="{StaticResource FieldPasswordBoxStyle}"
                         AutomationProperties.Name="节点认证"/>

            <Grid Margin="0,20,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="18"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="SNI / Server Name" Style="{StaticResource FieldLabelStyle}"/>
                <TextBox x:Name="ServerBox" Style="{StaticResource FieldTextBoxStyle}"
                         AutomationProperties.Name="SNI Server Name"/>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <TextBlock Text="WebSocket Host" Style="{StaticResource FieldLabelStyle}"/>
                <TextBox x:Name="HostBox" Style="{StaticResource FieldTextBoxStyle}"
                         AutomationProperties.Name="WebSocket Host"/>
              </StackPanel>
            </Grid>

            <TextBlock Text="WebSocket 路径" Style="{StaticResource FieldLabelStyle}"
                       Margin="0,20,0,7"/>
            <TextBox x:Name="PathBox" Text="/" Style="{StaticResource FieldTextBoxStyle}"
                     AutomationProperties.Name="WebSocket 路径"/>
          </StackPanel>

          <StackPanel x:Name="CustomPanel" Visibility="Collapsed">
            <TextBlock Text="自定义 Mihomo JSON 模板" Style="{StaticResource FieldLabelStyle}"/>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="88"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="CustomBox" Style="{StaticResource FieldTextBoxStyle}"
                       AutomationProperties.Name="自定义 Mihomo JSON 模板"/>
              <Button x:Name="BrowseButton" Grid.Column="2" Content="浏览…"
                      Style="{StaticResource SecondaryButtonStyle}"/>
            </Grid>
            <TextBlock Text="模板必须包含 type、port 以及完整认证和传输字段；向导只覆盖你填写的端口。"
                       Foreground="{DynamicResource MutedBrush}" FontSize="12"
                       Margin="0,8,0,0" TextWrapping="Wrap"/>
          </StackPanel>
            </StackPanel>
          </Border>

          <Border x:Name="AdvancedCard" Style="{StaticResource SettingsCardStyle}"
                  Margin="0,0,0,2" Padding="16,10">
          <Expander x:Name="AdvancedExpander" IsExpanded="False"
                    Style="{StaticResource SettingsExpanderStyle}">
            <Expander.Header>
              <StackPanel Margin="2,6,0,6">
                <TextBlock Text="Mihomo 本地连接" FontWeight="SemiBold"/>
                <TextBlock x:Name="AdvancedSummaryText" Margin="0,4,0,0"
                           Foreground="{DynamicResource MutedBrush}" FontSize="12"
                           Text="API 127.0.0.1:9090 · 密钥未设置 · Mixed 127.0.0.1:7890"/>
              </StackPanel>
            </Expander.Header>
            <StackPanel Margin="2,12,2,6">
              <TextBlock Text="Mihomo API" Style="{StaticResource FieldLabelStyle}"/>
              <TextBox x:Name="ControllerBox" Text="http://127.0.0.1:9090"
                       Style="{StaticResource FieldTextBoxStyle}"
                       AutomationProperties.Name="Mihomo API"/>
              <TextBlock Text="仅允许本机 HTTP(S) 地址；请先在 Clash Verge Rev 中启用外部控制。"
                         Foreground="{DynamicResource MutedBrush}" FontSize="12"
                         Margin="0,7,0,0" TextWrapping="Wrap"/>
              <TextBlock Text="Mihomo API 密钥（可选）" Style="{StaticResource FieldLabelStyle}"
                          Margin="0,18,0,7"/>
              <PasswordBox x:Name="SecretBox" Style="{StaticResource FieldPasswordBoxStyle}"
                           AutomationProperties.Name="Mihomo API 密钥"/>
              <TextBlock Text="Mixed Proxy" Style="{StaticResource FieldLabelStyle}"
                          Margin="0,18,0,7"/>
              <TextBox x:Name="MixedBox" Text="http://127.0.0.1:7890"
                       Style="{StaticResource FieldTextBoxStyle}"
                       AutomationProperties.Name="Mixed Proxy"/>
            </StackPanel>
          </Expander>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <Border x:Name="SummaryPanel" Grid.Column="2" Background="{DynamicResource SummarySurfaceBrush}"
              BorderBrush="{DynamicResource DividerBrush}"
              BorderThickness="1" CornerRadius="10" Padding="20,18"
              SnapsToDevicePixels="True">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="4"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Background="{DynamicResource AccentBrush}" CornerRadius="2"/>
              <TextBlock Grid.Column="2" Text="实时摘要" FontSize="17" FontWeight="SemiBold"/>
            </Grid>
            <TextBlock x:Name="SummarySubtitle" Text="敏感值始终不会在这里显示" Margin="0,5,0,0"
                       Foreground="{DynamicResource MutedBrush}" FontSize="12"/>
          </StackPanel>
          <ScrollViewer x:Name="SummaryDetailsScroll" Grid.Row="1" Margin="0,18,0,0"
                        VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel>
            <TextBlock Text="协议" Style="{StaticResource SummaryLabelStyle}"/>
            <TextBlock x:Name="SummaryProtocol" Text="VMess" Style="{StaticResource SummaryValueStyle}"/>
            <Border BorderBrush="{DynamicResource DividerBrush}" BorderThickness="0,0,0,1" Margin="0,10"/>
            <TextBlock Text="入口端口" Style="{StaticResource SummaryLabelStyle}"/>
            <TextBlock x:Name="SummaryPort" Text="443" Style="{StaticResource SummaryValueStyle}"/>
            <Border BorderBrush="{DynamicResource DividerBrush}" BorderThickness="0,0,0,1" Margin="0,10"/>
            <TextBlock Text="SNI / Server Name" Style="{StaticResource SummaryLabelStyle}"/>
            <TextBlock x:Name="SummarySni" Text="未填写" Style="{StaticResource SummaryValueStyle}"/>
            <Border BorderBrush="{DynamicResource DividerBrush}" BorderThickness="0,0,0,1" Margin="0,10"/>
            <TextBlock Text="WebSocket Host" Style="{StaticResource SummaryLabelStyle}"/>
            <TextBlock x:Name="SummaryHost" Text="未填写" Style="{StaticResource SummaryValueStyle}"/>
            <Border BorderBrush="{DynamicResource DividerBrush}" BorderThickness="0,0,0,1" Margin="0,10"/>
            <TextBlock Text="WebSocket 路径" Style="{StaticResource SummaryLabelStyle}"/>
            <TextBlock x:Name="SummaryPath" Text="/" Style="{StaticResource SummaryValueStyle}"/>
            <Border BorderBrush="{DynamicResource DividerBrush}" BorderThickness="0,0,0,1" Margin="0,10"/>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="节点认证" Style="{StaticResource SummaryLabelStyle}"/>
                <TextBlock x:Name="SummaryCredential" Text="未设置" Style="{StaticResource SummaryValueStyle}"/>
              </StackPanel>
              <StackPanel Grid.Column="1">
                <TextBlock Text="API 密钥" Style="{StaticResource SummaryLabelStyle}"/>
                <TextBlock x:Name="SummarySecret" Text="未设置" Style="{StaticResource SummaryValueStyle}"/>
              </StackPanel>
            </Grid>
          </StackPanel>
          </ScrollViewer>
          <Border Grid.Row="2" x:Name="ValidationBadge"
                  Background="{DynamicResource WarningBackgroundBrush}"
                  BorderBrush="{DynamicResource WarningBorderBrush}"
                  BorderThickness="1" CornerRadius="6"
                  Padding="12,10" Margin="0,16,0,0">
            <StackPanel>
              <TextBlock x:Name="ValidationTitle" Text="还需完成" FontWeight="SemiBold"/>
              <TextBlock x:Name="ValidationSummary" Text="请填写 VMess UUID" Margin="0,3,0,0"
                         TextWrapping="Wrap" Foreground="{DynamicResource MutedBrush}" FontSize="12"/>
            </StackPanel>
          </Border>
        </Grid>
      </Border>
    </Grid>

    <Border Grid.Row="2" Background="{DynamicResource FooterBackgroundBrush}"
            BorderBrush="{DynamicResource DividerBrush}" BorderThickness="0,1,0,0">
      <Grid Margin="36,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center" Margin="0,0,20,0">
          <TextBlock x:Name="FooterStatusTitle" Text="请完成配置" FontWeight="SemiBold"/>
          <TextBlock x:Name="FooterErrorText" Text="请填写 VMess UUID" Margin="0,3,0,0"
                     Foreground="{DynamicResource ErrorTextBrush}" FontSize="12"
                     TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="CancelButton" Content="取消" Width="92"
                  Style="{StaticResource SecondaryButtonStyle}" IsCancel="True"/>
          <Button x:Name="InstallButton" Content="验证并安装" Width="142" Margin="10,0,0,0"
                  Style="{StaticResource PrimaryButtonStyle}" IsDefault="True"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

    $Window = ConvertFrom-WpfXaml $Xaml
    Add-WpfScrollBarResources $Window
    $WorkArea = [Windows.SystemParameters]::WorkArea
    $Window.Width = [Math]::Min(
        1120,
        [Math]::Max($Window.MinWidth, $WorkArea.Width - 20)
    )
    $Window.Height = [Math]::Min(
        780,
        [Math]::Max($Window.MinHeight, $WorkArea.Height - 20)
    )
    $ControlNames = @(
        "HeaderTitle", "HeaderSubtitle", "AppearancePanel", "PrivacyText",
        "ContentGrid", "SummaryPanel", "ConnectionCard", "NodeCard", "AdvancedCard",
        "ProtocolBox", "PortBox", "BuiltInPanel", "CustomPanel",
        "CredentialLabel", "CredentialBox", "ServerBox", "HostBox", "PathBox",
        "CustomBox", "BrowseButton", "AdvancedExpander", "AdvancedSummaryText",
        "ControllerBox", "SecretBox", "MixedBox", "SummaryProtocol", "SummaryPort",
        "SummarySubtitle", "SummaryDetailsScroll", "SummarySni", "SummaryHost", "SummaryPath",
        "SummaryCredential", "SummarySecret",
        "ValidationBadge", "ValidationTitle", "ValidationSummary",
        "FooterStatusTitle", "FooterErrorText", "CancelButton", "InstallButton",
        "SystemThemeButton", "LightThemeButton", "DarkThemeButton"
    )
    foreach ($Name in $ControlNames) {
        Set-Variable -Name $Name -Value $Window.FindName($Name)
    }

    $ApplyResponsiveLayout = {
        $CurrentWidth = if ($Window.ActualWidth -gt 0) {
            $Window.ActualWidth
        } else {
            $Window.Width
        }
        if ($CurrentWidth -lt 1040) {
            $ContentGrid.ColumnDefinitions[0].MinWidth = 0
            $ContentGrid.ColumnDefinitions[1].Width = New-Object Windows.GridLength(0)
            $ContentGrid.ColumnDefinitions[2].Width = New-Object Windows.GridLength(0)
            $SummaryPanel.Visibility = [Windows.Visibility]::Collapsed
        } else {
            $ContentGrid.ColumnDefinitions[0].MinWidth = 500
            $ContentGrid.ColumnDefinitions[1].Width = New-Object Windows.GridLength(24)
            $ContentGrid.ColumnDefinitions[2].Width = New-Object Windows.GridLength(320)
            $SummaryPanel.Visibility = [Windows.Visibility]::Visible
        }
        $HeaderSubtitle.Visibility = if ($CurrentWidth -lt 820) {
            [Windows.Visibility]::Collapsed
        } else {
            [Windows.Visibility]::Visible
        }
        $PrivacyText.Visibility = $HeaderSubtitle.Visibility
        $HeaderTitle.FontSize = if ($CurrentWidth -lt 820) { 22 } else { 26 }
        $CurrentHeight = if ($Window.ActualHeight -gt 0) {
            $Window.ActualHeight
        } else {
            $Window.Height
        }
        $SummaryDetailsScroll.Visibility = if (
            $SummaryPanel.Visibility -eq [Windows.Visibility]::Collapsed -or
            $CurrentHeight -lt 560
        ) {
            [Windows.Visibility]::Collapsed
        } else {
            [Windows.Visibility]::Visible
        }
        $SummarySubtitle.Visibility = $SummaryDetailsScroll.Visibility
    }
    $Window.Add_SizeChanged({ & $ApplyResponsiveLayout })
    & $ApplyResponsiveLayout

    $script:WizardResult = $null
    $UiState = @{
        ConfirmedCustomPort = $null
        PreviousProtocolIndex = 0
        ThemeMode = $script:PreferredWpfThemeMode
        ResolvedTheme = "light"
        ThemeEventsReady = $false
    }
    $UiState.ResolvedTheme = Set-WpfThemeResources $Window $UiState.ThemeMode
    switch ($UiState.ThemeMode) {
        "light" { $LightThemeButton.IsChecked = $true }
        "dark" { $DarkThemeButton.IsChecked = $true }
        default { $SystemThemeButton.IsChecked = $true }
    }

    $GetCandidate = {
        $ProtocolNames = @("vmess", "vless", "trojan", "custom")
        $PortValue = 0
        $PortText = $PortBox.Text.Trim()
        $PortParseError = $false
        if (-not [string]::IsNullOrWhiteSpace($PortText) -and
            -not [int]::TryParse($PortText, [ref]$PortValue)) {
            $PortValue = -1
            $PortParseError = $true
        }
        return @{
            Protocol = $ProtocolNames[$ProtocolBox.SelectedIndex]
            Port = $PortValue
            PortText = $PortText
            PortParseError = $PortParseError
            Controller = $ControllerBox.Text.Trim()
            ControllerSecret = $SecretBox.Password
            MixedProxy = $MixedBox.Text.Trim()
            Credential = $CredentialBox.Password.Trim()
            ServerName = $ServerBox.Text.Trim()
            HostName = $HostBox.Text.Trim()
            WebSocketPath = $PathBox.Text.Trim()
            CustomTemplatePath = $CustomBox.Text.Trim()
        }
    }

    $GetValidationState = {
        param([hashtable]$Candidate)
        if ($Candidate.PortParseError) {
            return [PSCustomObject]@{ IsValid = $false; Field = "Port"; Message = "入口端口必须是数字。" }
        }
        if ($Candidate.Protocol -ne "custom" -and [string]::IsNullOrWhiteSpace($Candidate.PortText)) {
            return [PSCustomObject]@{ IsValid = $false; Field = "Port"; Message = "请填写 Cloudflare 入口端口。" }
        }
        if ($Candidate.Port -lt 0 -or $Candidate.Port -gt 65535 -or
            ($Candidate.Protocol -ne "custom" -and $Candidate.Port -eq 0)) {
            return [PSCustomObject]@{ IsValid = $false; Field = "Port"; Message = "入口端口必须为 1 到 65535。" }
        }
        if (-not (Test-LoopbackHttpUri $Candidate.Controller)) {
            return [PSCustomObject]@{ IsValid = $false; Field = "Controller"; Message = "Mihomo API 必须是本机 HTTP(S) 地址。" }
        }
        if (-not (Test-LoopbackHttpUri $Candidate.MixedProxy)) {
            return [PSCustomObject]@{ IsValid = $false; Field = "Mixed"; Message = "Mixed Proxy 必须是本机 HTTP(S) 地址。" }
        }
        if ($Candidate.Protocol -eq "custom") {
            if ([string]::IsNullOrWhiteSpace($Candidate.CustomTemplatePath)) {
                return [PSCustomObject]@{ IsValid = $false; Field = "Custom"; Message = "请选择自定义 Mihomo JSON 模板。" }
            }
            if (-not (Test-Path -LiteralPath $Candidate.CustomTemplatePath -PathType Leaf)) {
                return [PSCustomObject]@{ IsValid = $false; Field = "Custom"; Message = "自定义 Mihomo 模板文件不存在。" }
            }
            try {
                $null = New-NodeTemplate $Candidate
            } catch {
                return [PSCustomObject]@{ IsValid = $false; Field = "Custom"; Message = $_.Exception.Message }
            }
            return [PSCustomObject]@{ IsValid = $true; Field = ""; Message = "配置完整，可以验证并安装。" }
        }
        if ($Candidate.Protocol -in @("vmess", "vless")) {
            $Uuid = [Guid]::Empty
            if (-not [Guid]::TryParse($Candidate.Credential, [ref]$Uuid) -or
                $Uuid -eq [Guid]::Empty) {
                $ProtocolLabel = $Candidate.Protocol.ToUpperInvariant()
                return [PSCustomObject]@{ IsValid = $false; Field = "Credential"; Message = "请填写有效的非零 $ProtocolLabel UUID。" }
            }
        } elseif ([string]::IsNullOrWhiteSpace($Candidate.Credential)) {
            return [PSCustomObject]@{ IsValid = $false; Field = "Credential"; Message = "请填写 Trojan 密码。" }
        }
        if ([string]::IsNullOrWhiteSpace($Candidate.ServerName) -or
            $Candidate.ServerName -match "(?i)(^|\.)example\.(com|net|org)$|\.example$") {
            return [PSCustomObject]@{ IsValid = $false; Field = "Server"; Message = "请填写节点实际使用的 SNI / Server Name。" }
        }
        if ([string]::IsNullOrWhiteSpace($Candidate.HostName) -or
            $Candidate.HostName -match "(?i)(^|\.)example\.(com|net|org)$|\.example$") {
            return [PSCustomObject]@{ IsValid = $false; Field = "Host"; Message = "请填写节点实际使用的 WebSocket Host。" }
        }
        if ([string]::IsNullOrWhiteSpace($Candidate.WebSocketPath) -or
            -not $Candidate.WebSocketPath.StartsWith("/") -or
            $Candidate.WebSocketPath -eq "/your-websocket-path") {
            return [PSCustomObject]@{ IsValid = $false; Field = "Path"; Message = "WebSocket 路径必须以 / 开头。" }
        }
        return [PSCustomObject]@{ IsValid = $true; Field = ""; Message = "配置完整，可以验证并安装。" }
    }

    $FormatSummaryUri = {
        param([string]$Value)
        $Parsed = $null
        if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$Parsed)) {
            return "地址待检查"
        }
        $PortSuffix = if ($Parsed.IsDefaultPort) { "" } else { ":$($Parsed.Port)" }
        return "$($Parsed.Host)$PortSuffix"
    }

    $FieldControls = @{
        Port = $PortBox
        Controller = $ControllerBox
        Mixed = $MixedBox
        Credential = $CredentialBox
        Server = $ServerBox
        Host = $HostBox
        Path = $PathBox
        Custom = $CustomBox
    }

    $UpdateUi = {
        $Candidate = & $GetCandidate
        $IsCustom = $Candidate.Protocol -eq "custom"
        $BuiltInPanel.Visibility = if ($IsCustom) {
            [Windows.Visibility]::Collapsed
        } else {
            [Windows.Visibility]::Visible
        }
        $CustomPanel.Visibility = if ($IsCustom) {
            [Windows.Visibility]::Visible
        } else {
            [Windows.Visibility]::Collapsed
        }
        $CredentialLabel.Text = switch ($Candidate.Protocol) {
            "vmess" { "VMess UUID" }
            "vless" { "VLESS UUID" }
            "trojan" { "Trojan 密码" }
            default { "节点认证" }
        }

        $SummaryProtocol.Text = switch ($Candidate.Protocol) {
            "vmess" { "VMess" }
            "vless" { "VLESS" }
            "trojan" { "Trojan" }
            default { "自定义" }
        }
        $SummaryPort.Text = if ([string]::IsNullOrWhiteSpace($Candidate.PortText)) {
            if ($IsCustom) { "由模板提供" } else { "未填写" }
        } else {
            $Candidate.PortText
        }
        if ($IsCustom) {
            $SummarySni.Text = "由模板提供"
            $SummaryHost.Text = "由模板提供"
            $SummaryPath.Text = if ([string]::IsNullOrWhiteSpace($Candidate.CustomTemplatePath)) {
                "未选择模板"
            } else {
                [IO.Path]::GetFileName($Candidate.CustomTemplatePath)
            }
            $SummaryCredential.Text = if ([string]::IsNullOrWhiteSpace($Candidate.CustomTemplatePath)) {
                "未设置"
            } else {
                "已设置"
            }
        } else {
            $SummarySni.Text = if ([string]::IsNullOrWhiteSpace($Candidate.ServerName)) {
                "未填写"
            } else {
                $Candidate.ServerName
            }
            $SummaryHost.Text = if ([string]::IsNullOrWhiteSpace($Candidate.HostName)) {
                "未填写"
            } else {
                $Candidate.HostName
            }
            $SummaryPath.Text = if ([string]::IsNullOrWhiteSpace($Candidate.WebSocketPath)) {
                "未填写"
            } else {
                $Candidate.WebSocketPath
            }
            $SummaryCredential.Text = if ([string]::IsNullOrWhiteSpace($Candidate.Credential)) {
                "未设置"
            } else {
                "已设置"
            }
        }
        $SummarySecret.Text = if ([string]::IsNullOrWhiteSpace($Candidate.ControllerSecret)) {
            "未设置"
        } else {
            "已设置"
        }
        $SecretState = if ([string]::IsNullOrWhiteSpace($Candidate.ControllerSecret)) {
            "密钥未设置"
        } else {
            "密钥已设置"
        }
        $AdvancedSummaryText.Text = (
            "API {0} · {1} · Mixed {2}" -f
            (& $FormatSummaryUri $Candidate.Controller),
            $SecretState,
            (& $FormatSummaryUri $Candidate.MixedProxy)
        )

        foreach ($Control in $FieldControls.Values) {
            $Control.BorderBrush = $Window.Resources["ControlBorderBrush"]
        }
        $Validation = & $GetValidationState $Candidate
        if ($Validation.IsValid) {
            $ValidationBadge.Background = $Window.Resources["SuccessBackgroundBrush"]
            $ValidationBadge.BorderBrush = $Window.Resources["SuccessBorderBrush"]
            $ValidationTitle.Text = "校验通过"
            $ValidationSummary.Text = $Validation.Message
            $FooterStatusTitle.Text = "本地安装"
            $FooterErrorText.Text = "凭据将在本机受保护目录中保存，安装前会备份现有文件。"
            $FooterErrorText.Foreground = $Window.Resources["MutedBrush"]
        } else {
            $ValidationBadge.Background = $Window.Resources["WarningBackgroundBrush"]
            $ValidationBadge.BorderBrush = $Window.Resources["WarningBorderBrush"]
            $ValidationTitle.Text = "还需完成"
            $ValidationSummary.Text = $Validation.Message
            $FooterStatusTitle.Text = "请检查对应字段"
            $FooterErrorText.Text = $Validation.Message
            $FooterErrorText.Foreground = $Window.Resources["ErrorTextBrush"]
            if ($FieldControls.ContainsKey($Validation.Field)) {
                $FieldControls[$Validation.Field].BorderBrush = $Window.Resources["ErrorBorderBrush"]
            }
        }
        $Window.Tag = $Validation
    }

    $FocusValidationField = {
        param($Validation)
        if ($Validation.Field -in @("Controller", "Mixed")) {
            $AdvancedExpander.IsExpanded = $true
        }
        if ($FieldControls.ContainsKey($Validation.Field)) {
            $null = $FieldControls[$Validation.Field].Focus()
        }
    }

    $ApplyThemeMode = {
        param([string]$Mode)
        if (-not $UiState.ThemeEventsReady) {
            return
        }
        $UiState.ThemeMode = $Mode
        $script:PreferredWpfThemeMode = $Mode
        $UiState.ResolvedTheme = Set-WpfThemeResources $Window $Mode
        & $UpdateUi
    }
    $SystemThemeButton.Add_Checked({ & $ApplyThemeMode "system" })
    $LightThemeButton.Add_Checked({ & $ApplyThemeMode "light" })
    $DarkThemeButton.Add_Checked({ & $ApplyThemeMode "dark" })
    $Window.Add_Activated({
        if ($UiState.ThemeMode -eq "system") {
            $Resolved = Get-WindowsAppTheme
            if ($Resolved -ne $UiState.ResolvedTheme) {
                $UiState.ResolvedTheme = Set-WpfThemeResources $Window "system"
                & $UpdateUi
            }
        }
    })
    $UiState.ThemeEventsReady = $true

    $ProtocolBox.Add_SelectionChanged({
        $NewIndex = $ProtocolBox.SelectedIndex
        if ($NewIndex -eq 3 -and $UiState.PreviousProtocolIndex -ne 3) {
            $PortBox.Text = ""
        } elseif ($NewIndex -ne 3 -and [string]::IsNullOrWhiteSpace($PortBox.Text)) {
            $PortBox.Text = "443"
        }
        $UiState.PreviousProtocolIndex = $NewIndex
        & $UpdateUi
    })
    $PortBox.Add_SelectionChanged({ & $UpdateUi })
    $PortTextChangedHandler = [Windows.RoutedEventHandler]{ & $UpdateUi }
    $PortBox.AddHandler(
        [Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
        $PortTextChangedHandler
    )
    $PortBox.Add_LostKeyboardFocus({ & $UpdateUi })
    foreach ($TextControl in @($ServerBox, $HostBox, $PathBox, $CustomBox, $ControllerBox, $MixedBox)) {
        $TextControl.Add_TextChanged({ & $UpdateUi })
    }
    foreach ($PasswordControl in @($CredentialBox, $SecretBox)) {
        $PasswordControl.Add_PasswordChanged({ & $UpdateUi })
    }

    $BrowseButton.Add_Click({
        $Dialog = New-Object Microsoft.Win32.OpenFileDialog
        $Dialog.Title = "选择 Mihomo 节点模板"
        $Dialog.Filter = "JSON 文件 (*.json)|*.json|所有文件 (*.*)|*.*"
        if ($Dialog.ShowDialog($Window) -eq $true) {
            $CustomBox.Text = $Dialog.FileName
        }
    })
    $CancelButton.Add_Click({
        $Window.DialogResult = $false
        $Window.Close()
    })
    $InstallButton.Add_Click({
        try {
            $Candidate = & $GetCandidate
            $Validation = & $GetValidationState $Candidate
            if (-not $Validation.IsValid) {
                & $FocusValidationField $Validation
                return
            }
            Assert-CommonInput $Candidate
            $PreparedTemplate = New-NodeTemplate $Candidate
            $PreparedPort = [int]$PreparedTemplate.port
            if ($PreparedPort -notin $CloudflareHttpsPorts -and
                $UiState.ConfirmedCustomPort -ne $PreparedPort) {
                $Choice = [Windows.MessageBox]::Show(
                    $Window,
                    "端口 $PreparedPort 不在 Cloudflare 普通代理的标准 HTTPS 端口列表中。仍要继续吗？",
                    "确认非标准端口",
                    [Windows.MessageBoxButton]::YesNo,
                    [Windows.MessageBoxImage]::Warning
                )
                if ($Choice -ne [Windows.MessageBoxResult]::Yes) {
                    return
                }
                $UiState.ConfirmedCustomPort = $PreparedPort
            }
            $script:WizardResult = $Candidate
            $Window.DialogResult = $true
            $Window.Close()
        } catch {
            $ValidationSummary.Text = $_.Exception.Message
            $FooterErrorText.Text = $_.Exception.Message
        }
    })

    & $UpdateUi
    $DialogResult = $Window.ShowDialog()
    if ($DialogResult -ne $true) {
        return $null
    }
    return $script:WizardResult
}

function Show-ExistingConfigurationChoice {
    Initialize-WpfRuntime
    $Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Clash Cloudflare Dynamic" Width="680" Height="430"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="{DynamicResource AppBackgroundBrush}"
        FontFamily="Segoe UI Variable Text, Segoe UI"
        FontSize="14" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>
    <SolidColorBrush x:Key="AppBackgroundBrush" Color="#F3F3F3"/>
    <SolidColorBrush x:Key="SurfaceBrush" Color="#FBFBFB"/>
    <SolidColorBrush x:Key="TextBrush" Color="#1A1A1A"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#5D5D5D"/>
    <SolidColorBrush x:Key="DividerBrush" Color="#D0D0D0"/>
    <SolidColorBrush x:Key="SubtleAccentBrush" Color="#E8F3FB"/>
    <SolidColorBrush x:Key="SubtleAccentBorderBrush" Color="#87BDE0"/>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
    </Style>
  </Window.Resources>
  <Grid Margin="30,24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel>
      <TextBlock Text="检测到已有安装" FontSize="23" FontWeight="SemiBold"/>
      <TextBlock Text="选择升级方式。无论选择哪一种，安装器都会先创建事务备份。"
                 Foreground="{DynamicResource MutedBrush}" Margin="0,7,0,0"/>
    </StackPanel>
    <StackPanel Grid.Row="1" Margin="0,24,0,18">
      <Button x:Name="KeepButton" Height="94"
              Background="{DynamicResource SubtleAccentBrush}"
              Foreground="{DynamicResource TextBrush}"
              BorderBrush="{DynamicResource SubtleAccentBorderBrush}"
              BorderThickness="1" HorizontalContentAlignment="Stretch" Cursor="Hand">
        <StackPanel Margin="16,10">
          <TextBlock Text="保留配置并升级（推荐）" FontWeight="SemiBold" FontSize="15"/>
          <TextBlock Text="更新程序和计划任务，保留现有协议、端口、域名与凭据。"
                     Foreground="{DynamicResource MutedBrush}" Margin="0,7,0,0"/>
        </StackPanel>
      </Button>
      <Button x:Name="ReplaceButton" Height="94" Margin="0,12,0,0"
              Background="{DynamicResource SurfaceBrush}"
              Foreground="{DynamicResource TextBrush}"
              BorderBrush="{DynamicResource DividerBrush}" BorderThickness="1"
              HorizontalContentAlignment="Stretch" Cursor="Hand">
        <StackPanel Margin="16,10">
          <TextBlock Text="重新填写节点参数" FontWeight="SemiBold" FontSize="15"/>
          <TextBlock Text="备份旧配置后，重新填写协议、入口端口、SNI 和认证信息。"
                     Foreground="{DynamicResource MutedBrush}" Margin="0,7,0,0"/>
        </StackPanel>
      </Button>
    </StackPanel>
    <Button x:Name="CancelButton" Grid.Row="2" Content="取消" Width="92" Height="36"
            HorizontalAlignment="Right" IsCancel="True"
            Background="{DynamicResource SurfaceBrush}"
            Foreground="{DynamicResource TextBrush}"
            BorderBrush="{DynamicResource DividerBrush}"/>
  </Grid>
</Window>
'@
    $Window = ConvertFrom-WpfXaml $Xaml
    Add-WpfScrollBarResources $Window
    $null = Set-WpfThemeResources $Window $script:PreferredWpfThemeMode
    $KeepButton = $Window.FindName("KeepButton")
    $ReplaceButton = $Window.FindName("ReplaceButton")
    $CancelButton = $Window.FindName("CancelButton")
    $ChoiceState = @{ Value = "cancel" }
    $KeepButton.Add_Click({ $ChoiceState.Value = "keep"; $Window.Close() })
    $ReplaceButton.Add_Click({ $ChoiceState.Value = "replace"; $Window.Close() })
    $CancelButton.Add_Click({ $ChoiceState.Value = "cancel"; $Window.Close() })
    $Window.Add_ContentRendered({ $null = $KeepButton.Focus() })
    $null = $Window.ShowDialog()
    return $ChoiceState.Value
}

function Show-Message([string]$Text, [bool]$Error = $false) {
    if ($NonInteractive) {
        if ($Error) { Write-Error $Text } else { Write-Host $Text }
        return
    }
    Initialize-WpfRuntime
    $Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Clash Cloudflare Dynamic" Width="610" MinHeight="330"
        SizeToContent="Height" WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="{DynamicResource AppBackgroundBrush}"
        FontFamily="Segoe UI Variable Text, Segoe UI"
        FontSize="14" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>
    <SolidColorBrush x:Key="AppBackgroundBrush" Color="#F3F3F3"/>
    <SolidColorBrush x:Key="SurfaceBrush" Color="#FBFBFB"/>
    <SolidColorBrush x:Key="TextBrush" Color="#1A1A1A"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#5D5D5D"/>
    <SolidColorBrush x:Key="DividerBrush" Color="#D8D8D8"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#0067C0"/>
    <SolidColorBrush x:Key="AccentForegroundBrush" Color="#FFFFFF"/>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
    </Style>
  </Window.Resources>
  <Grid Margin="28,24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="46"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border x:Name="IconBorder" Width="38" Height="38" CornerRadius="19"
              Background="{DynamicResource AccentBrush}">
        <TextBlock x:Name="IconText" Text="✓" Foreground="{DynamicResource AccentForegroundBrush}"
                   FontWeight="Bold" FontSize="19"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Grid.Column="1" Margin="10,0,0,0">
        <TextBlock x:Name="TitleText" Text="安装完成" FontSize="21" FontWeight="SemiBold"/>
        <TextBlock x:Name="SubtitleText" Text="程序和计划任务已准备就绪"
                   Foreground="{DynamicResource MutedBrush}" Margin="0,5,0,0"/>
      </StackPanel>
    </Grid>
    <TextBox x:Name="BodyText" Grid.Row="1" Margin="0,24,0,22" MinHeight="120" MaxHeight="230"
             Padding="12" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
             Background="{DynamicResource SurfaceBrush}" Foreground="{DynamicResource TextBrush}"
             BorderBrush="{DynamicResource DividerBrush}" BorderThickness="1"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="CopyButton" Content="复制详情" Width="104" Height="36"
              Background="{DynamicResource SurfaceBrush}" Foreground="{DynamicResource TextBrush}"
              BorderBrush="{DynamicResource DividerBrush}"/>
      <Button x:Name="OkButton" Content="知道了" Width="104" Height="36" Margin="10,0,0,0"
              IsDefault="True" IsCancel="True" Background="{DynamicResource AccentBrush}"
              Foreground="{DynamicResource AccentForegroundBrush}"
              BorderBrush="{DynamicResource AccentBrush}"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $Window = ConvertFrom-WpfXaml $Xaml
    Add-WpfScrollBarResources $Window
    $null = Set-WpfThemeResources $Window $script:PreferredWpfThemeMode
    $IconBorder = $Window.FindName("IconBorder")
    $IconText = $Window.FindName("IconText")
    $TitleText = $Window.FindName("TitleText")
    $SubtitleText = $Window.FindName("SubtitleText")
    $BodyText = $Window.FindName("BodyText")
    $CopyButton = $Window.FindName("CopyButton")
    $OkButton = $Window.FindName("OkButton")
    $BodyText.Text = $Text
    if ($Error) {
        $IconBorder.Background = $Window.Resources["ErrorBorderBrush"]
        $IconText.Text = "!"
        $TitleText.Text = "安装未完成"
        $SubtitleText.Text = "请检查以下信息后重试"
    }
    $CopyButton.Add_Click({
        if (-not [string]::IsNullOrWhiteSpace($Text)) {
            try { [Windows.Clipboard]::SetText($Text) } catch { }
        }
    })
    $OkButton.Add_Click({ $Window.Close() })
    $Window.Add_ContentRendered({ $null = $OkButton.Focus() })
    $null = $Window.ShowDialog()
}
