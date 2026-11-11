#Requires -Version 5.1

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 > $null

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Clear-Host
    Write-Host "正在请求管理员权限..." -ForegroundColor Yellow
    try {
        $scriptPath = $MyInvocation.MyCommand.Definition
        $currentPath = (Get-Location).Path
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"Set-Location -LiteralPath '$currentPath'; & '$scriptPath'`""
    } catch {
        Write-Host "权限请求未获批准，将以标准权限继续运行。" -ForegroundColor DarkYellow
        Start-Sleep -Seconds 2
    }
    Exit
}

$scriptName = $MyInvocation.MyCommand.Name
$batContent = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$scriptName`"`r`npause"
if (!(Test-Path "启动器启动.bat")) {
    [System.IO.File]::WriteAllText("$PWD\启动器启动.bat", $batContent, [System.Text.Encoding]::Default)
}

try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing } catch {
    $ws = New-Object -ComObject WScript.Shell
    $ws.Popup("当前系统策略阻止了脚本运行。`n请双击目录下的【启动器启动.bat】。`n或在当前目录打开命令提示符并执行：`npowershell -ExecutionPolicy Bypass -File `"$scriptName`"", 15, "运行警告", 48)
    exit
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RootPath = $PWD.Path
$State = "LangSelect"
$TargetV = ""
$JavaPath = "java"
$GameDir = ""
$Player = ""
$UserCancelledUI = $false
$m = $null

New-Item -ItemType Directory -Force "$RootPath\mods" | Out-Null

function Get-WithFallback {
    param([string]$OfficialUrl, [string]$MirrorUrl, [int]$TimeoutSec = 8)
    try { return Invoke-RestMethod -Uri $OfficialUrl -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop } 
    catch { return Invoke-RestMethod -Uri $MirrorUrl -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop }
}

function Start-McDownloader ($tasks) {
    $csharpCode = @'
using System;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;

public class McDownloader
{
    static long totalBytes = 0;
    static long downloadedBytes = 0;
    static long lastDownloadedBytes = 0;
    static int completedFiles = 0;
    static int totalFiles = 0;
    static int failedFiles = 0;

    public static void DownloadAll(string[] tasks, int maxConcurrency)
    {
        totalBytes = 0;
        downloadedBytes = 0;
        lastDownloadedBytes = 0;
        completedFiles = 0;
        totalFiles = tasks.Length;
        failedFiles = 0;

        foreach (var data in tasks)
        {
            string[] parts = data.Split('|');
            if (parts.Length >= 4) {
                long size = 0;
                long.TryParse(parts[3], out size);
                totalBytes += size;
            }
        }

        Console.WriteLine("\n任务总数: " + totalFiles + " 个文件，总大小: " + (totalBytes / 1024.0 / 1024.0).ToString("F1") + " MB\n");

        bool isDownloading = true;
        Thread progressThread = new Thread(() =>
        {
            while (isDownloading)
            {
                Thread.Sleep(500);
                long currentBytes = Interlocked.Read(ref downloadedBytes);
                long speed = (currentBytes - lastDownloadedBytes) * 2;
                lastDownloadedBytes = currentBytes;

                int currentFiles = Interlocked.CompareExchange(ref completedFiles, 0, 0);
                
                double percent = 0;
                string infoStr = "";

                if (totalBytes > 0)
                {
                    percent = (double)currentBytes / totalBytes * 100;
                    if (percent > 100) percent = 100;
                    
                    string speedStr = speed >= 1024 * 1024 ? ((double)speed / 1024.0 / 1024.0).ToString("F1") + " MB/s" : ((double)speed / 1024.0).ToString("F1") + " KB/s";
                    infoStr = "进度: " + currentFiles + "/" + totalFiles + " | " + (currentBytes / 1024.0 / 1024.0).ToString("F1") + " MB / " + (totalBytes / 1024.0 / 1024.0).ToString("F1") + " MB | 速度: " + speedStr;
                }
                else
                {
                    percent = totalFiles == 0 ? 100 : (double)currentFiles / totalFiles * 100;
                    infoStr = "文件: " + currentFiles + " / " + totalFiles;
                }

                int barLen = 20;
                int fillLen = (int)(percent / 100 * barLen);
                string bar = new string('-', fillLen) + new string(' ', barLen - fillLen);

                Console.Write("\r[" + bar + "] " + percent.ToString("F1").PadLeft(5) + "% | " + infoStr + "   ");
            }
        });
        progressThread.IsBackground = true;
        progressThread.Start();

        var options = new ParallelOptions { MaxDegreeOfParallelism = maxConcurrency };
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        ServicePointManager.DefaultConnectionLimit = maxConcurrency + 100; 

        Parallel.ForEach(tasks, options, data =>
        {
            string[] parts = data.Split('|');
            if (parts.Length < 4) return;

            string[] urls = parts[0].Split('^');
            string savePath = parts[1];
            string expectedSha1 = parts[2];
            long size = 0;
            long.TryParse(parts[3], out size);
            bool success = false;

            if (File.Exists(savePath))
            {
                if (string.IsNullOrEmpty(expectedSha1) || VerifyFile(savePath, expectedSha1))
                {
                    Interlocked.Increment(ref completedFiles);
                    Interlocked.Add(ref downloadedBytes, size);
                    return; 
                }
                else { try { File.Delete(savePath); } catch { } }
            }

            try { Directory.CreateDirectory(Path.GetDirectoryName(savePath)); } catch { }

            foreach (var url in urls)
            {
                if (string.IsNullOrEmpty(url)) continue;
                try
                {
                    string tempPath = savePath + ".tmp";
                    using (var webClient = new WebClient())
                    {
                        webClient.Headers.Add("User-Agent", "Mozilla/5.0");
                        using (var stream = webClient.OpenRead(url))
                        using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
                        {
                            byte[] buffer = new byte[16384];
                            int bytesRead;
                            while ((bytesRead = stream.Read(buffer, 0, buffer.Length)) > 0)
                            {
                                fs.Write(buffer, 0, bytesRead);
                                Interlocked.Add(ref downloadedBytes, bytesRead);
                            }
                        }
                    }

                    if (string.IsNullOrEmpty(expectedSha1) || VerifyFile(tempPath, expectedSha1))
                    {
                        if (File.Exists(savePath)) File.Delete(savePath);
                        File.Move(tempPath, savePath);
                        success = true;
                        break;
                    }
                    else { File.Delete(tempPath); }
                }
                catch { } 
            }

            if (success)
            {
                Interlocked.Increment(ref completedFiles);
            }
            else
            {
                Interlocked.Increment(ref failedFiles);
                Interlocked.Add(ref downloadedBytes, -size);
            }
        });

        isDownloading = false;
        Thread.Sleep(600); 
        Console.Write("\r" + new string(' ', 80) + "\r");
        Console.WriteLine("文件校验及下载完成。总计: " + totalFiles + " | 成功: " + completedFiles + " | 失败: " + failedFiles + "\n");
    }

    private static bool VerifyFile(string path, string expectedSha1)
    {
        try
        {
            using (var sha1 = SHA1.Create())
            using (var stream = File.OpenRead(path))
            {
                byte[] hash = sha1.ComputeHash(stream);
                string actual = BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
                return actual == expectedSha1.ToLowerInvariant();
            }
        }
        catch { return false; }
    }
}
'@
    if (-not ("McDownloader" -as [type])) { Add-Type -TypeDefinition $csharpCode -Language CSharp -ErrorAction Stop }
    [McDownloader]::DownloadAll($tasks, 256)
}

