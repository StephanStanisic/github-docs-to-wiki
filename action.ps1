#!/usr/bin/env pwsh

[cmdletbinding()]
param()

if (-not (Get-Module -ListAvailable GitHubActions)) {
    Install-Module GitHubActions -Force
}

Import-Module GitHubActions

$githubToken = Get-ActionInput githubToken -Required
$defaultBranch  = Get-ActionInput defaultBranch
$rootDocsFolder = Get-ActionInput rootDocsFolder
$convertRootReadmeToHomePage = Get-ActionInput convertRootReadmeToHomePage
$useHeaderForWikiName = Get-ActionInput useHeaderForWikiName
$customWikiFileHeaderFormat = Get-ActionInput customWikiFileHeaderFormat
$customCommitMessageFormat = Get-ActionInput customCommitMessageFormat

$repositoryName = $env:GITHUB_REPOSITORY

$repositoryUrl = "https://github.com/$repositoryName"
$repositoryCloneUrl = "https://$githubToken@github.com/$repositoryName"

$wikiRepoDirectory = ($repositoryName -split "/")[-1] + ".wiki"

$sourceRepoDirectory = $pwd.Path

if (-not $defaultBranch)
{
    $defaultBranch = git branch --show-current
}

if (-not $rootDocsFolder)
{
    $rootDocsFolder = "."
    $rootDocsFolderDirs = @()
}
else
{
    $rootDocsFolderDirs = $rootDocsFolder -split "/"
}

$filenameToWikiNameMap = @{}
$wikiNameToFileNameMap = @{}

Function ProcessSourceDirectory()
{
    [cmdletbinding()]
    param([string[]]$directories=@())

    Write-ActionInfo "Processing source directory.. $directories"

    foreach ($file in Get-ChildItem "*.md")
    {
        Write-ActionInfo "Process file $file"
        ProcessSourceFile $file $directories
    }
    foreach ($file in Get-ChildItem -Path "plantuml-images" -Include "*.png" -Recurse -Force)
    {
        Write-ActionInfo "Process image $file"
        ProcessAssetFile $file $directories
    }

    foreach ($dir in Get-ChildItem -Directory)
    {
        Push-Location $dir.Name

        ProcessSourceDirectory ($directories + @($dir.Name))

        Pop-Location
    }
}

Function ProcessSourceFile()
{
    [cmdletbinding()]
    param($file, [string[]]$directories)

    Write-Verbose "Processing file $($file.FullName)"

    $outputFileName = ($directories + $file.Name) -join "__"

    $content = Get-Content -Path $file.FullName
    $content = UpdateFileLinks $file.Name $directories $content

    $override = GetOutputFileNameFromFile $content

    if ($convertRootReadmeToHomePage -and ($directories.Count -eq 0) -and ($file.Name -eq "readme.md"))
    {
        $outputFileName = "Home.md"
    }
    elseif ($override)
    {
        Write-Verbose "Using overridden file name $($override.FileName)"

        if ($wikiNameToFileNameMap[$override.FileName])
        {
            throw "Overridden file name $($override.FileName) is already in use by $($wikiNameToFileNameMap[$override.FileName])"
        }
        $wikiNameToFileNameMap[$override.FileName] = $outputFileName

        $filenameToWikiNameMap[$outputFileName] = $override.FileName
        $outputFileName = $override.FileName        

        $content = $override.NewContent
    }

    if ($customWikiFileHeaderFormat -and ($file.Name -ne "_sidebar.md"))
    {
        $content = AddCustomHeader $file.Name $directories $content
    }

    $outputPath = $wikiRepoPath + "/" + $outputFileName

    $content | Set-Content -Path $outputPath
}

Function ProcessAssetFile()
{
    [cmdletbinding()]
    param($file, [string[]]$directories)

    Write-Verbose "Processing file $($file.FullName)"

    $outputFileName = ($directories + $file.Name) -join "/"
    $content = Get-Content -Path $file.FullName
    $outputPath = $wikiRepoPath + "/plantuml-images/" + $outputFileName
    New-Item -Path $wikiRepoPath + "/plantuml-images" -ItemType Directory -Force
    $content | Out-File -Path $outputPath
    
    Write-ActionInfo "outputFileName $outputFileName"
    Write-ActionInfo "outputPath $outputPath"
}

Function GetOutputFileNameFromFile()
{
    [cmdletbinding()]
    param($content)

    if ($useHeaderForWikiName)
    {
        $firstLine = $content | Select-Object -First 1
        $headerMatch = [regex]::match($firstLine, "^#\s+(.*)$")
        if ($headerMatch.Success)
        {
            $filename = $headerMatch.Groups[1].Value
            $filename = $filename -replace " ", "-"
            $filename = $filename -replace "[^A-Za-z0-9\s.(){}_!?-]", ""

            return @{
                FileName = "$filename.md";
                NewContent = $content[1..$content.Count];
            }
        }
    }
}

