param (
    [string]$APK_PATH,
    [string]$DEVICE_SERIAL,
    [string]$AVD_NAME,
    [string]$OUTPUT_PATH,
    [string]$TEST_TIME,
    [string]$ENETCOUNT
)

Write-Output 'start run fastbot powershell script...'

$HEADLESS = $false
# 获取当前日期时间
$current_date_time = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"
# 获取 APK 文件的基本名称
$apk_file_name = [System.IO.Path]::GetFileName($APK_PATH)
$RESULT_DIR = Join-Path $OUTPUT_PATH "$apk_file_name.fastbot.result.$DEVICE_SERIAL.$AVD_NAME#$current_date_time"
$LOG_FILE = $RESULT_DIR + "\log.txt"


# 使用正则表达式提取端口号
if ($DEVICE_SERIAL -match 'emulator-(\d+)') {
    $AVD_PORT = $matches[1]
    Write-Output "The port is: $AVD_PORT"
} else {
    Write-Output "No port found in the string."
}

# 确保输出目录存在，不存在会自动创建
function Ensure-DirectoryExists {
    param (
        [string]$Directory
    )
    if (-not (Test-Path -Path $Directory -PathType Container)) {
        try {
            New-Item -ItemType Directory -Path $Directory -ErrorAction Stop
            Write-Output "Directory '$Directory' created successfully."
        } catch {
            Write-Output "Failed to create directory '$Directory'. Error: $_"
        }
    } else {
        Write-Output "Directory '$Directory' already exists."
    }
}
Ensure-DirectoryExists -Directory $RESULT_DIR

# 检查模拟器是否已经启动
function IsEmulatorRunning {
    param (
        [string]$port
    )
    $adbOutput = & adb devices
    return $adbOutput -match "emulator-$port"
}

# 以read-only模式启动模拟器，这样保证每一次重新运行设备时都是原始的状态，因为只有data的内容可以被修改。
function StartEmulator {
    param (
        [string]$avdName,
        [string]$port,
        [bool]$headless
    )
    $headlessFlag = ""
    if ($headless) {
        $headlessFlag = "-no-window"
    }
    Start-Process -FilePath "emulator" -ArgumentList ("-port $port -avd $avdName -read-only $headlessFlag") -NoNewWindow -PassThru
}

# 等待设备准备好
function WaitForDevice {
    param (
        [string]$deviceSerial
    )
    Write-Output "Waiting for device $deviceSerial to be ready..."
    & adb -s $deviceSerial wait-for-device 
    $bootAnimStatus = & adb -s $deviceSerial shell getprop init.svc.bootanim
    $i = 0
    while ($bootAnimStatus.Trim() -ne 'stopped') {
        Write-Output "   Waiting for emulator ($deviceSerial) to fully boot (#$i times) ..."
        Start-Sleep -Seconds 5
        $i++
        if ($i -eq 10) {
            Write-Output "Cannot connect to the device: ($deviceSerial) after (#$i times)..."
            break
        }
        $bootAnimStatus = & adb -s $deviceSerial shell getprop init.svc.bootanim
    }
    if ($bootAnimStatus.Trim() -eq 'stopped') {
        Write-Output "Device $deviceSerial is fully booted."
    }
}

# 判断设备是否启动，如果已经启动则杀死
while ((IsEmulatorRunning -port $AVD_PORT)) {
    Write-Output "Emulator on port $AVD_PORT is already running."
    Write-Output "Stopping emulator $DEVICE_SERIAL..."
    & adb -s $DEVICE_SERIAL emu kill
    Start-Sleep -Seconds 3
}

# 启动模拟器
Write-Output "Emulator on port $AVD_PORT is not running. Starting emulator..."
StartEmulator -avdName $AVD_NAME -port $AVD_PORT -headless $HEADLESS
WaitForDevice -deviceSerial "emulator-$AVD_PORT"

Start-Sleep -Seconds 3

# 获取应用包名
$packageInfo = & aapt dump badging $APK_PATH
$PACKAGE_NAME = $packageInfo | Select-String -Pattern "package: name='" | ForEach-Object {
    $_.Line -replace ".*package: name='([^']*)'.*", '$1'
}
# 注意正则匹配规则
Write-Output "** PROCESSING APP (${DEVICE_SERIAL}): $PACKAGE_NAME"

Start-Sleep -Seconds 1

# 授予root权限
Write-Output "  emulator ($DEVICE_SERIAL) is booted!"
& adb -s $DEVICE_SERIAL root

# 检查设备连接状态
Write-Output "** CHECKING DEVICE CONNECTION ($DEVICE_SERIAL)"
$device = & adb devices | Select-String $DEVICE_SERIAL
if (-not $device) {
    Write-Output "Device $DEVICE_SERIAL not connected."
    exit 1
}

# 卸载已安装的应用程序
Write-Output "** UNINSTALLING EXISTING APP"
try {
    & adb -s $DEVICE_SERIAL uninstall $PACKAGE_NAME
    Write-Output "Uninstall completed successfully."
} catch {
    Write-Output "Failed to uninstall app: $_"
}