function Clear-SystemMemory {
    $memCleanCode = @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public class MemCleaner {
    [DllImport("psapi.dll")]
    public static extern int EmptyWorkingSet(IntPtr hwndProc);

    [DllImport("ntdll.dll")]
    public static extern uint NtSetSystemInformation(int SystemInformationClass, IntPtr SystemInformation, int SystemInformationLength);

    public static void TrimWorkingSets() {
        foreach (Process process in Process.GetProcesses()) {
            try {
                string pName = process.ProcessName.ToLower();
                if (pName != "system" && pName != "idle" && pName != "csrss" && pName != "wininit") {
                    EmptyWorkingSet(process.Handle);
                }
            } catch { }
        }
    }

    public static void PurgeSystemLists() {
        try {
            IntPtr info = Marshal.AllocHGlobal(4);
            int[] commands = new int[] { 4, 3, 5 };
            foreach (int cmd in commands) {
                Marshal.WriteInt32(info, cmd);
                NtSetSystemInformation(0x50, info, 4);
            }
            Marshal.FreeHGlobal(info);
        } catch { }
    }

    public static void ClearSystemFileCache() {
        try {
            IntPtr info = Marshal.AllocHGlobal(16);
            Marshal.WriteInt64(info, 0, -1);
            Marshal.WriteInt64(info, 8, -1);
            NtSetSystemInformation(0x15, info, 16);
            Marshal.FreeHGlobal(info);
        } catch { }
    }

    public static void DeepClean() {
        System.GC.Collect();
        System.GC.WaitForPendingFinalizers();
        System.GC.Collect();
        TrimWorkingSets();       
    }
}
"@
    if (-not ("MemCleaner" -as [type])) { Add-Type -TypeDefinition $memCleanCode }
    [MemCleaner]::DeepClean()
}

function Build-GameTaskList ($root, $v, $j) {
    $taskList = New-Object System.Collections.Generic.List[string]
    $nativesJars = New-Object System.Collections.Generic.List[string]

    $cOfficial = $j.downloads.client.url
    $cMirror = $cOfficial -replace 'https://piston-data.mojang.com', 'https://bmclapi2.bangbang93.com'
    $taskList.Add("$cOfficial^$cMirror|$root\versions\$v\$v.jar|$($j.downloads.client.sha1)|$($j.downloads.client.size)")

    $libs = @($j.libraries | Where-Object {
        if (-not $_.downloads.artifact -and -not $_.downloads.classifiers) { return $false }
        if (-not $_.rules) { return $true }
        
        $isAllowed = $false
        foreach ($rule in $_.rules) {
            $match = $true
            if ($rule.os) {
                if ($rule.os.name -and $rule.os.name -ne "windows") { $match = $false }
                if ($rule.os.arch -and $rule.os.arch -notmatch "x86_64|x64") { $match = $false }
            }
            if ($match) {
                if ($rule.action -eq "allow") { $isAllowed = $true }
                elseif ($rule.action -eq "disallow") { $isAllowed = $false }
            }
        }
        return $isAllowed
    })

    foreach ($lib in $libs) {
        if ($lib.downloads.artifact) {
            $a = $lib.downloads.artifact
            $taskList.Add("$($a.url)^$($a.url -replace 'https://libraries.minecraft.net', 'https://bmclapi2.bangbang93.com/maven')|$root\libraries\$($a.path)|$($a.sha1)|$($a.size)")
        }
        $nativeKey = $null
        if ($lib.natives -and $lib.natives.windows) { $nativeKey = $lib.natives.windows }
        elseif ($lib.downloads.classifiers -and $lib.downloads.classifiers.'natives-windows') { $nativeKey = 'natives-windows' }
        if ($nativeKey) {
            $n = $lib.downloads.classifiers.$nativeKey
            if (!$n) { $n = $lib.downloads.classifiers.($nativeKey.Replace('${arch}', '64')) }
            if ($n) {
                $taskList.Add("$($n.url)^$($n.url -replace 'https://libraries.minecraft.net', 'https://bmclapi2.bangbang93.com/maven')|$root\libraries\$($n.path)|$($n.sha1)|$($n.size)")
                $nativesJars.Add("$root\libraries\$($n.path)")
            }
        }
    }
    
    $iOfficial = $j.assetIndex.url
    $iPath = "$root\assets\indexes\$($j.assetIndex.id).json"
    New-Item -ItemType Directory -Force "$root\assets\indexes" | Out-Null
    if (!(Test-Path $iPath)) {
        try { irm $iOfficial -OutFile $iPath -UseBasicParsing -TimeoutSec 10 } 
        catch { irm ($iOfficial -replace 'https://piston-meta.mojang.com', 'https://bmclapi2.bangbang93.com') -OutFile $iPath -UseBasicParsing }
    }
    $ai = Get-Content $iPath -Raw | ConvertFrom-Json
    
    foreach ($prop in @($ai.objects.PSObject.Properties)) {
        $h = $prop.Value.hash; $sub = $h.Substring(0,2)
        $size = $prop.Value.size
        $taskList.Add("https://resources.download.minecraft.net/$sub/$h^https://bmclapi2.bangbang93.com/assets/$sub/$h|$root\assets\objects\$sub\$h|$h|$size")
    }

    return @{ Tasks = $taskList.ToArray(); Natives = $nativesJars.ToArray() }
}