Function UpdateFileLinks()
{
    [cmdletbinding()]
    param($filename, [string[]]$directories, $content)

    $evaluator = { 
        [cmdletbinding()]
        param($match)

        $text = $match.Groups[1].Value
        $link = $match.Groups[2].Value

        if (($link -like "http*") -or ($link -like "onenote*"))
        {
            # Absolute link, no change
            Write-Verbose "Link $link is already absolute, nothing to do"
            return "[$text]($link)"
        }

        if ($link -like "#*")
        {
            # Header anchor, no change
            Write-Verbose "Link $link is to an anchor within the page (generally a header), nothing to do"
            return "[$text]($link)"
        }
        
        $upDirs = 0
        $path = @()

        $link -split "/" | % {
            if ($_ -eq "..") 
            {
                $upDirs += 1
            }
            else
            {
                $path += @($_)
            }
        }

        $isMarkdownLink = ($link -split "#")[0] -like "*.md"

        if (($upDirs -le $directories.Count) -and ($isMarkdownLink))
        {
            # Link to another doc which should now point to a wiki file

            $relativeWikiPath = @($directories | Select-Object -First ($directories.Count - $upDirs)) + @($path)
            $wikiFileName = ($relativeWikiPath -join "__") -replace ".md", ""
    
            Write-Verbose "Link $link updated to $wikiFileName"
            return "[$text]($wikiFileName)"
        }

        # Outside the root directory or not a doc, convert to absolute Url
        $extraUpDirs = $upDirs - $directories.Count
        
        if ($extraUpDirs -gt $rootDocsFolderDirs.Count)
        {
            throw "Relative link $link in $filename does not exist"
        }

        $relativePathFromRoot = ($rootDocsFolderDirs | Select-Object -First ($rootDocsFolderDirs.Count - $extraUpDirs)) -join "/"
        if ($relativePathFromRoot) { $relativePathFromRoot += "/" }

        $absoluteLink = $repositoryUrl + "/blob/$defaultBranch/" + $relativePathFromRoot + ($path -join "/")

        if ($isMarkdownLink)
        {
            Write-Verbose "Link $link is outside the docs root, updating to absolute link $absoluteLink"
        }
        else
        {
            Write-Verbose "Link $link is not a doc, updating to absolute link $absoluteLink"
        }

        return "[$text]($absoluteLink)"
    }

    # TODO - handle nested brackets
    # Matches `[text](link)`
    $linkRegex = [regex]"\[([^\]]+)\]\(([^\)]+)\)"

    $content | % { $linkRegex.Replace($_, $evaluator) }
}

Function AddCustomHeader()
{
    [cmdletbinding()]
    param($filename, [string[]]$directories, $content)

    $header = $customWikiFileHeaderFormat

    $relativePath = "$rootDocsFolder/$($directories -join "/")"
    $sourceFileLink = "$repositoryUrl/blob/$defaultBranch/$relativePath/$($fileName)"
    $header = $header -replace "{sourceFileLink}", $sourceFileLink

    @($header, "`n", "`n") + $content
}

Function ProcessWikiDirectory()
{
    [cmdletbinding()]
    param([string[]]$directories=@())

    foreach ($file in Get-ChildItem "*.md")
    {
        ProcessWikiFile $file $directories
    }

    foreach ($dir in Get-ChildItem -Directory)
    {
        Push-Location $dir.Name

        ProcessWikiDirectory ($directories + @($dir.Name))

        Pop-Location
    }
}

Function ProcessWikiFile()
{
    [cmdletbinding()]
    param($file, [string[]]$directories)

    Write-Verbose "Processing file $($file.Name)"

    $content = Get-Content $file
    $filenameToWikiNameMap.Keys | % {
        $originalLink = $_ -replace ".md$", ""
        $newLink = $filenameToWikiNameMap[$_] -replace ".md$", ""

        $content = $content -replace $originalLink, $newLink
    }

    Set-Content -Path $file.FullName -Value $content -Force
}

Function GetWikiCommitMessage()
{
    if (-not $customCommitMessageFormat)
    {
        return "Sync Files"
    }

    Push-Location $sourceRepoDirectory

    $commitMessage = $customCommitMessageFormat

    $message = git log -1 --pretty=%B
    $commitMessage = $commitMessage -replace "{commitMessage}", $message

    $shaFull = git rev-parse HEAD
    $commitMessage = $commitMessage -replace "{shaFull}", $shaFull

    $shaShort = git rev-parse --short HEAD
    $commitMessage = $commitMessage -replace "{shaShort}", $shaShort

    Pop-Location
    return $commitMessage
}

git config --global user.email "action@github.com"
git config --global user.name "GitHub Action"

Push-Location ..
Write-ActionInfo "Cloning wiki repo..."
git clone "$repositoryCloneUrl.wiki.git"
$wikiRepoPath = $pwd.Path + "/" + $wikiRepoDirectory
cd $wikiRepoDirectory
git rm -rf * | Out-Null
Pop-Location

Push-Location $rootDocsFolder
Write-ActionInfo "Processing source directory..."
ProcessSourceDirectory
Pop-Location

Push-Location ..\$wikiRepoDirectory
Write-ActionInfo "Post-processing wiki files..."
ProcessWikiDirectory

$commitMessage = GetWikiCommitMessage

Write-ActionInfo "Pushing wiki"
git add .
git commit -am $commitMessage
git push
Pop-Location
