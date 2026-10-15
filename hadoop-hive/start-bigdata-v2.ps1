# ---- EDIT THESE ----
$JavaHome    = "C:\PROGRA~1\Java\jdk1.8.0_202"          # 8.3 short path avoids the space in "Program Files"
$HadoopHome  = "C:\opt\rbc\software\hadoop-3.3.6"       # your Windows Hadoop folder
$StartHadoop = $true                                    # $false if Hive runs in local mode only
$HdfsExtraDelay = 20                                    # seconds to let NameNode/DataNode settle
$HiveExtraDelay = 30                                    # seconds to let HiveServer2 finish initializing

# ---- Local S3 (used by Hive external tables: s3a://bucket/path/) ----
$ConfigureS3A      = $true                              # $false = skip all S3 setup
$S3Endpoint        = "http://127.0.0.1:8333"
$S3AccessKey       = "admin"
$S3SecretKey       = "admin12345"
$S3TestBucket      = "dev"                              # bucket used for the connectivity test (must exist)
$RestartHiveServer = $true                              # if HiveServer2 is already running, restart it so it loads the S3A jars/config
# --------------------
$Distro = "Ubuntu"

function Wait-Port($port, $name, $maxSeconds = 300) {
    $end = (Get-Date).AddSeconds($maxSeconds)
    while ((Get-Date) -lt $end) {
        if (Test-NetConnection 127.0.0.1 -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue) {
            Write-Host "$name is UP (port $port)" -ForegroundColor Green; return $true
        }
        Start-Sleep -Seconds 5
    }
    Write-Host "$name did not start within $maxSeconds seconds" -ForegroundColor Red; return $false
}

# Bash script that is copied into WSL (~/setup-s3a.sh) and run before HiveServer2 starts.
# - links the S3A jars (already shipped with Hadoop 3.3.6) into Hive's lib folder
# - writes fs.s3a.* settings into WSL Hadoop's core-site.xml (block is replaced on every run)
# - tests the connection with "hadoop fs -ls s3a://<bucket>/"
$S3ASetupScript = @'
#!/bin/bash
# env in: S3_ENDPOINT S3_ACCESS S3_SECRET S3_TEST_BUCKET
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export HADOOP_HOME=$HOME/hadoop-3.3.6
export HIVE_HOME=$HOME/apache-hive-4.0.1-bin
HCONF=${HADOOP_CONF_DIR:-$HADOOP_HOME/etc/hadoop}
STATUS=0