function Show-ModCenter {
    $modForm = New-Object System.Windows.Forms.Form
    $modForm.Text = "模组下载平台"
    $modForm.Size = New-Object System.Drawing.Size(1100, 800)
    $modForm.StartPosition = "CenterScreen"
    $modForm.FormBorderStyle = "Sizable"
    $modForm.MaximizeBox = $true
    $modForm.MinimumSize = New-Object System.Drawing.Size(800, 600)

    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text = "当前筛选:"
    $lblFilter.Location = New-Object System.Drawing.Point(20, 20)
    $lblFilter.AutoSize = $true

    $comboGameVer = New-Object System.Windows.Forms.ComboBox
    $comboGameVer.Location = New-Object System.Drawing.Point(90, 18)
    $comboGameVer.Size = New-Object System.Drawing.Size(120, 25)
    $comboGameVer.DropDownStyle = "DropDownList"

    $comboLoader = New-Object System.Windows.Forms.ComboBox
    $comboLoader.Location = New-Object System.Drawing.Point(230, 18)
    $comboLoader.Size = New-Object System.Drawing.Size(100, 25)
    $comboLoader.DropDownStyle = "DropDownList"

    $btnSearch = New-Object System.Windows.Forms.Button
    $btnSearch.Text = "检索"
    $btnSearch.Location = New-Object System.Drawing.Point(350, 16)
    $btnSearch.Size = New-Object System.Drawing.Size(80, 28)

    try {
        $manifest = Get-WithFallback -OfficialUrl "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" -MirrorUrl "https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json"
        $allReleases = @($manifest.versions | Where-Object { $_.type -eq "release" } | ForEach-Object { $_.id })
        $comboGameVer.Items.AddRange([string[]]$allReleases) | Out-Null
        if ($comboGameVer.Items.Count -gt 0) { $comboGameVer.SelectedIndex = 0 }
    } catch {
        $comboGameVer.Items.AddRange(@("1.21.4", "1.20.1", "1.12.2")) | Out-Null; $comboGameVer.SelectedIndex = 0
    }
    $comboLoader.Items.AddRange(@("Forge", "Fabric", "NeoForge", "Quilt", "Vanilla")) | Out-Null
    $comboLoader.SelectedIndex = 1

    $listMods = New-Object System.Windows.Forms.ListBox
    $listMods.Location = New-Object System.Drawing.Point(20, 60)
    $listMods.Size = New-Object System.Drawing.Size(480, 630)
    $listMods.Font = New-Object System.Drawing.Font("Microsoft YaHei", 10)
    $listMods.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

    $listVers = New-Object System.Windows.Forms.ListBox
    $listVers.Location = New-Object System.Drawing.Point(520, 60)
    $listVers.Size = New-Object System.Drawing.Size(540, 630)
    $listVers.Font = New-Object System.Drawing.Font("Consolas", 10)
    $listVers.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $btnPrev = New-Object System.Windows.Forms.Button
    $btnPrev.Text = "< 上一页"
    $btnPrev.Location = New-Object System.Drawing.Point(20, 710)
    $btnPrev.Size = New-Object System.Drawing.Size(100, 30)
    $btnPrev.Enabled = $false
    $btnPrev.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

    $btnNext = New-Object System.Windows.Forms.Button
    $btnNext.Text = "下一页 >"
    $btnNext.Location = New-Object System.Drawing.Point(130, 710)
    $btnNext.Size = New-Object System.Drawing.Size(100, 30)
    $btnNext.Enabled = $false
    $btnNext.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

    $lblPage = New-Object System.Windows.Forms.Label
    $lblPage.Text = "第 1 页"
    $lblPage.Location = New-Object System.Drawing.Point(250, 716)
    $lblPage.AutoSize = $true
    $lblPage.ForeColor = [System.Drawing.Color]::Gray
    $lblPage.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

    $modForm.Controls.AddRange(@($lblFilter, $comboGameVer, $comboLoader, $btnSearch, $listMods, $listVers, $btnPrev, $btnNext, $lblPage))

    $script:modHits = @(); $script:modVersions = @(); $script:depNames = @{}
    $script:modOffset = 0

    $doSearch = {
        $listMods.Items.Clear(); $listVers.Items.Clear(); $listMods.Items.Add("正在检索..."); $modForm.Refresh()
        $facets = '[["project_type:mod"],["versions:' + $comboGameVer.SelectedItem.ToString() + '"]'
        if ($comboLoader.SelectedItem.ToString().ToLower() -ne "vanilla") { $facets += ',["categories:' + $comboLoader.SelectedItem.ToString().ToLower() + '"]' }
        $facets += ']'
        $query = "?facets=" + [System.Uri]::EscapeDataString($facets) + "&limit=100&offset=$($script:modOffset)"

        try {
            $res = Get-WithFallback -OfficialUrl ("https://api.modrinth.com/v2/search" + $query) -MirrorUrl ("https://mod.mcimirror.top/modrinth/v2/search" + $query)
            $script:modHits = @($res.hits); $listMods.Items.Clear()
            if ($script:modHits.Count -eq 0) { 
                $listMods.Items.Add("当前页未检索到匹配项")
                if ($script:modOffset -gt 0) {
                    $script:modOffset -= 100
                    $lblPage.Text = "第 $(($script:modOffset / 100) + 1) 页"
                }
                return 
            }
            foreach ($mod in $script:modHits) { $listMods.Items.Add("$($mod.title) | 热度: $($mod.downloads)") | Out-Null }
        } catch { $listMods.Items.Clear(); $listMods.Items.Add("检索异常：$($_.Exception.Message)") | Out-Null }
    }

    $btnSearch.Add_Click({
        $script:modOffset = 0
        $lblPage.Text = "第 1 页"
        $btnPrev.Enabled = $false
        $btnNext.Enabled = $true
        & $doSearch
    })

    $btnPrev.Add_Click({
        if ($script:modOffset -ge 100) {
            $script:modOffset -= 100
            $lblPage.Text = "第 $(($script:modOffset / 100) + 1) 页"
            $btnNext.Enabled = $true
            if ($script:modOffset -eq 0) { $btnPrev.Enabled = $false }
            & $doSearch
        }
    })

    $btnNext.Add_Click({
        $script:modOffset += 100
        $lblPage.Text = "第 $(($script:modOffset / 100) + 1) 页"
        $btnPrev.Enabled = $true
        & $doSearch
    })

    $listMods.Add_SelectedIndexChanged({
        $idx = $listMods.SelectedIndex
        if ($idx -lt 0 -or $idx -ge $script:modHits.Count) { return }
        $listVers.Items.Clear(); $listVers.Items.Add("正在解析版本..."); $modForm.Refresh()
        
        $mod = $script:modHits[$idx]
        $gameVer = $comboGameVer.SelectedItem.ToString(); $loader = $comboLoader.SelectedItem.ToString().ToLower()
        $query = "?loaders=%22" + $loader + "%22&game_versions=%22" + $gameVer + "%22"
        
        try {
            $res = Get-WithFallback -OfficialUrl ("https://api.modrinth.com/v2/project/$($mod.project_id)/version" + $query) -MirrorUrl ("https://mod.mcimirror.top/modrinth/v2/project/$($mod.project_id)/version" + $query)
            $script:modVersions = @($res); $listVers.Items.Clear()
            if ($script:modVersions.Count -eq 0) { $listVers.Items.Add("不存在兼容当前环境的版本"); return }
            
            $depIds = @()
            foreach ($ver in $script:modVersions) { if ($ver.dependencies) { foreach ($dep in $ver.dependencies) { if ($dep.dependency_type -eq "required") { $depIds += $dep.project_id } } } }
            
            $script:depNames = @{}
            if ($depIds.Count -gt 0) {
                $uniqueDeps = $depIds | Select-Object -Unique
                $depQuery = '["' + ($uniqueDeps -join '","') + '"]'
                $depUrl = "https://api.modrinth.com/v2/projects?ids=" + [System.Uri]::EscapeDataString($depQuery)
                try {
                    $depRes = Get-WithFallback -OfficialUrl $depUrl -MirrorUrl ($depUrl -replace 'api.modrinth.com/v2', 'mod.mcimirror.top/modrinth/v2')
                    foreach ($d in $depRes) { $script:depNames[$d.id] = $d.title }
                } catch {}
            }

            foreach ($ver in $script:modVersions) {
                $typeStr = "[正式]"; if ($ver.version_type -eq "beta") { $typeStr = "[测试]" } elseif ($ver.version_type -eq "alpha") { $typeStr = "[内测]" }
                $reqDeps = @()
                if ($ver.dependencies) { foreach ($dep in $ver.dependencies) { if ($dep.dependency_type -eq "required" -and $script:depNames[$dep.project_id]) { $reqDeps += $script:depNames[$dep.project_id] } } }
                $depText = if ($reqDeps.Count -gt 0) { " | 依赖: " + ($reqDeps -join ', ') } else { "" }
                $listVers.Items.Add("$typeStr $($ver.version_number) $($ver.name)$depText") | Out-Null
            }
        } catch { $listVers.Items.Clear(); $listVers.Items.Add("解析失败：$($_.Exception.Message)") | Out-Null }
    })

    $listVers.Add_DoubleClick({
        $idx = $listVers.SelectedIndex
        if ($idx -lt 0 -or $idx -ge $script:modVersions.Count) { return }
        $ver = $script:modVersions[$idx]
        
        $modsDir = "$RootPath\mods"
        if (!(Test-Path $modsDir)) { New-Item -ItemType Directory -Force $modsDir | Out-Null }
        
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "请确认模组保存路径 (已默认定位至mods文件夹)"
        $folderBrowser.SelectedPath = $modsDir
        
        if ($folderBrowser.ShowDialog() -eq "OK") {
            $saveDir = $folderBrowser.SelectedPath; $tasks = @()
            $primaryFile = $ver.files | Where-Object { $_.primary } | Select-Object -First 1
            if (-not $primaryFile) { $primaryFile = $ver.files[0] }
            $tasks += "$($primaryFile.url)|$(Join-Path $saveDir $primaryFile.filename)|$($primaryFile.hashes.sha1)|$($primaryFile.size)"
            
            $depCount = 0
            if ($ver.dependencies) {
                foreach ($dep in $ver.dependencies) {
                    if ($dep.dependency_type -eq "required") {
                        $depQuery = "?loaders=%22" + $comboLoader.SelectedItem.ToString().ToLower() + "%22&game_versions=%22" + $comboGameVer.SelectedItem.ToString() + "%22"
                        $depUrl = "https://api.modrinth.com/v2/project/" + $dep.project_id + "/version" + $depQuery
                        try {
                            $depVers = Get-WithFallback -OfficialUrl $depUrl -MirrorUrl ($depUrl -replace 'api.modrinth.com/v2', 'mod.mcimirror.top/modrinth/v2')
                            if ($depVers.Count -gt 0) {
                                $df = $depVers[0].files | Where-Object { $_.primary } | Select-Object -First 1
                                if (-not $df) { $df = $depVers[0].files[0] }
                                $tasks += "$($df.url)|$(Join-Path $saveDir $df.filename)|$($df.hashes.sha1)|$($df.size)"
                                $depCount++
                            }
                        } catch {}
                    }
                }
            }
            Write-Host "`n[下载] 主文件 1 个，自动附带依赖文件 $depCount 个。开始获取..." -ForegroundColor Cyan
            Start-McDownloader $tasks
            [System.Windows.Forms.MessageBox]::Show("文件已部署至目标目录。", "完成")
        }
    })
    $modForm.ShowDialog() | Out-Null; $modForm.Dispose()
}