# 安装应用并自动授予权限
adb -s $DEVICE_SERIAL install -g $APK_PATH
Start-Sleep -Seconds 2

#anroid 11 通过以下命令授予存储权限
&adb -s $DEVICE_SERIAL shell appops set --uid $PACKAGE_NAME MANAGE_EXTERNAL_STORAGE allow
Start-Sleep -Seconds 2

# 获取注册的广播接收器名称
$RECEIVER_NAME = adb -s $DEVICE_SERIAL shell pm dump $PACKAGE_NAME | Select-String "jacocoInstrument.SMSInstrumentedReceiver" | ForEach-Object {
    # 使用空格分隔并提取第二个内容
    $parts = $_ -split '\s+' # 按空格分隔
    if ($parts.Count -ge 2) {
        $parts[2] # 提取第3个元素
    }
}

# 打印获取到的接收器名称
Write-Output "Registered Broadcast Receiver: $RECEIVER_NAME"

Start-Sleep -Seconds 2

# 启动 logcat 并重定向输出
try {
    $process = Start-Process -FilePath "adb" -ArgumentList " logcat AndroidRuntime:E CrashAnrDetector:D System.err:W CustomActivityOnCrash:E ACRA:E WordPress-EDITOR:E *:F *:S" -RedirectStandardOutput "$RESULT_DIR/logcat.log" -NoNewWindow -PassThru
    Write-Output "Logcat started successfully with Process ID: $($process.Id)"
} catch {
    Write-Output "Failed to start logcat: $_"
}

# 检查 logcat 进程是否正在运行
Start-Sleep -Seconds 2
try {
    $logcatProcess = Get-Process -Id $process.Id -ErrorAction Stop
    Write-Output "Logcat process is running."
} catch {
    Write-Output "Logcat process is not running: $_"
}



# 启动覆盖率数据转储
Write-Output "** START COVERAGE ($DEVICE_SERIAL)"
Start-Process -FilePath "powershell" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "dump_coverage.ps1", $DEVICE_SERIAL, $PACKAGE_NAME, $RESULT_DIR, $RECEIVER_NAME -NoNewWindow -PassThru
Write-Output "Coverage dump started in background"

& adb -s $DEVICE_SERIAL shell mkdir /sdcard/$PACKAGE_NAME/
& adb -s $DEVICE_SERIAL shell date "+%Y-%m-%d-%H:%M:%S" | Out-File -FilePath "$RESULT_DIR/monkey_testing_time_on_emulator.txt" -Encoding utf8


# & adb -s $DEVICE_SERIAL shell "CLASSPATH=/sdcard/monkeyq.jar:/sdcard/framework.jar:/sdcard/fastbot-thirdpart.jar exec app_process /system/bin com.android.commands.monkey.Monkey -p $PACKAGE_NAME --agent reuseq --throttle 1000 -v --ignore-crashes --ignore-timeouts --ignore-security-exceptions --running-minutes $TEST_TIME --bugreport --output-directory /sdcard/$PACKAGE_NAME/" 2>&1 | Tee-Object -FilePath $LOG_FILE -Append

python3 start.py -d $DEVICE_SERIAL -a $APK_PATH -o $RESULT_DIR -timeout $TEST_TIME -interval 3 -count 100000 -keep_app -keep_env -policy dfs_greedy -grant_perm -is_emulator 2>&1 | Tee-Object -FilePath $LOG_FILE -Append

& adb -s $DEVICE_SERIAL shell date "+%Y-%m-%d-%H:%M:%S" | Out-File -FilePath "$RESULT_DIR/monkey_testing_time_on_emulator.txt" -Encoding utf8 -Append

# 存储log文件并清除
&adb -s $DEVICE_SERIAL pull /sdcard/$PACKAGE_NAME/crash-dump.log "$RESULT_DIR\crash-dump.log"
&adb -s $DEVICE_SERIAL shell rm /sdcard/$PACKAGE_NAME/crash-dump.log

# 停止覆盖率数据转储
Write-Output "** STOP COVERAGE ($DEVICE_SERIAL)"
$coverage_pid = Get-Process | Where-Object { $_.Path -eq "powershell" -and $_.CommandLine -like "*dump_coverage.ps1 $DEVICE_SERIAL*" } | Select-Object -ExpandProperty Id
if ($coverage_pid) {
    Stop-Process -Id $coverage_pid
}

# 停止 logcat
Write-Output "** STOP LOGCAT ($DEVICE_SERIAL)"
$logcat_pid = Get-Process | Where-Object { $_.Path -eq "adb" -and $_.CommandLine -like "*$DEVICE_SERIAL logcat*" } | Select-Object -ExpandProperty Id
if ($logcat_pid) {
    Stop-Process -Id $logcat_pid
}

# 关闭模拟器
Write-Output "Stopping emulator $DEVICE_SERIAL..."
Start-Sleep -Seconds 5  # 确保所有操作完成后再终止模拟器
& adb -s $DEVICE_SERIAL emu kill
Write-Output "@@@@@@ Finish ($DEVICE_SERIAL): $PACKAGE_NAME @@@@@@@"

exit