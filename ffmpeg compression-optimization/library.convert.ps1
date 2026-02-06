param (
    [string]$RootDir = (Get-Location)
)

Write-Host "SCRIPT STARTED"

# ---------------- SETTINGS ----------------

$extensions = @("mp4","avi","mov","mpg","flv","wmv","webm","m4v")
$minSizeMB  = 1200   # minimum size to process (MB)

$logFile = Join-Path (Get-Location) "conversion_log.txt"
Add-Content $logFile "`n===== Conversion run: $(Get-Date) =====`n"

# ---------------- LOAD LOGGED FILES ----------------

$processedFiles = @{}
if (Test-Path $logFile) {
    Get-Content $logFile | ForEach-Object {
        if ($_ -match "^(Replaced|Kept original|FAILED): (.+)$") {
            $processedFiles[$Matches[2]] = $true
        }
    }
}

# ---------------- COUNTERS ----------------

$successCount = 0
$failCount = 0
$skipCount = 0
$gpuFallbackCount = 0

# ---------------- PROCESS FILES ----------------

Get-ChildItem -Path $RootDir -File -Recurse | Where-Object {
    $extensions -contains $_.Extension.TrimStart('.').ToLower()
} | ForEach-Object {

    $input = $_.FullName

    # Skip already processed
    if ($processedFiles.ContainsKey($input)) {
        Write-Host "Skipping already processed: $input"
        $skipCount++
        return
    }

    $fileSizeMB = [math]::Round($_.Length / 1MB, 0)

    # Skip small files
    if ($fileSizeMB -lt $minSizeMB) {
        Write-Host "Skipping small file ($fileSizeMB MB): $input"
        Add-Content $logFile "Skipped (small $fileSizeMB MB): $input"
        $skipCount++
        return
    }

    $output = [System.IO.Path]::ChangeExtension($input, ".mkv")
    $temp   = "$output.temp.mkv"

    Write-Host "`nProcessing: $input"
    Add-Content $logFile "Processing: $input"

    # ---------------- SUBTITLE CHECK ----------------

    $hasMovText = $false
    $subtitleCodecs = & ffprobe -v error `
        -select_streams s `
        -show_entries stream=codec_name `
        -of csv=p=0 `
        "$input"

    foreach ($codec in $subtitleCodecs) {
        if ($codec -eq "mov_text") {
            $hasMovText = $true
            break
        }
    }

    if ($hasMovText) {
        Write-Host "mov_text subtitles detected → converting to SRT"
        Add-Content $logFile "Subtitle: mov_text → srt"
        $subtitleArgs = @("-c:s", "srt")
    }
    else {
        $subtitleArgs = @("-c:s", "copy")
    }

    $encoded = $false

    # ---------------- GPU ENCODE ----------------

    try {
        ffmpeg -y -hwaccel nvdec -i "$input" `
            -map 0:v? -map 0:a? -map 0:s? `
            -c:v h264_nvenc -preset slow -rc vbr -cq 21 -b:v 0 `
            -pix_fmt yuv420p `
            -c:a aac -b:a 160k `
            @subtitleArgs `
            "$temp"

        if ($LASTEXITCODE -eq 0 -and (Test-Path $temp)) {
            $encoded = $true
        }
        else {
            throw "GPU encode failed"
        }
    }
    catch {
        Write-Warning "GPU failed → CPU fallback"
        Add-Content $logFile "GPU failed, CPU fallback: $input"
        $gpuFallbackCount++

        ffmpeg -y -i "$input" `
            -map 0:v? -map 0:a? -map 0:s? `
            -c:v libx264 -preset slow -crf 20 `
            -pix_fmt yuv420p `
            -c:a aac -b:a 160k `
            @subtitleArgs `
            "$temp"

        if ($LASTEXITCODE -eq 0 -and (Test-Path $temp)) {
            $encoded = $true
        }
    }

    # ---------------- SIZE COMPARISON ----------------

    if ($encoded) {
        $originalSize = (Get-Item $input).Length
        $encodedSize  = (Get-Item $temp).Length

        if ($encodedSize -lt $originalSize) {
            Write-Host "Keeping encoded (smaller)"
            Add-Content $logFile "Replaced: $input"

            Remove-Item -Force "$input"
            Rename-Item -Force "$temp" "$output"
            $successCount++
        }
        else {
            Write-Host "Keeping original (encoded larger)"
            Add-Content $logFile "Kept original: $input"

            Remove-Item -Force "$temp"
            $skipCount++
        }
    }
    else {
        Write-Warning "Encoding failed completely"
        Add-Content $logFile "FAILED: $input"

        if (Test-Path $temp) { Remove-Item $temp }
        $failCount++
    }
}

# ---------------- SUMMARY ----------------

Write-Host "`nAll files processed."
Write-Host "Converted (smaller kept): $successCount"
Write-Host "Skipped: $skipCount"
Write-Host "GPU fallbacks: $gpuFallbackCount"
Write-Host "Failures: $failCount"

Add-Content $logFile "`nSummary:"
Add-Content $logFile "Converted: $successCount"
Add-Content $logFile "Skipped: $skipCount"
Add-Content $logFile "GPU fallbacks: $gpuFallbackCount"
Add-Content $logFile "Failures: $failCount"
Add-Content $logFile "===== End of run =====`n"