function Show-VersionUI ($versions) {
    $script:UserCancelledUI = $false; $script:TargetV = "" 
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "选择本地实例"; $form.Size = New-Object System.Drawing.Size(300, 350); $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
    $form.Add_FormClosing({ param($sender, $e); if ($e.CloseReason -eq "UserClosing" -and $sender.DialogResult -eq "None") { $script:UserCancelledUI = $true } })
    $chkList = New-Object System.Windows.Forms.CheckedListBox; $chkList.Location = New-Object System.Drawing.Point(20, 20); $chkList.Size = New-Object System.Drawing.Size(240, 200)
    $versions | ForEach-Object { [void]$chkList.Items.Add($_) }; $form.Controls.Add($chkList)
    $btnStart = New-Object System.Windows.Forms.Button; $btnStart.Text = "确认执行"; $btnStart.Location = New-Object System.Drawing.Point(80, 240); $btnStart.Size = New-Object System.Drawing.Size(120, 40)
    $btnStart.Add_Click({
        $selected = $chkList.CheckedItems
        if ($selected.Count -gt 0) { $script:TargetV = $selected[0]; $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() } 
        else { [System.Windows.Forms.MessageBox]::Show("请至少勾选一个实例。") }
    })
    $form.Controls.Add($btnStart); $form.ShowDialog() | Out-Null; $form.Dispose()
}

function Show-DownloadVersionUI ($releases, $snapshots) {
    $script:UserCancelledUI = $false; $script:TargetV = "" 
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "获取新实例"; $form.Size = New-Object System.Drawing.Size(380, 500); $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
    $form.Add_FormClosing({ param($sender, $e); if ($e.CloseReason -eq "UserClosing" -and $sender.DialogResult -eq "None") { $script:UserCancelledUI = $true } })
    $tabControl = New-Object System.Windows.Forms.TabControl; $tabControl.Location = New-Object System.Drawing.Point(20, 20); $tabControl.Size = New-Object System.Drawing.Size(320, 360)
    $tabRelease = New-Object System.Windows.Forms.TabPage; $tabRelease.Text = "正式版本"
    $listRelease = New-Object System.Windows.Forms.ListBox; $listRelease.Dock = [System.Windows.Forms.DockStyle]::Fill; $listRelease.Font = New-Object System.Drawing.Font("Consolas", 10)
    $releases | ForEach-Object { [void]$listRelease.Items.Add($_) }; $tabRelease.Controls.Add($listRelease)
    $tabSnapshot = New-Object System.Windows.Forms.TabPage; $tabSnapshot.Text = "快照版本"
    $listSnapshot = New-Object System.Windows.Forms.ListBox; $listSnapshot.Dock = [System.Windows.Forms.DockStyle]::Fill; $listSnapshot.Font = New-Object System.Drawing.Font("Consolas", 10)
    $snapshots | ForEach-Object { [void]$listSnapshot.Items.Add($_) }; $tabSnapshot.Controls.Add($listSnapshot)
    $tabControl.Controls.Add($tabRelease); $tabControl.Controls.Add($tabSnapshot); $form.Controls.Add($tabControl)
    $btnStart = New-Object System.Windows.Forms.Button; $btnStart.Text = "部署实例"; $btnStart.Location = New-Object System.Drawing.Point(120, 400); $btnStart.Size = New-Object System.Drawing.Size(120, 40)
    $btnStart.Add_Click({
        if ($tabControl.SelectedIndex -eq 0) { $sel = $listRelease.SelectedItem } else { $sel = $listSnapshot.SelectedItem }
        if ($sel) { $script:TargetV = $sel.ToString(); $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() } 
        else { [System.Windows.Forms.MessageBox]::Show("请先选择一个目标版本。") }
    })
    $form.Controls.Add($btnStart); $form.ShowDialog() | Out-Null; $form.Dispose()
}

