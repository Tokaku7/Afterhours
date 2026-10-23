function Get-GameTint([string]$Name){
 $tones=if($script:gameTones){$script:gameTones}else{@(@('#DDE7E1','#AEBFB5','#42574B'),@('#EEE5DA','#CDBDA9','#625548'),@('#E6E2EA','#C2B8CA','#574E61'))}
 $sum=0;foreach($character in $Name.ToCharArray()){$sum+=[int]$character}
 return ,$tones[$sum%$tones.Count]
}
function New-DayCard([string]$Date){
 [xml]$markup=@'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Name="CardRoot" Width="376" Padding="16" CornerRadius="20" BorderThickness="1">
 <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#80FFFFFF" Offset="0"/><GradientStop Color="#80E5E7E3" Offset="0.58"/><GradientStop Color="#80F1EEE8" Offset="1"/></LinearGradientBrush></Border.Background>
 <Border.BorderBrush><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#FFFFFFFF" Offset="0"/><GradientStop Color="#A5B4BCB8" Offset="1"/></LinearGradientBrush></Border.BorderBrush>
 <Border.Resources><Style TargetType="TextBlock"><Setter Property="FontFamily" Value="Microsoft YaHei UI"/><Setter Property="Foreground" Value="#303B39"/></Style></Border.Resources>
 <StackPanel>
  <Grid Margin="0,0,0,16"><TextBlock Name="Date" FontSize="16" FontWeight="SemiBold"/><Border Name="SourceBadge" HorizontalAlignment="Right" Background="#66FFFFFF" BorderBrush="#80ADB7B1" BorderThickness="1" CornerRadius="5" Padding="7,3"><TextBlock Name="Source" FontSize="12" Foreground="#65716C"/></Border></Grid>
  <Grid Margin="0,0,0,16"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="前台时长" FontSize="12" Foreground="#687570"/><TextBlock Name="FrontTotal" FontFamily="Segoe UI" FontSize="25" FontWeight="SemiBold" Margin="0,3,0,0"/></StackPanel><StackPanel Grid.Column="1" Margin="14,0,0,0"><TextBlock Text="运行时长" FontSize="12" Foreground="#687570"/><TextBlock Name="RunTotal" FontFamily="Segoe UI" FontSize="25" FontWeight="SemiBold" Margin="0,3,0,0"/></StackPanel></Grid>
  <Border BorderBrush="#40A7B2AC" BorderThickness="0,1,0,0" Padding="0,12,0,0"><StackPanel>
   <Grid Margin="0,0,0,6"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="78"/><ColumnDefinition Width="78"/></Grid.ColumnDefinitions><TextBlock Text="游戏" Foreground="#687570" FontSize="12"/><TextBlock Text="前台" Grid.Column="1" Foreground="#687570" FontSize="12" HorizontalAlignment="Right"/><TextBlock Text="运行" Grid.Column="2" Foreground="#687570" FontSize="12" HorizontalAlignment="Right"/></Grid>
   <StackPanel Name="Rows"/>
  </StackPanel></Border>
 </StackPanel>
</Border>
'@
 $card=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($markup))
 if($script:cardBackground){$card.Background=$script:cardBackground;$card.BorderBrush=$script:glassBorder}
 $source=if($script:isDemo){$demoRecords}else{$records}
 $rows=@($source.Values|Where-Object {$_.Date -eq $Date -and (-not $script:selectedGame -or $_.Name -eq $script:selectedGame)})
 $card.FindName('Date').Text=([datetime]$Date).ToString('M 月 d 日 · ddd')
 $card.FindName('Source').Text=if($script:isDemo){'示例数据'}else{'实测记录'}
 $card.FindName('FrontTotal').Text=Format-CompactDuration ([double](($rows|Measure-Object Foreground -Sum).Sum))
 $card.FindName('RunTotal').Text=Format-CompactDuration ([double](($rows|Measure-Object Running -Sum).Sum))
 foreach($group in @($rows|Group-Object Name|Sort-Object Name)){
  [xml]$rowMarkup=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" MinHeight="40" Margin="0,2,0,2"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="78"/><ColumnDefinition Width="78"/></Grid.ColumnDefinitions>
 <Border Name="Chip" CornerRadius="6" BorderThickness="1" Padding="7,5" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="0,0,10,0"><TextBlock Name="Game" FontSize="12" TextWrapping="Wrap" MaxWidth="152"/></Border>
 <TextBlock Name="Front" Grid.Column="1" FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
 <TextBlock Name="Run" Grid.Column="2" FontFamily="Segoe UI" FontSize="13" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#687570"/>
</Grid>
'@
  $row=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($rowMarkup))
  $tone=Get-GameTint $group.Name
  $row.FindName('Chip').Background=$tone[0];$row.FindName('Chip').BorderBrush=$tone[1]
  $row.FindName('Game').Text=$group.Name;$row.FindName('Game').Foreground=$tone[2]
  $row.FindName('Front').Text=Format-CompactDuration ([double](($group.Group|Measure-Object Foreground -Sum).Sum))
  $row.FindName('Run').Text=Format-CompactDuration ([double](($group.Group|Measure-Object Running -Sum).Sum))
  [void]$card.FindName('Rows').Children.Add($row)
 }
 if(-not $rows.Count){$empty=[Windows.Controls.TextBlock]::new();$empty.Text='当天暂无记录';$empty.FontSize=11;$empty.Margin='0,10,0,0';[void]$card.FindName('Rows').Children.Add($empty)}
 if(Get-Command Set-ThemeText -ErrorAction SilentlyContinue){Set-ThemeText $card;foreach($group in @($rows|Group-Object Name)){$null=$group}}
 return $card
}
function New-DayTooltip([string]$Date){
 $tip=[Windows.Controls.ToolTip]::new()
 $tip.Content=New-DayCard $Date
 $tip.Background=[Windows.Media.Brushes]::Transparent;$tip.BorderThickness=0;$tip.Padding=0
 $tip.HasDropShadow=$false
 [xml]$template='<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="ToolTip"><ContentPresenter/></ControlTemplate>'
 $tip.Template=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($template))
 $tip.Add_Loaded({param($sender,$eventArgs) $source=[Windows.Interop.HwndSource]::FromVisual($sender);if($source){[DesktopLayer]::BlurPopup($source.Handle)};if(Get-Command Set-ThemeText -ErrorAction SilentlyContinue){Set-ThemeText $sender.Content}})
 [Windows.Automation.AutomationProperties]::SetHelpText($tip,(Get-DayTooltip $Date))
 return $tip
}