# 1) Pick an endpoint that WSL can actually reach
HOSTPORT=${S3_ENDPOINT#http://}; HOSTPORT=${HOSTPORT#https://}
S3HOST=${HOSTPORT%%:*}; S3PORT=${HOSTPORT##*:}
reach() { timeout 3 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null; }
EP="$S3_ENDPOINT"
if reach "$S3HOST" "$S3PORT"; then
  echo "[s3a] $S3HOST:$S3PORT reachable from WSL"
else
  WINIP=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
  if [ -n "$WINIP" ] && reach "$WINIP" "$S3PORT"; then
    EP="http://$WINIP:$S3PORT"
    echo "[s3a] $S3HOST:$S3PORT NOT reachable from WSL; using Windows host $EP instead"
  else
    echo "[s3a] WARNING: S3 not reachable from WSL on $S3HOST:$S3PORT or host $WINIP:$S3PORT"
    echo "[s3a]          Is the S3 server running? Does it listen on 0.0.0.0 (not only 127.0.0.1)? Firewall?"
    STATUS=1
  fi
fi

# 2) S3A jars -> Hive lib (symlinks to the jars shipped in Hadoop)
TOOLS=$HADOOP_HOME/share/hadoop/tools/lib
for pat in 'hadoop-aws-*.jar' 'aws-java-sdk-bundle-*.jar'; do
  f=$(ls $TOOLS/$pat 2>/dev/null | head -1)
  if [ -z "$f" ]; then
    echo "[s3a] ERROR: $pat not found in $TOOLS"; STATUS=1
  else
    ln -sf "$f" "$HIVE_HOME/lib/$(basename "$f")"
    echo "[s3a] linked $(basename "$f") into Hive lib"
  fi
done

# 3) fs.s3a.* settings in core-site.xml
FILE="$HCONF/core-site.xml"
[ -f "$FILE" ] && cp -n "$FILE" "$FILE.bak-before-s3a"
python3 - "$FILE" "$EP" "$S3_ACCESS" "$S3_SECRET" <<'PY'
import re, sys, os
from xml.sax.saxutils import escape
path, endpoint, ak, sk = sys.argv[1:5]
props = [
 ("fs.s3a.endpoint", endpoint),
 ("fs.s3a.access.key", ak),
 ("fs.s3a.secret.key", sk),
 ("fs.s3a.path.style.access", "true"),
 ("fs.s3a.connection.ssl.enabled", "false"),
 ("fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem"),
 ("fs.s3a.aws.credentials.provider", "org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider"),
 ("fs.s3a.endpoint.region", "us-east-1"),
]
block = "<!-- S3A-BEGIN (managed by start-bigdata script) -->\n"
for k, v in props:
    block += "  <property><name>%s</name><value>%s</value></property>\n" % (k, escape(v))
block += "<!-- S3A-END -->\n"
s = open(path).read() if os.path.exists(path) else '<?xml version="1.0"?>\n<configuration>\n</configuration>\n'
s = re.sub(r"[ \t]*<!-- S3A-BEGIN.*?<!-- S3A-END -->\n?", "", s, flags=re.S)
i = s.rfind("</configuration>")
s = s[:i] + block + s[i:]
open(path, "w").write(s)
print("[s3a] wrote S3A settings to " + path + " (endpoint " + endpoint + ")")
PY

# 4) connectivity test (independent of Hive)
export HADOOP_OPTIONAL_TOOLS=hadoop-aws
echo "[s3a] testing: hadoop fs -ls s3a://$S3_TEST_BUCKET/"
"$HADOOP_HOME/bin/hadoop" fs -D fs.s3a.retry.limit=1 -D fs.s3a.attempts.maximum=1 \
    -D fs.s3a.connection.establish.timeout=5000 -ls "s3a://$S3_TEST_BUCKET/" 2>&1 | tail -n 12
if [ "${PIPESTATUS[0]}" -eq 0 ]; then echo "[s3a] TEST OK"; else echo "[s3a] TEST FAILED"; STATUS=1; fi
exit $STATUS
# end of script
'@

function Setup-S3A {
    Write-Host "Configuring S3A (jars + settings) in WSL..."
    ($S3ASetupScript -replace "`r", "") | wsl.exe -d $Distro -- bash -c "cat > ~/setup-s3a.sh && chmod +x ~/setup-s3a.sh"
    $cmd = "S3_ENDPOINT='$S3Endpoint' S3_ACCESS='$S3AccessKey' S3_SECRET='$S3SecretKey' S3_TEST_BUCKET='$S3TestBucket' bash ~/setup-s3a.sh"
    wsl.exe -d $Distro -- bash -lc $cmd
    if ($LASTEXITCODE -eq 0) {
        Write-Host "S3A is configured and the S3 test passed." -ForegroundColor Green
    } else {
        Write-Host "S3A setup finished with problems (see [s3a] lines above). Hive will still start, but s3a:// tables may fail." -ForegroundColor Yellow
    }
}

if ($StartHadoop) {
    $env:JAVA_HOME   = $JavaHome
    $env:HADOOP_HOME = $HadoopHome
    $env:Path = "$JavaHome\bin;$HadoopHome\bin;$HadoopHome\sbin;$env:Path"
    Write-Host "Starting HDFS..."
    Start-Process -FilePath "$HadoopHome\sbin\start-dfs.cmd" -WorkingDirectory $HadoopHome
    Wait-Port 9870 "HDFS NameNode UI" | Out-Null

    Write-Host "Letting HDFS settle for $HdfsExtraDelay seconds..."
    Start-Sleep -Seconds $HdfsExtraDelay
    Write-Host "Waiting for HDFS to leave safe mode..."
    & "$HadoopHome\bin\hdfs.cmd" dfsadmin -safemode wait
}

# HiveServer2 is launched through a helper script inside WSL (~/start-hs2.sh).
# It keeps the window open after an exit/crash and logs to ~/hive-data/hs2.log
wsl.exe -d $Distro -- bash -c "test -f ~/start-hs2.sh"
if ($LASTEXITCODE -ne 0) {
    Write-Host "~/start-hs2.sh not found in WSL ($Distro). Create it first, then rerun." -ForegroundColor Red
    exit 1
}

if ($ConfigureS3A) {
    Setup-S3A

    # HiveServer2 only reads jars/config at startup, so an already-running instance must be restarted
    if ($RestartHiveServer -and (Test-NetConnection 127.0.0.1 -Port 10000 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
        Write-Host "HiveServer2 is already running - stopping it so it loads the S3A jars/config..." -ForegroundColor Yellow
        wsl.exe -d $Distro -- bash -c "pkill -f org.apache.hive.service.server.HiveServer2; sleep 5"
        Start-Sleep -Seconds 3
    }
}

Write-Host "Starting HiveServer2 in WSL (a new window opens; keep it open)..."
Start-Process -FilePath "wsl.exe" -ArgumentList ('-d ' + $Distro + ' -- bash -lc "~/start-hs2.sh"')
Wait-Port 10000 "HiveServer2" | Out-Null

Write-Host "Letting HiveServer2 finish initializing for $HiveExtraDelay seconds..."
Start-Sleep -Seconds $HiveExtraDelay

# Verify with a real query through beeline (retry up to 10 times)
$check = 'export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64; export HADOOP_HOME=$HOME/hadoop-3.3.6; export HIVE_HOME=$HOME/apache-hive-4.0.1-bin; export PATH=$HADOOP_HOME/bin:$HIVE_HOME/bin:$PATH; beeline -u jdbc:hive2://localhost:10000/default -n hive -e ''select 1'' > /dev/null 2>&1'
$ok = $false
for ($i = 1; $i -le 10; $i++) {
    wsl.exe -d $Distro -- bash -c $check
    if ($LASTEXITCODE -eq 0) { $ok = $true; break }
    Write-Host "Hive query test failed (attempt $i/10), retrying in 10s..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
}

if ($ok) {
    Write-Host "`nHiveServer2 is accepting queries." -ForegroundColor Green
} else {
    Write-Host "`nPort is open but queries still fail. Check the WSL window and ~/hive-data/hs2.log" -ForegroundColor Red
}
Write-Host "DBeaver/beeline URL: jdbc:hive2://127.0.0.1:10000/default  (web UI: http://localhost:10002)"
if ($ConfigureS3A) {
    Write-Host "S3 location example: LOCATION 's3a://$S3TestBucket/db/common/batchconfig/'  (endpoint $S3Endpoint)"
}