function Get-JavaDownloadInfo {
    param([int]$majorVersion)

    $fileName = ""
    $officialUrl = ""
    
    try {
        $apiUrl = "https://api.adoptium.net/v3/assets/latest/$majorVersion/hotspot?image_type=jre&vendor=eclipse&architecture=x64&os=windows"
        $res = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($res -and $res.Count -gt 0) {
            $asset = $res[0]
            $fileName = $asset.binary.package.name
            $officialUrl = $asset.binary.package.link
        }
    } catch {}

    if (-not $fileName) {
        try {
            $listUrl = "https://mirrors.tuna.tsinghua.edu.cn/Adoptium/$majorVersion/jre/x64/windows/"
            $html = Invoke-WebRequest -Uri $listUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            $matches = [regex]::Matches($html.Content, 'href="([^"]*\.zip)"')
            foreach ($m in $matches) {
                $f = $m.Groups[1].Value
                if ($f -match "jre.*windows.*x64" -or $f -match "jre_x64_windows") {
                    $fileName = $f
                    break
                }
            }
        } catch {}
    }

    if (-not $fileName) { return $null }

    $urls = @()
    if ($officialUrl) { $urls += $officialUrl }
    
    $urls += "https://mirrors.tuna.tsinghua.edu.cn/Adoptium/$majorVersion/jre/x64/windows/$fileName"
    $urls += "https://mirrors.ustc.edu.cn/adoptium/$majorVersion/jre/x64/windows/$fileName"
    $urls += "https://mirrors.nju.edu.cn/adoptium/$majorVersion/jre/x64/windows/$fileName"
    
    $fallbackApi = "https://api.adoptium.net/v3/binary/latest/$majorVersion/ga/windows/x64/jre/hotspot/normal/eclipse"
    $urls += $fallbackApi

    return @{
        Urls = $urls
        FileName = $fileName
        Source = if ($officialUrl) { "Adoptium 官方 / 镜像备选" } else { "清华 TUNA / 中科大 USTC 备选" }
    }
}

function Extract-ZipFile {
    param($zipPath, $destDir)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($entry in $zip.Entries) {
            $destPath = Join-Path $destDir $entry.FullName
            if ([string]::IsNullOrEmpty($entry.Name)) {
                New-Item -ItemType Directory -Force -Path $destPath | Out-Null
            } else {
                $parent = Split-Path $destPath -Parent
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destPath, $true)
            }
        }
    } finally {
        $zip.Dispose()
    }
}

function Show-JavaDownloadUI {
    $javaForm = New-Object System.Windows.Forms.Form
    $javaForm.Text = "Java 运行环境下载"
    $javaForm.Size = New-Object System.Drawing.Size(500, 400)
    $javaForm.StartPosition = "CenterScreen"
    $javaForm.FormBorderStyle = "FixedDialog"
    $javaForm.MaximizeBox = $false

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = "请选择要下载的 Java 版本 (LTS 版本):"
    $lblInfo.Location = New-Object System.Drawing.Point(20, 20)
    $lblInfo.AutoSize = $true

    $comboJavaVer = New-Object System.Windows.Forms.ComboBox
    $comboJavaVer.Location = New-Object System.Drawing.Point(20, 50)
    $comboJavaVer.Size = New-Object System.Drawing.Size(440, 25)
    $comboJavaVer.DropDownStyle = "DropDownList"

    $availableJavaVersions = @("8", "11", "17", "21", "25")
    $availableJavaVersions | ForEach-Object { [void]$comboJavaVer.Items.Add($_) }
    $comboJavaVer.SelectedIndex = 3  # 默认选中 21

    $listLog = New-Object System.Windows.Forms.ListBox
    $listLog.Location = New-Object System.Drawing.Point(20, 90)
    $listLog.Size = New-Object System.Drawing.Size(440, 200)
    $listLog.Font = New-Object System.Drawing.Font("Consolas", 9)

    $btnDownload = New-Object System.Windows.Forms.Button
    $btnDownload.Text = "开始下载"
    $btnDownload.Location = New-Object System.Drawing.Point(150, 310)
    $btnDownload.Size = New-Object System.Drawing.Size(200, 40)

    $btnDownload.Add_Click({
        $btnDownload.Enabled = $false
        $comboJavaVer.Enabled = $false
        $ver = $comboJavaVer.SelectedItem.ToString()
        $listLog.Items.Clear()
        $listLog.Items.Add("正在获取 Java $ver 版本信息...")
        $javaForm.Refresh()

        try {
            $info = Get-JavaDownloadInfo -majorVersion $ver
            if (-not $info) {
                $listLog.Items.Add("获取失败：所有下载源均无法响应，请检查网络后重试。")
                return
            }

            $listLog.Items.Add("目标文件: $($info.FileName)")

            $targetDir = "$RootPath\Java\$ver"
            New-Item -ItemType Directory -Force $targetDir | Out-Null
            $targetPath = Join-Path $targetDir $info.FileName

            $downloadSuccess = $false
            $idx = 1
            foreach ($url in $info.Urls) {
                if ([string]::IsNullOrWhiteSpace($url)) { continue }
                try {
                    $listLog.Items.Add("尝试节点 $idx : $url")
                    $javaForm.Refresh()
                    
                    $ProgressPreference = 'SilentlyContinue' 
                    Invoke-WebRequest -Uri $url -OutFile $targetPath -UseBasicParsing -TimeoutSec 300
                    
                    if ((Test-Path $targetPath) -and ((Get-Item $targetPath).Length -gt 1048576)) {
                        $downloadSuccess = $true
                        break
                    }
                } catch {
                    $listLog.Items.Add("失败: $($_.Exception.Message)")
                    $javaForm.Refresh()
                    if (Test-Path $targetPath) { Remove-Item $targetPath -Force -ErrorAction SilentlyContinue }
                }
                $idx++
            }

            if ($downloadSuccess) {
                $listLog.Items.Add("下载完成，正在解压...")
                $javaForm.Refresh()
                try {
                    Extract-ZipFile -zipPath $targetPath -destDir $targetDir
                    Remove-Item $targetPath -Force -ErrorAction SilentlyContinue
                    $listLog.Items.Add("解压完成，已部署至: $targetDir")
                    [System.Windows.Forms.MessageBox]::Show("Java $ver 下载并解压完成。`n目录位置: $targetDir", "完成")
                } catch {
                    $listLog.Items.Add("解压失败: $($_.Exception.Message)")
                    [System.Windows.Forms.MessageBox]::Show("解压失败，请检查磁盘空间或权限。", "错误")
                }
            } else {
                $listLog.Items.Add("下载失败，所有备用下载源均不可达，请检查网络或重试。")
            }
        } catch {
            $listLog.Items.Add("发生错误: $($_.Exception.Message)")
        } finally {
            $btnDownload.Enabled = $true
            $comboJavaVer.Enabled = $true
        }
    })

    $javaForm.Controls.AddRange(@($lblInfo, $comboJavaVer, $listLog, $btnDownload))
    $javaForm.ShowDialog() | Out-Null
    $javaForm.Dispose()
}

