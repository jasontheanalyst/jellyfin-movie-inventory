[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppName = 'Jellyfin Movie Inventory'
$script:AppVersion = '1.0.3'
$script:DeviceId = [Guid]::NewGuid().ToString('N')
$script:Form = $null
$script:StatusLabel = $null
$script:ProgressBar = $null
$script:LogBox = $null
$script:LogFilePath = Join-Path $PSScriptRoot 'JellyfinMovieInventory.log'

function Initialize-AppLog {
    $header = @(
        ('Jellyfin Movie Inventory v' + $script:AppVersion)
        ('Started: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
        ('PowerShell: ' + $PSVersionTable.PSVersion.ToString())
        ('Windows: ' + [Environment]::OSVersion.VersionString)
        ('Application folder: ' + $PSScriptRoot)
        ('Log file: ' + $script:LogFilePath)
        ('-' * 72)
    ) -join "`r`n"
    try {
        [IO.File]::WriteAllText($script:LogFilePath, ($header + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        $script:LogFilePath = Join-Path ([IO.Path]::GetTempPath()) 'JellyfinMovieInventory.log'
        [IO.File]::WriteAllText($script:LogFilePath, ($header + "`r`nFallback log file: $script:LogFilePath`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
}

Initialize-AppLog

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

function Get-PropertyValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Join-Names {
    param($Items)
    if ($null -eq $Items) { return '' }
    return (@($Items) | ForEach-Object {
        $name = Get-PropertyValue $_ 'Name' ''
        if ($name) { [string]$name }
    } | Where-Object { $_ }) -join '; '
}

function Join-Strings {
    param($Items)
    if ($null -eq $Items) { return '' }
    return (@($Items) | ForEach-Object { if ($null -ne $_) { [string]$_ } } | Where-Object { $_ }) -join '; '
}

function Convert-ToDateOrNull {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $null
}

function Convert-TicksToMinutes {
    param($Ticks)
    if ($null -eq $Ticks) { return $null }
    try { return [Math]::Round(([double]$Ticks / 600000000), 0) } catch { return $null }
}

function Write-AppLog {
    param([string]$Message)
    $timestamp = (Get-Date).ToString('HH:mm:ss')
    $line = "[$timestamp] $Message"
    try {
        [IO.File]::AppendAllText($script:LogFilePath, ($line + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # Logging must never hide the original application error.
    }
    if ($null -ne $script:LogBox) {
        $script:LogBox.AppendText($line + "`r`n")
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Write-DetailedErrorLog {
    param($ErrorRecord)
    if ($null -eq $ErrorRecord) { return }
    Write-AppLog ('Exception type: ' + $ErrorRecord.Exception.GetType().FullName)
    Write-AppLog ('Exception message: ' + $ErrorRecord.Exception.Message)
    if ($ErrorRecord.ScriptStackTrace) {
        Write-AppLog ('Technical location: ' + ($ErrorRecord.ScriptStackTrace -replace "`r?`n", ' | '))
    }
    $details = ($ErrorRecord | Out-String).Trim()
    if ($details) { Write-AppLog ('PowerShell details: ' + ($details -replace "`r?`n", ' | ')) }
}

function Set-AppStatus {
    param([string]$Message, [int]$Percent = -1)
    if ($null -ne $script:StatusLabel) { $script:StatusLabel.Text = $Message }
    if ($null -ne $script:ProgressBar -and $Percent -ge 0) {
        $script:ProgressBar.Value = [Math]::Max(0, [Math]::Min(100, $Percent))
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Normalize-ServerUrl {
    param([string]$ServerUrl)
    $url = $ServerUrl.Trim().TrimEnd('/')
    if (-not ($url -match '^https?://')) { $url = 'http://' + $url }
    $parsed = $null
    if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$parsed)) {
        throw 'The Jellyfin server address is not valid.'
    }
    return $url
}

function Get-AuthorizationHeader {
    param([string]$Token = '')
    $header = 'MediaBrowser Client="Jellyfin Movie Inventory", Device="Windows", DeviceId="{0}", Version="{1}"' -f $script:DeviceId, $script:AppVersion
    if ($Token) { $header += ', Token="' + $Token + '"' }
    return $header
}

function Connect-Jellyfin {
    param([string]$ServerUrl, [string]$Username, [string]$Password)

    $server = Normalize-ServerUrl $ServerUrl
    if ([string]::IsNullOrWhiteSpace($Username)) { throw 'Enter your Jellyfin username.' }
    if ([string]::IsNullOrEmpty($Password)) { throw 'Enter your Jellyfin password.' }

    $authorization = Get-AuthorizationHeader
    $headers = @{
        'Authorization' = $authorization
        'X-Emby-Authorization' = $authorization
        'Accept' = 'application/json'
    }
    $body = @{ Username = $Username; Pw = $Password } | ConvertTo-Json -Compress

    try {
        $response = Invoke-RestMethod -Method Post -Uri ($server + '/Users/AuthenticateByName') -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 30
    } catch {
        if ($_.Exception.Response -and ([int]$_.Exception.Response.StatusCode -eq 401)) {
            throw 'Jellyfin rejected the username or password.'
        }
        throw ('Could not connect to Jellyfin. ' + $_.Exception.Message)
    }

    $token = [string](Get-PropertyValue $response 'AccessToken' '')
    $user = Get-PropertyValue $response 'User'
    $userId = [string](Get-PropertyValue $user 'Id' '')
    if (-not $token -or -not $userId) { throw 'Jellyfin signed in, but did not return a usable user session.' }

    $authWithToken = Get-AuthorizationHeader $token
    return [PSCustomObject]@{
        Server = $server
        UserId = $userId
        DisplayName = [string](Get-PropertyValue $user 'Name' $Username)
        Headers = @{
            'Authorization' = $authWithToken
            'X-Emby-Authorization' = $authWithToken
            'X-Emby-Token' = $token
            'Accept' = 'application/json'
        }
    }
}

function Get-VirtualFolders {
    param($Connection)
    try {
        return @(Invoke-RestMethod -Method Get -Uri ($Connection.Server + '/Library/VirtualFolders') -Headers $Connection.Headers -TimeoutSec 30)
    } catch {
        Write-AppLog 'Library names were unavailable; movie inventory will still be complete.'
        return @()
    }
}

function Resolve-LibraryName {
    param([string]$Path, $VirtualFolders)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $bestName = ''
    $bestLength = -1
    foreach ($folder in @($VirtualFolders)) {
        $folderName = [string](Get-PropertyValue $folder 'Name' '')
        foreach ($location in @(Get-PropertyValue $folder 'Locations' @())) {
            $candidate = ([string]$location).TrimEnd('\', '/')
            if ($candidate -and $Path.StartsWith($candidate, [StringComparison]::OrdinalIgnoreCase) -and $candidate.Length -gt $bestLength) {
                $bestName = $folderName
                $bestLength = $candidate.Length
            }
        }
    }
    return $bestName
}

function Get-ProviderId {
    param($ProviderIds, [string]$Name)
    if ($null -eq $ProviderIds) { return '' }
    $property = $ProviderIds.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Get-MovieRecord {
    param($Item, $VirtualFolders)

    $mediaSources = @(Get-PropertyValue $Item 'MediaSources' @())
    $mediaSource = if ($mediaSources.Count -gt 0) { $mediaSources[0] } else { $null }
    $streams = @(Get-PropertyValue $mediaSource 'MediaStreams' @())
    if ($streams.Count -eq 0) { $streams = @(Get-PropertyValue $Item 'MediaStreams' @()) }
    $video = @($streams | Where-Object { (Get-PropertyValue $_ 'Type' '') -eq 'Video' } | Select-Object -First 1)
    $audio = @($streams | Where-Object { (Get-PropertyValue $_ 'Type' '') -eq 'Audio' } | Select-Object -First 1)
    $subtitles = @($streams | Where-Object { (Get-PropertyValue $_ 'Type' '') -eq 'Subtitle' })
    $videoStream = if ($video.Count -gt 0) { $video[0] } else { $null }
    $audioStream = if ($audio.Count -gt 0) { $audio[0] } else { $null }

    $path = [string](Get-PropertyValue $Item 'Path' '')
    if (-not $path) { $path = [string](Get-PropertyValue $mediaSource 'Path' '') }
    $width = Get-PropertyValue $videoStream 'Width'
    $height = Get-PropertyValue $videoStream 'Height'
    $resolution = ''
    if ($width -and $height) { $resolution = '{0}x{1}' -f $width, $height }

    $videoRange = [string](Get-PropertyValue $videoStream 'VideoRangeType' '')
    if (-not $videoRange) { $videoRange = [string](Get-PropertyValue $videoStream 'VideoRange' '') }
    $hdr = if ($videoRange -and $videoRange -notmatch '^SDR$') { $videoRange } else { 'No' }

    $audioLabel = ''
    if ($null -ne $audioStream) {
        $audioParts = @()
        $language = [string](Get-PropertyValue $audioStream 'Language' '')
        $codec = [string](Get-PropertyValue $audioStream 'Codec' '')
        $channels = Get-PropertyValue $audioStream 'Channels'
        if ($language) { $audioParts += $language.ToUpperInvariant() }
        if ($codec) { $audioParts += $codec.ToUpperInvariant() }
        if ($channels) { $audioParts += ([string]$channels + ' ch') }
        $audioLabel = $audioParts -join ' / '
    }

    $subtitleLanguages = (@($subtitles | ForEach-Object {
        $language = [string](Get-PropertyValue $_ 'Language' '')
        if ($language) { $language.ToUpperInvariant() }
    } | Where-Object { $_ } | Sort-Object -Unique)) -join '; '

    $people = @(Get-PropertyValue $Item 'People' @())
    $directors = Join-Names @($people | Where-Object { (Get-PropertyValue $_ 'Type' '') -eq 'Director' })
    $writers = Join-Names @($people | Where-Object { (Get-PropertyValue $_ 'Type' '') -in @('Writer', 'Screenplay') })
    $userData = Get-PropertyValue $Item 'UserData'
    $played = [bool](Get-PropertyValue $userData 'Played' $false)
    $favorite = [bool](Get-PropertyValue $userData 'IsFavorite' $false)
    $providerIds = Get-PropertyValue $Item 'ProviderIds'
    $size = Get-PropertyValue $mediaSource 'Size'
    $sizeGb = if ($size) { [Math]::Round(([double]$size / 1073741824), 2) } else { $null }

    return [PSCustomObject][ordered]@{
        'Title' = [string](Get-PropertyValue $Item 'Name' '')
        'Year' = Get-PropertyValue $Item 'ProductionYear'
        'Library' = Resolve-LibraryName $path $VirtualFolders
        'Watched Status' = if ($played) { 'Watched' } else { 'Unwatched' }
        'Play Count' = [int](Get-PropertyValue $userData 'PlayCount' 0)
        'Last Played' = Convert-ToDateOrNull (Get-PropertyValue $userData 'LastPlayedDate')
        'Runtime (Minutes)' = Convert-TicksToMinutes (Get-PropertyValue $Item 'RunTimeTicks')
        'Genres' = Join-Strings (Get-PropertyValue $Item 'Genres' @())
        'Directors' = $directors
        'Writers' = $writers
        'Studios' = Join-Names (Get-PropertyValue $Item 'Studios' @())
        'Content Rating' = [string](Get-PropertyValue $Item 'OfficialRating' '')
        'Jellyfin Rating' = Get-PropertyValue $Item 'CommunityRating'
        'Critic Rating' = Get-PropertyValue $Item 'CriticRating'
        'Resolution' = $resolution
        'HDR' = $hdr
        'Video Codec' = ([string](Get-PropertyValue $videoStream 'Codec' '')).ToUpperInvariant()
        'Audio' = $audioLabel
        'Subtitle Languages' = $subtitleLanguages
        'File Size (GB)' = $sizeGb
        'Date Added' = Convert-ToDateOrNull (Get-PropertyValue $Item 'DateCreated')
        'Premiere Date' = Convert-ToDateOrNull (Get-PropertyValue $Item 'PremiereDate')
        'Favorite' = if ($favorite) { 'Yes' } else { 'No' }
        'IMDb ID' = Get-ProviderId $providerIds 'Imdb'
        'TMDb ID' = Get-ProviderId $providerIds 'Tmdb'
        'File Path' = $path
        'Jellyfin ID' = [string](Get-PropertyValue $Item 'Id' '')
        'Overview' = [string](Get-PropertyValue $Item 'Overview' '')
    }
}

function Get-JellyfinMovies {
    param($Connection)

    $virtualFolders = Get-VirtualFolders $Connection
    $allMovies = New-Object System.Collections.Generic.List[object]
    $startIndex = 0
    $pageSize = 500
    $total = 0
    $fields = 'Path,Genres,People,ProviderIds,MediaSources,MediaStreams,DateCreated,Overview,OfficialRating,CommunityRating,CriticRating,ProductionYear,PremiereDate,RunTimeTicks,Studios'

    do {
        $uri = '{0}/Users/{1}/Items?Recursive=true&IncludeItemTypes=Movie&IsVirtualItem=false&EnableUserData=true&Fields={2}&SortBy=SortName&SortOrder=Ascending&StartIndex={3}&Limit={4}' -f $Connection.Server, [Uri]::EscapeDataString($Connection.UserId), $fields, $startIndex, $pageSize
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $Connection.Headers -TimeoutSec 120
        $items = @(Get-PropertyValue $response 'Items' @())
        $total = [int](Get-PropertyValue $response 'TotalRecordCount' $items.Count)

        foreach ($item in $items) { $allMovies.Add((Get-MovieRecord $item $virtualFolders)) }
        $startIndex += $items.Count
        $percent = if ($total -gt 0) { [Math]::Round(($startIndex / $total) * 72) } else { 0 }
        Set-AppStatus ("Reading movies: {0:N0} of {1:N0}" -f $startIndex, $total) $percent
        Write-AppLog ("Retrieved {0:N0} of {1:N0} movies." -f $startIndex, $total)
        if ($items.Count -eq 0) { break }
    } while ($startIndex -lt $total)

    # Windows PowerShell 5.1 can throw "Argument types do not match" when a
    # generic List[object] is wrapped in @(...). Convert it explicitly first.
    return $allMovies.ToArray()
}

function Get-DuplicateRows {
    param($Movies)
    $rows = New-Object System.Collections.Generic.List[object]
    $groups = @($Movies | Group-Object {
        $normalized = ([string]$_.Title).ToLowerInvariant() -replace '[^a-z0-9]', ''
        $normalized + '|' + [string]$_.Year
    } | Where-Object { $_.Count -gt 1 })

    foreach ($group in $groups) {
        foreach ($movie in $group.Group) {
            $rows.Add([PSCustomObject][ordered]@{
                'Title' = $movie.Title
                'Year' = $movie.Year
                'Duplicate Count' = $group.Count
                'Library' = $movie.Library
                'File Path' = $movie.'File Path'
                'Jellyfin ID' = $movie.'Jellyfin ID'
            })
        }
    }
    return $rows.ToArray()
}

function Get-IssueRows {
    param($Movies)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($movie in $Movies) {
        $issues = New-Object System.Collections.Generic.List[string]
        if (-not $movie.Year) { $issues.Add('Missing year') }
        if (-not $movie.'Runtime (Minutes)') { $issues.Add('Missing runtime') }
        if (-not $movie.Genres) { $issues.Add('Missing genres') }
        if (-not $movie.'File Path') { $issues.Add('Missing file path') }
        if (-not $movie.'IMDb ID' -and -not $movie.'TMDb ID') { $issues.Add('Missing IMDb/TMDb ID') }
        if ($issues.Count -gt 0) {
            $rows.Add([PSCustomObject][ordered]@{
                'Title' = $movie.Title
                'Year' = $movie.Year
                'Issues' = $issues -join '; '
                'Library' = $movie.Library
                'File Path' = $movie.'File Path'
                'Jellyfin ID' = $movie.'Jellyfin ID'
            })
        }
    }
    return $rows.ToArray()
}

function Get-RecommendationRows {
    param($Movies)
    $unwatched = @($Movies | Where-Object { $_.'Watched Status' -eq 'Unwatched' } | Sort-Object @{Expression='Jellyfin Rating';Descending=$true}, @{Expression='Date Added';Descending=$true})
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($movie in $unwatched) {
        $rows.Add([PSCustomObject][ordered]@{
            'Queue Rank' = $null
            'Priority' = ''
            'Recommendation Score' = $null
            'Title' = $movie.Title
            'Year' = $movie.Year
            'Runtime (Minutes)' = $movie.'Runtime (Minutes)'
            'Genres' = $movie.Genres
            'Jellyfin Rating' = $movie.'Jellyfin Rating'
            'Date Added' = $movie.'Date Added'
            'Why It Fits' = ''
            'Likely Caveat' = ''
            'Watched Status' = $movie.'Watched Status'
            'Jellyfin ID' = $movie.'Jellyfin ID'
        })
    }
    return $rows.ToArray()
}

function Convert-ToSafeXmlText {
    param($Value)
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $text = [Regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    if ($text.Length -gt 32767) { $text = $text.Substring(0, 32767) }
    return $text
}

function Get-ExcelColumnName {
    param([int]$Number)
    $name = ''
    while ($Number -gt 0) {
        $Number--
        $name = [char](65 + ($Number % 26)) + $name
        $Number = [Math]::Floor($Number / 26)
    }
    return $name
}

function New-XmlWriter {
    param([string]$Path)
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $true
    return [System.Xml.XmlWriter]::Create($Path, $settings)
}

function Write-ExcelCell {
    param($Writer, [string]$Reference, $Value, [int]$Style = 0, [string]$Formula = '')
    if ($null -eq $Value -and -not $Formula) { return }
    $Writer.WriteStartElement('c')
    $Writer.WriteAttributeString('r', $Reference)
    if ($Style -gt 0) { $Writer.WriteAttributeString('s', [string]$Style) }

    if ($Formula) {
        $Writer.WriteElementString('f', $Formula.TrimStart('='))
    } elseif ($Value -is [DateTime]) {
        $Writer.WriteElementString('v', $Value.ToOADate().ToString([Globalization.CultureInfo]::InvariantCulture))
    } elseif ($Value -is [bool]) {
        $Writer.WriteAttributeString('t', 'b')
        $Writer.WriteElementString('v', $(if ($Value) { '1' } else { '0' }))
    } elseif ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        $Writer.WriteElementString('v', ([Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)))
    } else {
        $Writer.WriteAttributeString('t', 'inlineStr')
        $Writer.WriteStartElement('is')
        $Writer.WriteStartElement('t')
        $text = Convert-ToSafeXmlText $Value
        if ($text.StartsWith(' ') -or $text.EndsWith(' ') -or $text.Contains("`n")) {
            $Writer.WriteAttributeString('xml', 'space', $null, 'preserve')
        }
        $Writer.WriteString($text)
        $Writer.WriteEndElement()
        $Writer.WriteEndElement()
    }
    $Writer.WriteEndElement()
}

function Get-ColumnStyle {
    param([string]$Name, $Value)
    if ($Value -is [DateTime]) { return 5 }
    if ($Name -in @('Year', 'Play Count', 'Runtime (Minutes)', 'Duplicate Count', 'Queue Rank')) { return 6 }
    if ($Name -in @('Jellyfin Rating', 'Critic Rating', 'File Size (GB)', 'Recommendation Score')) { return 7 }
    if ($Name -in @('Overview', 'Why It Fits', 'Likely Caveat', 'Issues')) { return 8 }
    if ($Name -in @('Watched Status', 'Favorite', 'HDR', 'Resolution')) { return 9 }
    return 0
}

function Write-DataWorksheet {
    param(
        [string]$Path,
        [string]$Title,
        [string]$Subtitle,
        [string[]]$Columns,
        [double[]]$Widths,
        $Rows
    )
    $writer = New-XmlWriter $Path
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement('worksheet', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
        $writer.WriteAttributeString('xmlns', 'r', $null, 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
        $lastColumn = Get-ExcelColumnName $Columns.Count
        $lastRow = [Math]::Max(4, 4 + @($Rows).Count)
        $writer.WriteStartElement('dimension'); $writer.WriteAttributeString('ref', ('A1:{0}{1}' -f $lastColumn, $lastRow)); $writer.WriteEndElement()
        $writer.WriteStartElement('sheetViews')
        $writer.WriteStartElement('sheetView'); $writer.WriteAttributeString('showGridLines', '0'); $writer.WriteAttributeString('workbookViewId', '0')
        $writer.WriteStartElement('pane'); $writer.WriteAttributeString('ySplit', '4'); $writer.WriteAttributeString('topLeftCell', 'A5'); $writer.WriteAttributeString('activePane', 'bottomLeft'); $writer.WriteAttributeString('state', 'frozen'); $writer.WriteEndElement()
        $writer.WriteEndElement(); $writer.WriteEndElement()
        $writer.WriteStartElement('sheetFormatPr'); $writer.WriteAttributeString('defaultRowHeight', '15'); $writer.WriteEndElement()
        $writer.WriteStartElement('cols')
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $writer.WriteStartElement('col'); $writer.WriteAttributeString('min', [string]($i + 1)); $writer.WriteAttributeString('max', [string]($i + 1)); $writer.WriteAttributeString('width', ([string]$Widths[$i])); $writer.WriteAttributeString('customWidth', '1'); $writer.WriteEndElement()
        }
        $writer.WriteEndElement()
        $writer.WriteStartElement('sheetData')
        $writer.WriteStartElement('row'); $writer.WriteAttributeString('r', '1'); $writer.WriteAttributeString('ht', '28'); $writer.WriteAttributeString('customHeight', '1'); Write-ExcelCell $writer 'A1' $Title 1; $writer.WriteEndElement()
        $writer.WriteStartElement('row'); $writer.WriteAttributeString('r', '2'); $writer.WriteAttributeString('ht', '22'); $writer.WriteAttributeString('customHeight', '1'); Write-ExcelCell $writer 'A2' $Subtitle 2; $writer.WriteEndElement()
        $writer.WriteStartElement('row'); $writer.WriteAttributeString('r', '4'); $writer.WriteAttributeString('ht', '25'); $writer.WriteAttributeString('customHeight', '1')
        for ($i = 0; $i -lt $Columns.Count; $i++) { Write-ExcelCell $writer ((Get-ExcelColumnName ($i + 1)) + '4') $Columns[$i] 4 }
        $writer.WriteEndElement()
        $rowNumber = 5
        foreach ($row in @($Rows)) {
            $writer.WriteStartElement('row'); $writer.WriteAttributeString('r', [string]$rowNumber)
            for ($i = 0; $i -lt $Columns.Count; $i++) {
                $name = $Columns[$i]
                $value = Get-PropertyValue $row $name
                $style = Get-ColumnStyle $name $value
                Write-ExcelCell $writer ((Get-ExcelColumnName ($i + 1)) + [string]$rowNumber) $value $style
            }
            $writer.WriteEndElement()
            $rowNumber++
        }
        $writer.WriteEndElement()
        $writer.WriteStartElement('mergeCells'); $writer.WriteAttributeString('count', '2')
        foreach ($ref in @("A1:$lastColumn`1", "A2:$lastColumn`2")) { $writer.WriteStartElement('mergeCell'); $writer.WriteAttributeString('ref', $ref); $writer.WriteEndElement() }
        $writer.WriteEndElement()
        $writer.WriteStartElement('autoFilter'); $writer.WriteAttributeString('ref', ("A4:$lastColumn$lastRow")); $writer.WriteEndElement()
        $writer.WriteStartElement('pageMargins'); $writer.WriteAttributeString('left', '0.25'); $writer.WriteAttributeString('right', '0.25'); $writer.WriteAttributeString('top', '0.5'); $writer.WriteAttributeString('bottom', '0.5'); $writer.WriteAttributeString('header', '0.2'); $writer.WriteAttributeString('footer', '0.2'); $writer.WriteEndElement()
        $writer.WriteStartElement('pageSetup'); $writer.WriteAttributeString('orientation', 'landscape'); $writer.WriteAttributeString('fitToWidth', '1'); $writer.WriteAttributeString('fitToHeight', '0'); $writer.WriteEndElement()
        $writer.WriteEndElement()
        $writer.WriteEndDocument()
    } finally { $writer.Dispose() }
}

function Write-SummaryWorksheet {
    param([string]$Path, $Movies, $Issues, $Duplicates, [DateTime]$ExportedAt)
    $lastMovieRow = [Math]::Max(5, 4 + @($Movies).Count)
    $lastIssueRow = [Math]::Max(5, 4 + @($Issues).Count)
    $lastDuplicateRow = [Math]::Max(5, 4 + @($Duplicates).Count)
    $libraries = @($Movies | Group-Object Library | Sort-Object Name)
    $genres = @($Movies | ForEach-Object { @($_.Genres -split '; ' | Where-Object { $_ }) } | Group-Object | Sort-Object -Property @{Expression='Count';Descending=$true}, @{Expression='Name';Descending=$false} | Select-Object -First 20)
    $decades = @($Movies | Where-Object { $_.Year } | Group-Object { ([Math]::Floor([int]$_.Year / 10) * 10) } | Sort-Object Name)

    $writer = New-XmlWriter $Path
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement('worksheet', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
        $writer.WriteStartElement('sheetViews'); $writer.WriteStartElement('sheetView'); $writer.WriteAttributeString('showGridLines', '0'); $writer.WriteAttributeString('workbookViewId', '0'); $writer.WriteEndElement(); $writer.WriteEndElement()
        $writer.WriteStartElement('cols')
        foreach ($pair in @(@(1,28),@(2,18),@(3,18),@(4,4),@(5,24),@(6,16))) { $writer.WriteStartElement('col'); $writer.WriteAttributeString('min',[string]$pair[0]); $writer.WriteAttributeString('max',[string]$pair[0]); $writer.WriteAttributeString('width',[string]$pair[1]); $writer.WriteAttributeString('customWidth','1'); $writer.WriteEndElement() }
        $writer.WriteEndElement()
        $writer.WriteStartElement('sheetData')
        $writer.WriteStartElement('row'); $writer.WriteAttributeString('r','1'); $writer.WriteAttributeString('ht','30'); $writer.WriteAttributeString('customHeight','1'); Write-ExcelCell $writer 'A1' 'Jellyfin Movie Inventory' 1; $writer.WriteEndElement()
        $writer.WriteStartElement('row'); $writer.WriteAttributeString('r','2'); Write-ExcelCell $writer 'A2' ('Exported {0} for this Jellyfin user' -f $ExportedAt.ToString('yyyy-MM-dd HH:mm')) 2; $writer.WriteEndElement()
        $metrics = @(
            @('Total movies', "COUNTA('All Movies'!A5:A$lastMovieRow)", 6),
            @('Watched movies', "COUNTIF('All Movies'!D5:D$lastMovieRow,`"Watched`")", 6),
            @('Unwatched movies', "COUNTIF('All Movies'!D5:D$lastMovieRow,`"Unwatched`")", 6),
            @('Percent watched', 'IF(B5=0,0,B6/B5)', 10),
            @('Total runtime (hours)', "SUM('All Movies'!G5:G$lastMovieRow)/60", 7),
            @('Unwatched runtime (hours)', "SUMIF('All Movies'!D5:D$lastMovieRow,`"Unwatched`",'All Movies'!G5:G$lastMovieRow)/60", 7),
            @('Metadata issue rows', "COUNTA('Metadata Issues'!A5:A$lastIssueRow)", 6),
            @('Potential duplicate entries', "COUNTA('Potential Duplicates'!A5:A$lastDuplicateRow)", 6)
        )
        $libraryLastRow = 5 + $libraries.Count
        $sectionRow = [Math]::Max(15, $libraryLastRow + 3)
        $headerRow = $sectionRow + 1
        $detailLastRow = $headerRow + [Math]::Max($decades.Count, $genres.Count)
        $summaryLastRow = [Math]::Max(12, $detailLastRow)

        for ($rowNum = 4; $rowNum -le $summaryLastRow; $rowNum++) {
            $writer.WriteStartElement('row'); $writer.WriteAttributeString('r',[string]$rowNum)
            if ($rowNum -eq 4) {
                Write-ExcelCell $writer 'A4' 'Inventory Snapshot' 3
                Write-ExcelCell $writer 'E4' 'Library Summary' 3
            }
            if ($rowNum -ge 5 -and $rowNum -le 12) {
                $metric = $metrics[$rowNum - 5]
                Write-ExcelCell $writer ('A'+$rowNum) $metric[0] 0
                Write-ExcelCell $writer ('B'+$rowNum) $null ([int]$metric[2]) ([string]$metric[1])
            }
            if ($rowNum -eq 5) {
                Write-ExcelCell $writer 'E5' 'Library' 4
                Write-ExcelCell $writer 'F5' 'Movies' 4
            } elseif ($rowNum -ge 6 -and $rowNum -le $libraryLastRow) {
                $library = $libraries[$rowNum - 6]
                $libraryName = if ([string]::IsNullOrWhiteSpace($library.Name)) { '(Unresolved)' } else { $library.Name }
                Write-ExcelCell $writer ('E'+$rowNum) $libraryName 0
                Write-ExcelCell $writer ('F'+$rowNum) $library.Count 6
            }
            if ($rowNum -eq $sectionRow) {
                Write-ExcelCell $writer ('A'+$rowNum) 'Movies by Decade' 3
                Write-ExcelCell $writer ('E'+$rowNum) 'Top Genres' 3
            } elseif ($rowNum -eq $headerRow) {
                Write-ExcelCell $writer ('A'+$rowNum) 'Decade' 4
                Write-ExcelCell $writer ('B'+$rowNum) 'Movies' 4
                Write-ExcelCell $writer ('E'+$rowNum) 'Genre' 4
                Write-ExcelCell $writer ('F'+$rowNum) 'Movies' 4
            } elseif ($rowNum -gt $headerRow) {
                $index = $rowNum - $headerRow - 1
                if ($index -lt $decades.Count) {
                    Write-ExcelCell $writer ('A'+$rowNum) ([string]$decades[$index].Name + 's') 0
                    Write-ExcelCell $writer ('B'+$rowNum) $decades[$index].Count 6
                }
                if ($index -lt $genres.Count) {
                    Write-ExcelCell $writer ('E'+$rowNum) $genres[$index].Name 0
                    Write-ExcelCell $writer ('F'+$rowNum) $genres[$index].Count 6
                }
            }
            $writer.WriteEndElement()
        }
        $writer.WriteEndElement()
        $writer.WriteStartElement('mergeCells'); $writer.WriteAttributeString('count','2'); foreach($ref in @('A1:F1','A2:F2')) { $writer.WriteStartElement('mergeCell'); $writer.WriteAttributeString('ref',$ref); $writer.WriteEndElement() }; $writer.WriteEndElement()
        $writer.WriteStartElement('pageMargins'); $writer.WriteAttributeString('left','0.5'); $writer.WriteAttributeString('right','0.5'); $writer.WriteAttributeString('top','0.5'); $writer.WriteAttributeString('bottom','0.5'); $writer.WriteAttributeString('header','0.2'); $writer.WriteAttributeString('footer','0.2'); $writer.WriteEndElement()
        $writer.WriteEndElement(); $writer.WriteEndDocument()
    } finally { $writer.Dispose() }
}

function Write-PackageXmlFiles {
    param([string]$Root, [string[]]$SheetNames)
    New-Item -ItemType Directory -Path (Join-Path $Root '_rels') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'docProps') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'xl') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'xl\_rels') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'xl\worksheets') -Force | Out-Null

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $overrides = for ($i=1; $i -le $SheetNames.Count; $i++) { '<Override PartName="/xl/worksheets/sheet{0}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' -f $i }
    $contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>' + ($overrides -join '') + '</Types>'
    [IO.File]::WriteAllText((Join-Path $Root '[Content_Types].xml'), $contentTypes, $utf8)
    [IO.File]::WriteAllText((Join-Path $Root '_rels\.rels'), '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>', $utf8)

    $escapedSheetNames = @($SheetNames | ForEach-Object { [Security.SecurityElement]::Escape($_) })
    $sheetElements = for ($i=0; $i -lt $SheetNames.Count; $i++) { '<sheet name="{0}" sheetId="{1}" r:id="rId{1}"/>' -f $escapedSheetNames[$i], ($i+1) }
    $workbookXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView xWindow="0" yWindow="0" windowWidth="24000" windowHeight="15000"/></bookViews><sheets>' + ($sheetElements -join '') + '</sheets><calcPr calcId="191029" calcMode="auto" fullCalcOnLoad="1" forceFullCalc="1"/></workbook>'
    [IO.File]::WriteAllText((Join-Path $Root 'xl\workbook.xml'), $workbookXml, $utf8)

    $relationships = for ($i=1; $i -le $SheetNames.Count; $i++) { '<Relationship Id="rId{0}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{0}.xml"/>' -f $i }
    $relationships += '<Relationship Id="rId{0}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' -f ($SheetNames.Count + 1)
    [IO.File]::WriteAllText((Join-Path $Root 'xl\_rels\workbook.xml.rels'), ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + ($relationships -join '') + '</Relationships>'), $utf8)

    $styles = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <numFmts count="3"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/><numFmt numFmtId="165" formatCode="0.00"/><numFmt numFmtId="166" formatCode="0.0%"/></numFmts>
  <fonts count="4"><font><sz val="10"/><name val="Aptos"/></font><font><b/><sz val="18"/><color rgb="FFFFFFFF"/><name val="Aptos Display"/></font><font><i/><sz val="10"/><color rgb="FF475569"/><name val="Aptos"/></font><font><b/><sz val="10"/><color rgb="FFFFFFFF"/><name val="Aptos"/></font></fonts>
  <fills count="5"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF16243A"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FF0F766E"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFE2E8F0"/><bgColor indexed="64"/></patternFill></fill></fills>
  <borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top/><bottom style="thin"><color rgb="FFCBD5E1"/></bottom><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="11">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top"/></xf>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center"/></xf>
    <xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf>
    <xf numFmtId="0" fontId="3" fillId="3" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center"/></xf>
    <xf numFmtId="0" fontId="3" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>
    <xf numFmtId="164" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment vertical="top"/></xf>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="top"/></xf>
    <xf numFmtId="165" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="top"/></xf>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top"/></xf>
    <xf numFmtId="166" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="top"/></xf>
  </cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>
'@
    [IO.File]::WriteAllText((Join-Path $Root 'xl\styles.xml'), $styles.Trim(), $utf8)
    $now = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
    [IO.File]::WriteAllText((Join-Path $Root 'docProps\core.xml'), ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:creator>Jellyfin Movie Inventory</dc:creator><cp:lastModifiedBy>Jellyfin Movie Inventory</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">' + $now + '</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">' + $now + '</dcterms:modified></cp:coreProperties>'), $utf8)
    [IO.File]::WriteAllText((Join-Path $Root 'docProps\app.xml'), ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Jellyfin Movie Inventory</Application><DocSecurity>0</DocSecurity><ScaleCrop>false</ScaleCrop><HeadingPairs><vt:vector size="2" baseType="variant"><vt:variant><vt:lpstr>Worksheets</vt:lpstr></vt:variant><vt:variant><vt:i4>' + $SheetNames.Count + '</vt:i4></vt:variant></vt:vector></HeadingPairs><TitlesOfParts><vt:vector size="' + $SheetNames.Count + '" baseType="lpstr">' + (($escapedSheetNames | ForEach-Object { '<vt:lpstr>' + $_ + '</vt:lpstr>' }) -join '') + '</vt:vector></TitlesOfParts><Company></Company><LinksUpToDate>false</LinksUpToDate><SharedDoc>false</SharedDoc><HyperlinksChanged>false</HyperlinksChanged><AppVersion>16.0300</AppVersion></Properties>'), $utf8)
}

function New-XlsxArchive {
    param([string]$SourceRoot, [string]$DestinationPath)

    # ZipFile.CreateFromDirectory used Windows path separators inside the ZIP on
    # some Windows PowerShell/.NET combinations. XLSX requires forward slashes.
    $fileStream = [IO.File]::Open($DestinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $archive = $null
    try {
        $archive = New-Object IO.Compression.ZipArchive($fileStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        foreach ($file in @(Get-ChildItem -LiteralPath $SourceRoot -File -Recurse | Sort-Object FullName)) {
            $entryName = $file.FullName.Substring($SourceRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
            $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
            $sourceStream = $null
            $entryStream = $null
            try {
                $sourceStream = [IO.File]::OpenRead($file.FullName)
                $entryStream = $entry.Open()
                $sourceStream.CopyTo($entryStream)
            } finally {
                if ($null -ne $entryStream) { $entryStream.Dispose() }
                if ($null -ne $sourceStream) { $sourceStream.Dispose() }
            }
        }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $fileStream.Dispose()
    }
}

function Test-XlsxArchive {
    param([string]$Path)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })
        Write-AppLog ('Workbook ZIP entries: ' + ($entryNames -join ', '))
        $backslashEntries = @($entryNames | Where-Object { $_ -match '\\' })
        if ($backslashEntries.Count -gt 0) {
            throw ('Workbook validation failed: invalid backslash ZIP entries: ' + ($backslashEntries -join ', '))
        }
        $requiredEntries = @('[Content_Types].xml','_rels/.rels','xl/workbook.xml','xl/_rels/workbook.xml.rels','xl/styles.xml','xl/worksheets/sheet1.xml','xl/worksheets/sheet7.xml')
        foreach ($entryName in $requiredEntries) {
            $entry = $archive.GetEntry($entryName)
            if ($null -eq $entry -or $entry.Length -eq 0) { throw ('Workbook validation failed: missing ' + $entryName) }
        }
    } finally { $archive.Dispose() }
}

function Export-MovieWorkbook {
    param([string]$OutputPath, $Movies, [string]$JellyfinUser)
    Write-AppLog 'Preparing watched, duplicate, issue, and recommendation views.'
    $unwatched = @($Movies | Where-Object { $_.'Watched Status' -eq 'Unwatched' })
    $watched = @($Movies | Where-Object { $_.'Watched Status' -eq 'Watched' })
    $duplicates = @(Get-DuplicateRows $Movies)
    $issues = @(Get-IssueRows $Movies)
    $recommendations = @(Get-RecommendationRows $Movies)
    $sheetNames = @('Summary','All Movies','Unwatched Movies','Watched Movies','Potential Duplicates','Metadata Issues','Recommendation Queue')
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('JellyfinInventory_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $completed = $false
    Write-AppLog ('Temporary workbook folder: ' + $tempRoot)

    try {
        Set-AppStatus 'Building Excel workbook...' 76
        Write-PackageXmlFiles $tempRoot $sheetNames
        $allColumns = @('Title','Year','Library','Watched Status','Play Count','Last Played','Runtime (Minutes)','Genres','Directors','Writers','Studios','Content Rating','Jellyfin Rating','Critic Rating','Resolution','HDR','Video Codec','Audio','Subtitle Languages','File Size (GB)','Date Added','Premiere Date','Favorite','IMDb ID','TMDb ID','File Path','Jellyfin ID','Overview')
        $allWidths = @(34,9,18,15,11,14,17,28,24,24,22,14,14,13,13,10,13,19,20,14,14,14,10,15,15,55,34,70)
        Write-SummaryWorksheet (Join-Path $tempRoot 'xl\worksheets\sheet1.xml') $Movies $issues $duplicates (Get-Date)
        Write-DataWorksheet (Join-Path $tempRoot 'xl\worksheets\sheet2.xml') 'All Movies' ("{0:N0} movies exported for {1}" -f $Movies.Count, $JellyfinUser) $allColumns $allWidths $Movies
        Set-AppStatus 'Writing unwatched and watched sheets...' 82
        Write-DataWorksheet (Join-Path $tempRoot 'xl\worksheets\sheet3.xml') 'Unwatched Movies' ("{0:N0} movies waiting patiently - or judging you." -f $unwatched.Count) $allColumns $allWidths $unwatched
        Write-DataWorksheet (Join-Path $tempRoot 'xl\worksheets\sheet4.xml') 'Watched Movies' ("{0:N0} movies marked watched for this Jellyfin user." -f $watched.Count) $allColumns $allWidths $watched
        $dupColumns = @('Title','Year','Duplicate Count','Library','File Path','Jellyfin ID')
        Write-DataWorksheet (Join-Path $tempRoot 'xl\worksheets\sheet5.xml') 'Potential Duplicates' 'Same normalized title and year. Review before deleting anything.' $dupColumns @(34,9,16,18,70,34) $duplicates
        $issueColumns = @('Title','Year','Issues','Library','File Path','Jellyfin ID')
        Write-DataWorksheet (Join-Path $tempRoot 'xl\worksheets\sheet6.xml') 'Metadata Issues' 'Missing fields worth reviewing in Jellyfin metadata.' $issueColumns @(34,9,36,18,70,34) $issues
        $recColumns = @('Queue Rank','Priority','Recommendation Score','Title','Year','Runtime (Minutes)','Genres','Jellyfin Rating','Date Added','Why It Fits','Likely Caveat','Watched Status','Jellyfin ID')
        Write-DataWorksheet (Join-Path $tempRoot 'xl\worksheets\sheet7.xml') 'Recommendation Queue' 'All unwatched films, ready for the recommendation phase. Score and notes are intentionally blank.' $recColumns @(12,12,21,34,9,17,28,14,14,45,40,15,34) $recommendations

        Set-AppStatus 'Finalizing Excel file...' 94
        $parent = Split-Path -Parent $OutputPath
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
        Write-AppLog 'Packaging XLSX with normalized forward-slash entry names.'
        New-XlsxArchive $tempRoot $OutputPath
        Test-XlsxArchive $OutputPath
        $completed = $true
        return [PSCustomObject]@{ Movies=$Movies.Count; Watched=$watched.Count; Unwatched=$unwatched.Count; Issues=$issues.Count; Duplicates=$duplicates.Count }
    } finally {
        if ($completed) {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        } else {
            Write-AppLog ('Export did not complete. Temporary workbook files preserved at: ' + $tempRoot)
            if (Test-Path -LiteralPath $OutputPath) { Write-AppLog ('Failed XLSX package preserved at: ' + $OutputPath) }
        }
    }
}

function Show-ErrorMessage {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show($script:Form, $Message, $script:AppName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 22)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text; $label.Location = New-Object Drawing.Point($X,$Y); $label.Size = New-Object Drawing.Size($Width,$Height)
    return $label
}

$form = New-Object System.Windows.Forms.Form
$script:Form = $form
$form.Text = $script:AppName + ' v' + $script:AppVersion
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(790,675)
$form.MinimumSize = New-Object Drawing.Size(790,675)
$form.Font = New-Object Drawing.Font('Segoe UI',10)
$form.BackColor = [Drawing.Color]::FromArgb(246,248,251)

$title = New-Label 'Jellyfin Movie Inventory' 28 22 600 38
$title.Font = New-Object Drawing.Font('Segoe UI Semibold',20)
$title.ForeColor = [Drawing.Color]::FromArgb(22,36,58)
$form.Controls.Add($title)
$subtitle = New-Label 'Turn the movie hoard into an Excel workbook - and eventually, a watchlist with standards.' 30 64 710 28
$subtitle.ForeColor = [Drawing.Color]::FromArgb(71,85,105)
$form.Controls.Add($subtitle)

$serverLabel = New-Label 'Jellyfin server' 30 113 160
$form.Controls.Add($serverLabel)
$serverBox = New-Object System.Windows.Forms.TextBox
$serverBox.Location = New-Object Drawing.Point(190,109); $serverBox.Size = New-Object Drawing.Size(540,28); $serverBox.Text = 'http://localhost:8096'
$form.Controls.Add($serverBox)

$userLabel = New-Label 'Username' 30 153 160
$form.Controls.Add($userLabel)
$userBox = New-Object System.Windows.Forms.TextBox
$userBox.Location = New-Object Drawing.Point(190,149); $userBox.Size = New-Object Drawing.Size(540,28); $userBox.Text = ''
$form.Controls.Add($userBox)

$passwordLabel = New-Label 'Password' 30 193 160
$form.Controls.Add($passwordLabel)
$passwordBox = New-Object System.Windows.Forms.TextBox
$passwordBox.Location = New-Object Drawing.Point(190,189); $passwordBox.Size = New-Object Drawing.Size(540,28); $passwordBox.UseSystemPasswordChar = $true
$form.Controls.Add($passwordBox)

$outputLabel = New-Label 'Excel output' 30 233 160
$form.Controls.Add($outputLabel)
$outputBox = New-Object System.Windows.Forms.TextBox
$outputBox.Location = New-Object Drawing.Point(190,229); $outputBox.Size = New-Object Drawing.Size(455,28); $outputBox.Text = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Jellyfin Movie Inventory.xlsx'
$form.Controls.Add($outputBox)
$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = 'Browse...'; $browseButton.Location = New-Object Drawing.Point(654,227); $browseButton.Size = New-Object Drawing.Size(76,32)
$form.Controls.Add($browseButton)

$security = New-Label 'Security: your password is never saved. On an HTTP server, it still travels unencrypted across your local network.' 30 273 710 38
$security.ForeColor = [Drawing.Color]::FromArgb(180,83,9)
$form.Controls.Add($security)

$testButton = New-Object System.Windows.Forms.Button
$testButton.Text = 'Test Connection'; $testButton.Location = New-Object Drawing.Point(30,320); $testButton.Size = New-Object Drawing.Size(140,40)
$form.Controls.Add($testButton)
$exportButton = New-Object System.Windows.Forms.Button
$exportButton.Text = 'Export Movie Inventory'; $exportButton.Location = New-Object Drawing.Point(180,320); $exportButton.Size = New-Object Drawing.Size(200,40)
$exportButton.BackColor = [Drawing.Color]::FromArgb(15,118,110); $exportButton.ForeColor = [Drawing.Color]::White; $exportButton.FlatStyle = 'Flat'
$form.Controls.Add($exportButton)
$openButton = New-Object System.Windows.Forms.Button
$openButton.Text = 'Open Excel File'; $openButton.Location = New-Object Drawing.Point(390,320); $openButton.Size = New-Object Drawing.Size(160,40); $openButton.Enabled = $false
$form.Controls.Add($openButton)
$openLogButton = New-Object System.Windows.Forms.Button
$openLogButton.Text = 'Open Log File'; $openLogButton.Location = New-Object Drawing.Point(560,320); $openLogButton.Size = New-Object Drawing.Size(170,40)
$form.Controls.Add($openLogButton)

$progress = New-Object System.Windows.Forms.ProgressBar
$script:ProgressBar = $progress
$progress.Location = New-Object Drawing.Point(30,382); $progress.Size = New-Object Drawing.Size(700,18); $progress.Style = 'Continuous'
$form.Controls.Add($progress)
$status = New-Label 'Ready.' 30 407 700 26
$script:StatusLabel = $status
$status.Font = New-Object Drawing.Font('Segoe UI Semibold',10)
$form.Controls.Add($status)

$log = New-Object System.Windows.Forms.TextBox
$script:LogBox = $log
$log.Location = New-Object Drawing.Point(30,440); $log.Size = New-Object Drawing.Size(700,150); $log.Multiline = $true; $log.ScrollBars = 'Vertical'; $log.ReadOnly = $true
$log.BackColor = [Drawing.Color]::White; $log.Font = New-Object Drawing.Font('Consolas',9)
$form.Controls.Add($log)

$footer = New-Label 'Exports: Summary | All | Unwatched | Watched | Duplicates | Issues | Recommendation Queue' 30 604 710 24
$footer.ForeColor = [Drawing.Color]::FromArgb(71,85,105)
$form.Controls.Add($footer)

$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'Excel Workbook (*.xlsx)|*.xlsx'
    $dialog.FileName = [IO.Path]::GetFileName($outputBox.Text)
    $dialog.InitialDirectory = Split-Path -Parent $outputBox.Text
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $outputBox.Text = $dialog.FileName }
})

$testButton.Add_Click({
    $testButton.Enabled = $false; $exportButton.Enabled = $false
    try {
        Set-AppStatus 'Testing Jellyfin connection...' 5
        $connection = Connect-Jellyfin $serverBox.Text $userBox.Text $passwordBox.Text
        $passwordBox.Clear()
        Set-AppStatus ('Connected as ' + $connection.DisplayName + '.') 0
        Write-AppLog ('Connection successful for ' + $connection.DisplayName + '. Password cleared.')
        [System.Windows.Forms.MessageBox]::Show($form, ('Connected successfully as {0}. The password field has been cleared.' -f $connection.DisplayName), $script:AppName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        Set-AppStatus 'Connection failed.' 0
        Write-DetailedErrorLog $_
        Show-ErrorMessage $_.Exception.Message
    } finally { $testButton.Enabled = $true; $exportButton.Enabled = $true }
})

$exportButton.Add_Click({
    $testButton.Enabled = $false; $exportButton.Enabled = $false; $browseButton.Enabled = $false; $openButton.Enabled = $false
    try {
        if ([string]::IsNullOrWhiteSpace($outputBox.Text)) { throw 'Choose an Excel output file.' }
        if ([IO.Path]::GetExtension($outputBox.Text) -ne '.xlsx') { $outputBox.Text += '.xlsx' }
        Set-AppStatus 'Signing into Jellyfin...' 3
        Write-AppLog 'Starting inventory export.'
        $connection = Connect-Jellyfin $serverBox.Text $userBox.Text $passwordBox.Text
        $passwordBox.Clear()
        Write-AppLog ('Connected as ' + $connection.DisplayName + '. Password cleared from the app.')
        $movies = @(Get-JellyfinMovies $connection)
        if ($movies.Count -eq 0) { throw 'Jellyfin returned zero movies for this user.' }
        Write-AppLog ("Movie retrieval complete. Building workbook from {0:N0} records." -f $movies.Count)
        $result = Export-MovieWorkbook $outputBox.Text $movies $connection.DisplayName
        Set-AppStatus ("Finished: {0:N0} movies, {1:N0} unwatched." -f $result.Movies, $result.Unwatched) 100
        Write-AppLog ("Excel file created: {0}" -f $outputBox.Text)
        Write-AppLog ("Watched {0:N0}; unwatched {1:N0}; issue rows {2:N0}; duplicate entries {3:N0}." -f $result.Watched, $result.Unwatched, $result.Issues, $result.Duplicates)
        $openButton.Enabled = $true
        [System.Windows.Forms.MessageBox]::Show($form, ("Done. Exported {0:N0} movies to:`r`n{1}" -f $result.Movies, $outputBox.Text), $script:AppName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        Set-AppStatus 'Export failed.' 0
        Write-DetailedErrorLog $_
        Show-ErrorMessage ($_.Exception.Message + "`r`n`r`nFull log:`r`n" + $script:LogFilePath)
    } finally { $testButton.Enabled = $true; $exportButton.Enabled = $true; $browseButton.Enabled = $true }
})

$openButton.Add_Click({
    if (Test-Path -LiteralPath $outputBox.Text) { Start-Process -FilePath $outputBox.Text }
})

$openLogButton.Add_Click({
    if (Test-Path -LiteralPath $script:LogFilePath) { Start-Process -FilePath $script:LogFilePath }
})

$form.Add_Shown({
    $passwordBox.Focus()
    Write-AppLog 'Ready. Server and username are prefilled; password is not stored.'
    Write-AppLog ('Persistent log file: ' + $script:LogFilePath)
})
[void]$form.ShowDialog()