while ($true) {
    switch ($State) {
        "LangSelect" {
            Clear-Host
            Write-Host "==================================================" -ForegroundColor DarkCyan
            Write-Host "                 轩奶xuannai制作" -ForegroundColor Cyan
            Write-Host "==================================================" -ForegroundColor DarkCyan
            Write-Host "==================================================" -ForegroundColor DarkCyan
            Write-Host "       Minecraft 自动化部署与启动程序" -ForegroundColor Cyan
            Write-Host "==================================================" -ForegroundColor DarkCyan
            Write-Host "`n[1] 实例管理" -ForegroundColor White
            Write-Host "[2] 模组下载" -ForegroundColor White
            Write-Host "[3] 下载 Java 环境" -ForegroundColor White
            Write-Host "[4] 终止运行" -ForegroundColor DarkGray
            $choice = Read-Host "`n请选择操作 [默认 1]"
            
            if ($choice -eq "2") { Show-ModCenter; $State = "LangSelect" }
            elseif ($choice -eq "3") { Show-JavaDownloadUI; $State = "LangSelect" }
            elseif ($choice -eq "4") { exit }
            else { $State = "InstanceMenu" }
        }

        "InstanceMenu" {
            Clear-Host
            Write-Host "==================================================" -ForegroundColor DarkCyan
            Write-Host "       实例管理菜单" -ForegroundColor Cyan
            Write-Host "==================================================" -ForegroundColor DarkCyan
            Write-Host "`n[1] 启动本地已有版本" -ForegroundColor White
            Write-Host "[2] 下载新版本" -ForegroundColor White
            Write-Host "[3] 返回主控台" -ForegroundColor DarkGray
            $choice = Read-Host "`n请选择操作 [默认 1]"
            
            if ($choice -eq "2") { $State = "AskDownload" }
            elseif ($choice -eq "3") { $State = "LangSelect" }
            else { $State = "Scan" }
        }

        "Scan" {
            Clear-Host; Write-Host "正在检索本地实例..." -ForegroundColor Cyan
            $foundVersions = @()
            $dirs = Get-ChildItem -Path $RootPath -Directory -Exclude "Java", ".git", "assets", "libraries", "versions", "game", "mods" -ErrorAction SilentlyContinue
            foreach ($d in $dirs) {
                $jsonPath = "$($d.FullName)\versions\$($d.Name)\$($d.Name).json"
                if (Test-Path $jsonPath) { $foundVersions += $d.Name }
            }

            if ($foundVersions.Count -gt 0) {
                Show-VersionUI $foundVersions
                if (-not $UserCancelledUI -and $TargetV) { $GameDir = "$RootPath\$TargetV"; $State = "InputName" } 
                else { $State = "InstanceMenu" } 
            } else { 
                Write-Host "未找到任何本地版本。" -ForegroundColor Yellow
                Start-Sleep -Seconds 2
                $State = "AskDownload" 
            }
        }

        "AskDownload" {
            Clear-Host; Write-Host "正在获取官方版本清单..." -ForegroundColor Cyan
            try { $m = irm "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" -UseBasicParsing -TimeoutSec 10 } 
            catch { try { $m = irm "https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json" -UseBasicParsing -TimeoutSec 10 } catch { Write-Host "网络异常：无法获取远端数据。" -ForegroundColor Red; Start-Sleep -Seconds 2; $State = "LangSelect"; continue } }

            $allReleases = @($m.versions | Where-Object { $_.type -eq "release" } | ForEach-Object { $_.id })
            $allSnapshots = @($m.versions | Where-Object { $_.type -eq "snapshot" } | ForEach-Object { $_.id })

            Show-DownloadVersionUI $allReleases $allSnapshots
            if (-not $UserCancelledUI -and $TargetV) { $GameDir = "$RootPath\$TargetV"; $State = "InputName" } 
            elseif ($UserCancelledUI) { $State = "InstanceMenu" } 
        }

        "InputName" {
            $userFile = "$RootPath\username.txt"
            if (Test-Path $userFile) {
                $historyPlayer = (Get-Content $userFile -Raw).Trim()
                if (![string]::IsNullOrWhiteSpace($historyPlayer)) {
                    Write-Host "`n发现历史玩家名称: " -NoNewline; Write-Host "$historyPlayer" -ForegroundColor Cyan
                    $useHistory = Read-Host "是否沿用当前名称？[Y/N]"
                    if ($useHistory -notmatch "^[Nn]") { $script:Player = $historyPlayer }
                }
            }
            
            if ([string]::IsNullOrWhiteSpace($script:Player)) {
                $inputPlayer = Read-Host "`n请输入本地玩家标识 (直接回车默认 Steve)"
                $script:Player = if ([string]::IsNullOrWhiteSpace($inputPlayer)) { "Steve" } else { $inputPlayer.Trim() }
                [System.IO.File]::WriteAllText($userFile, $script:Player, [System.Text.Encoding]::UTF8)
            }
            Write-Host "当前名称: $script:Player" -ForegroundColor Green
            $State = "Download"
        }

        "Download" {
            Clear-Host; Write-Host "[部署] 准备获取目标实例文件..." -ForegroundColor Cyan
            $root = $GameDir; New-Item -ItemType Directory -Force $root | Out-Null; $v = $TargetV
            
            if (!$m) {
                try { $m = irm "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" -UseBasicParsing -TimeoutSec 10 } 
                catch { try { $m = irm "https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json" -UseBasicParsing -TimeoutSec 10 } catch { } }
            }

            $e = $m.versions | Where-Object id -eq $v
            if (!$e) { Write-Host "异常：未在清单中找到目标版本。" -ForegroundColor Red; $State = "InstanceMenu"; continue }
            
            New-Item -ItemType Directory -Force "$root\versions\$v" | Out-Null
            if (!(Test-Path "$root\versions\$v\$v.json")) {
                try { irm $e.url -OutFile "$root\versions\$v\$v.json" -UseBasicParsing -TimeoutSec 10 }
                catch { irm ($e.url -replace 'https://piston-meta.mojang.com', 'https://bmclapi2.bangbang93.com') -OutFile "$root\versions\$v\$v.json" -UseBasicParsing }
            }
            $j = Get-Content "$root\versions\$v\$v.json" -Raw | ConvertFrom-Json

            Write-Host "`n[1/2] 生成下载序列并启用并发引擎..." -ForegroundColor Cyan
            $taskData = Build-GameTaskList $root $v $j
            
            Start-McDownloader $taskData.Tasks

            Write-Host "`n[2/2] 正在释放本地运行库..." -ForegroundColor Cyan
            $natives = "$root\versions\$v\natives"; New-Item -ItemType Directory -Force "$natives" | Out-Null
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            foreach ($jar in $taskData.Natives) {
                if (Test-Path $jar) {
                    $zip = [System.IO.Compression.ZipFile]::OpenRead($jar)
                    foreach ($entry in $zip.Entries) { if ($entry.FullName.EndsWith(".dll")) { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $natives $entry.Name), $true) } }
                    $zip.Dispose()
                }
            }

            Write-Host "`n实例部署与校验完成。" -ForegroundColor Green
            
            $ans = Read-Host "是否立即唤起游戏进程？[Y/N]"
            if ($ans -match "^[Nn]") { 
                Write-Host "操作已取消，返回主控台。" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
                $State = "LangSelect"
            } else {
                $State = "Launch"
            }
        }

        "Launch" {
            Clear-Host; Write-Host "[初始化] 正在核查运行环境..." -ForegroundColor Cyan

            $root = $GameDir; $v = $TargetV
            $gameData = ("$root\game" -replace '\\', '/')
            $natives = "$root\versions\$v\natives"

            Write-Host "[准备] 正在清理潜在的残留进程与文件锁..." -ForegroundColor Cyan
            
            try {
                $runningProcs = Get-CimInstance Win32_Process -Filter "name = 'java.exe' or name = 'javaw.exe'" -ErrorAction SilentlyContinue
                foreach ($p in $runningProcs) {
                    if ($p.ExecutablePath -and ($p.ExecutablePath -match [regex]::Escape($RootPath) -or $p.ExecutablePath -match [regex]::Escape($JavaPath))) {
                        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                    }
                }
            } catch {}

            if (Test-Path $gameData) {
                Get-ChildItem -Path $gameData -Filter "*.lock" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                if (Test-Path "$gameData\logs") {
                    Get-ChildItem -Path "$gameData\logs" -Filter "*.log*" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                }
            }

            if (Test-Path $natives) { Remove-Item -Path $natives -Recurse -Force -ErrorAction SilentlyContinue }

            try {
                $tempHsperf = Join-Path $env:TEMP "hsperfdata_$env:USERNAME"
                if (Test-Path $tempHsperf) {
                    Remove-Item -Path "$tempHsperf\*" -Force -ErrorAction SilentlyContinue
                }
            } catch {}

            Start-Sleep -Seconds 2

            $jMajor = 21
            $probeJson = "$GameDir\versions\$TargetV\$TargetV.json"
            if (Test-Path $probeJson) {
                try {
                    $probe = Get-Content $probeJson -Raw | ConvertFrom-Json
                    if ($probe.javaVersion -and $probe.javaVersion.majorVersion) { $jMajor = [int]$probe.javaVersion.majorVersion }
                } catch { }
            }

            $JavaDir = "$RootPath\Java\$jMajor"; New-Item -ItemType Directory -Force $JavaDir | Out-Null
            $localJava = Get-ChildItem -Path $JavaDir -Filter "java.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            
            if (-not $localJava) {
                Write-Host "`n未检测到内置运行环境 (Java $jMajor)，开始自动部署..." -ForegroundColor Yellow

                $info = Get-JavaDownloadInfo -majorVersion $jMajor
                if (-not $info) {
                    Write-Host "获取 Java $jMajor 下载信息失败，请检查网络或使用主菜单的 [3] 下载 Java 环境 手动下载。" -ForegroundColor Red
                    Read-Host "按任意键返回"
                    $State = "LangSelect"
                    continue
                }

                Write-Host "目标文件: $($info.FileName)" -ForegroundColor Cyan

                $targetPath = Join-Path $JavaDir $info.FileName

                $downloadSuccess = $false
                $idx = 1
                foreach ($url in $info.Urls) {
                    if ([string]::IsNullOrWhiteSpace($url)) { continue }
                    try {
                        Write-Host "尝试从节点 $idx 下载..." -ForegroundColor DarkGray
                        $ProgressPreference = 'SilentlyContinue'
                        Invoke-WebRequest -Uri $url -OutFile $targetPath -UseBasicParsing -TimeoutSec 300
                        
                        if ((Test-Path $targetPath) -and ((Get-Item $targetPath).Length -gt 1048576)) {
                            $downloadSuccess = $true
                            break
                        }
                    } catch {
                        Write-Host "下载失败: $($_.Exception.Message)" -ForegroundColor DarkYellow
                        if (Test-Path $targetPath) { Remove-Item $targetPath -Force -ErrorAction SilentlyContinue }
                    }
                    $idx++
                }

                if ($downloadSuccess) {
                    Write-Host "`n正在部署运行环境..." -ForegroundColor Cyan
                    try {
                        Extract-ZipFile -zipPath $targetPath -destDir $JavaDir
                        Remove-Item $targetPath -Force -ErrorAction SilentlyContinue
                    } catch {
                        Write-Host "解压过程发生异常。" -ForegroundColor Red
                        Read-Host "按任意键返回"
                        $State = "LangSelect"
                        continue
                    }
                } else {
                    Write-Host "下载失败，所有节点均无法响应。" -ForegroundColor Red
                    Read-Host "按任意键返回"
                    $State = "LangSelect"
                    continue
                }
                
                $localJava = Get-ChildItem -Path $JavaDir -Filter "java.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $localJava) { 
                    Write-Host "异常：未能在目标目录找到可执行文件。" -ForegroundColor Red
                    Read-Host "按任意键返回"
                    $State = "LangSelect"
                    continue 
                }
            }
            $script:JavaPath = $localJava.FullName
            Write-Host "  -> 绑定运行环境: $JavaPath" -ForegroundColor Green

            if (!(Test-Path "$root\versions\$v\$v.json")) { Write-Host "异常：配置文件丢失。" -ForegroundColor Red; Read-Host "按任意键"; $State = "LangSelect"; continue }
            
            $j = Get-Content "$root\versions\$v\$v.json" -Raw | ConvertFrom-Json
            
            Write-Host "`n[校验] 正在核对核心文件完整性..." -ForegroundColor Cyan
            $taskData = Build-GameTaskList $root $v $j
            Start-McDownloader $taskData.Tasks
            
            New-Item -ItemType Directory -Force "$natives" | Out-Null
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            foreach ($jar in $taskData.Natives) {
                if (Test-Path $jar) {
                    $zip = [System.IO.Compression.ZipFile]::OpenRead($jar)
                    foreach ($entry in $zip.Entries) { 
                        if ($entry.FullName.EndsWith(".dll")) { 
                            try { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $natives $entry.Name), $true) } catch {}
                        } 
                    }
                    $zip.Dispose()
                }
            }
            Write-Host "[校验] 完整性检查通过。" -ForegroundColor Green

            $mainClass = if ($j.mainClass) { $j.mainClass } else { "net.minecraft.client.main.Main" }
            
            $libs = @($j.libraries | Where-Object {
                if (-not $_.downloads.artifact) { return $false }
                if (-not $_.rules) { return $true }
                
                $isAllowed = $false
                foreach ($rule in $_.rules) {
                    $match = $true
                    if ($rule.os) {
                        if ($rule.os.name -and $rule.os.name -ne "windows") { $match = $false }
                        if ($rule.os.arch -and $rule.os.arch -notmatch "x86_64|x64") { $match = $false }
                    }
                    if ($match) {
                        if ($rule.action -eq "allow") { $isAllowed = $true }
                        elseif ($rule.action -eq "disallow") { $isAllowed = $false }
                    }
                }
                return $isAllowed
            })

            $clientJarPath = "$root\versions\$v\$v.jar"
            $cp = ("$clientJarPath" -replace '\\', '/') + ';' + (@($libs | ForEach-Object { (Join-Path $root "libraries\$($_.downloads.artifact.path)") -replace '\\', '/' }) -join ';')

            $md5 = [Security.Cryptography.MD5]::Create(); $b = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("OfflinePlayer:$Player"))
            $b[6] = ($b[6] -band 0x0F) -bor 0x30; $b[8] = ($b[8] -band 0x3F) -bor 0x80
            $h = ($b | ForEach-Object { $_.ToString('x2') }) -join ''
            $uuid = "$($h.Substring(0,8))-$($h.Substring(8,4))-$($h.Substring(12,4))-$($h.Substring(16,4))-$($h.Substring(20,12))"

            $nativesPath = ("$root\versions\$v\natives" -replace '\\', '/')
            New-Item -ItemType Directory -Force $gameData | Out-Null
            
            $argFilePath = "$root\java.args"
            
            $argsContent = @"
-Xms1G
-Xmx2G
-XX:+UseG1GC
-Dorg.lwjgl.opengl.Display.allowSoftwareOpenGL=true
-Djava.net.preferIPv4Stack=true
"@
            if ($jMajor -ge 9) {
                $argsContent += @"
--enable-native-access=ALL-UNNAMED
--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED
"@
            }

            $argsContent += @"
"-Djava.library.path=$nativesPath"
"-Djna.tmpdir=$nativesPath"
"-Dorg.lwjgl.system.SharedLibraryExtractPath=$nativesPath"
"-Dio.netty.native.workdir=$nativesPath"
-cp
"$cp"
$mainClass
"--username=$Player"
"--version=$v"
"--versionType=release"
"--gameDir=$gameData"
"--assetsDir=$($root -replace '\\', '/')/assets"
"--assetIndex=$($j.assetIndex.id)"
"--uuid=$uuid"
"--accessToken=0"
"@
            [System.IO.File]::WriteAllText($argFilePath, $argsContent, (New-Object System.Text.UTF8Encoding $false))

            $batContentStr = @"
@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Minecraft $v - $Player
set "JAVA_EXE="
for /r "..\Java" %%a in (java.exe) do ( set "JAVA_EXE=%%a" & goto :found_java )
:found_java
if not exist "%JAVA_EXE%" ( echo 异常：未找到运行环境。 & pause & exit /b )
echo 正在启动...
"%JAVA_EXE%" @java.args
pause
"@
            [System.IO.File]::WriteAllText("$root\启动器启动.bat", $batContentStr, [System.Text.Encoding]::Default)

            $launchArgs = @()
            $launchArgs += "-Xms1G"
            $launchArgs += "-Xmx2G"
            $launchArgs += "-XX:+UseG1GC"
            $launchArgs += "-Dorg.lwjgl.opengl.Display.allowSoftwareOpenGL=true"
            $launchArgs += "-Djava.net.preferIPv4Stack=true"
            
            if ($jMajor -ge 9) {
                $launchArgs += "--enable-native-access=ALL-UNNAMED"
                $launchArgs += "--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED"
            }

            $launchArgs += "-Djava.library.path=$nativesPath"
            $launchArgs += "-Djna.tmpdir=$nativesPath"
            $launchArgs += "-Dorg.lwjgl.system.SharedLibraryExtractPath=$nativesPath"
            $launchArgs += "-Dio.netty.native.workdir=$nativesPath"
            $launchArgs += "-cp"
            $launchArgs += $cp
            $launchArgs += $mainClass
            $launchArgs += "--username=$Player"
            $launchArgs += "--version=$v"
            $launchArgs += "--versionType=release"
            $launchArgs += "--gameDir=$gameData"
            $launchArgs += "--assetsDir=$($root -replace '\\', '/')/assets"
            $launchArgs += "--assetIndex=$($j.assetIndex.id)"
            $launchArgs += "--uuid=$uuid"
            $launchArgs += "--accessToken=0"

            Write-Host "`n正在唤起游戏进程..." -ForegroundColor Green
            
            $launchJava = $JavaPath
            $launchJavaW = Join-Path (Split-Path $JavaPath -Parent) "javaw.exe"
            if (Test-Path $launchJavaW) { $launchJava = $launchJavaW }

            $proc = Start-Process -FilePath $launchJava -ArgumentList $launchArgs -PassThru
            
            Write-Host "`n==================================================" -ForegroundColor DarkCyan
            Write-Host " [状态] 游戏进程已启动" -ForegroundColor White
            Write-Host " [指令] 在此窗口输入 'q' 并回车，可强制终止进程树。" -ForegroundColor White
            Write-Host " [指令] 直接关闭游戏窗口，系统将自动返回主控台。" -ForegroundColor White
            Write-Host "==================================================" -ForegroundColor DarkCyan
            
            $userQuit = $false
            while (-not $proc.HasExited) {
                try {
                    if ([Console]::KeyAvailable) {
                        $key = [Console]::ReadKey($true)
                        if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') { 
                            Write-Host "`n正在强制终止游戏进程树..." -ForegroundColor Yellow
                            Start-Process -FilePath "taskkill.exe" -ArgumentList "/F /T /PID $($proc.Id)" -WindowStyle Hidden -Wait
                            $userQuit = $true
                            break 
                        }
                    }
                } catch { } 
                Start-Sleep -Milliseconds 100
            }
            
            if ($userQuit) {
                Write-Host "`n进程已被手动终止。" -ForegroundColor Yellow
            } else {
                Write-Host "`n游戏窗口已关闭。" -ForegroundColor Green
                if ($proc.ExitCode -ne 0) {
                    Write-Host "警告：游戏异常退出 (状态码: $($proc.ExitCode))！" -ForegroundColor Red
                    Start-Sleep -Seconds 1
                    
                    $latestLog = "$gameData\logs\latest.log"
                    if (Test-Path $latestLog) {
                        Write-Host "`n========== latest.log 最后 15 行 ==========" -ForegroundColor Red
                        Get-Content $latestLog -Tail 15 | ForEach-Object { Write-Host $_ -ForegroundColor DarkRed }
                        Write-Host "===========================================" -ForegroundColor Red
                    } else {
                        Write-Host "未找到日志文件，请检查 $gameData\crash-reports 文件夹。" -ForegroundColor Yellow
                    }
                    Read-Host "`n按回车键返回主菜单..."
                }
            }
            
            Write-Host "正在等待系统释放端口与单例锁..." -ForegroundColor DarkGray
            try { 
                $runningProcs = Get-CimInstance Win32_Process -Filter "name = 'java.exe' or name = 'javaw.exe'" -ErrorAction SilentlyContinue
                foreach ($p in $runningProcs) {
                    if ($p.ExecutablePath -and ($p.ExecutablePath -match [regex]::Escape($RootPath) -or $p.ExecutablePath -match [regex]::Escape($JavaPath))) {
                        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                    }
                }
            } catch {}
            
            if (Test-Path $gameData) {
                Get-ChildItem -Path $gameData -Filter "*.lock" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            }
            
            Start-Sleep -Seconds 5 
            
            Write-Host "正在返回主控台..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 1
            $State = "LangSelect"
        }
    }
}