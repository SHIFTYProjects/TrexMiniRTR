#!/usr/bin/env zsh
setopt NULL_GLOB

if [ "$EUID" -ne 0 ]; then
    exit 1
fi

HOST=$(hostname)
DATE_STR=$(date "+%Y-%m-%d %H:%M:%S")
REPORT_DIR="/tmp/${HOST}_Trex_Reports"
mkdir -p "$REPORT_DIR"

run_cmd() {
    local timeout_secs=$1
    shift
    local tmp_out="/tmp/trex_cmd_${$}_${RANDOM}.tmp"
    
    ( "$@" > "$tmp_out" 2>/dev/null ) &
    local cmd_pid=$!
    
    local count=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
        if [ "$count" -ge "$timeout_secs" ]; then
            kill -9 "$cmd_pid" 2>/dev/null
            wait "$cmd_pid" 2>/dev/null
            rm -f "$tmp_out" 2>/dev/null
            return
        fi
        sleep 1
        count=$((count + 1))
    done
    wait "$cmd_pid" 2>/dev/null
    
    if [ -f "$tmp_out" ] && [ -s "$tmp_out" ]; then
        cat "$tmp_out"
        rm -f "$tmp_out" 2>/dev/null
    else
        rm -f "$tmp_out" 2>/dev/null
    fi
}

generate_html_report() {
    local title="$1"
    local content="$2"
    local outfile="$REPORT_DIR/${title}.html"
    cat <<EOF > "$outfile"
<html>
<head>
<style>
body{margin:0;font-family:sans-serif;background:#eee}
.hb{background:linear-gradient(135deg,#1e3c72 0%,#2a5298 100%);color:#fff;padding:20px;border-bottom:4px solid #b30000;margin-bottom:15px}
.hb h2{margin:0 0 5px 0}
.c{padding:0 15px 15px 15px}
table{width:100%;border-collapse:collapse;background:#fff}
th,td{border:1px solid #ccc;padding:8px;font-size:12px;text-align:left}
th{background:#1e3c72;color:#fff}
#report-content th{cursor:pointer}
#report-content th:hover{background:#2a5298}
pre{background:#fff;border:1px solid #ccc;padding:10px;overflow-x:auto;font-size:11px}
code{font-family:monospace;font-size:11px}
.search{margin:0 0 12px}
.search input{box-sizing:border-box;width:100%;max-width:480px;padding:8px;font-size:14px}
</style>
</head>
<body>
<div class='hb'><h2>TREX REPORT: ${title}</h2>Target Host: ${HOST}</div>
<div class='c'>
<div class='search'><input id='report-search' type='search' placeholder='Filter report rows and text...' aria-label='Filter report rows and text'></div>
<div id='report-content'>
${content}
</div>
<br><small style='color:#555;font-weight:bold;'>Context: REAL TIME RESPONSE - macOS DFIR PULL - $DATE_STR</small>
</div>
<script>
document.getElementById('report-search').addEventListener('input',function(){
    var query=this.value.toLowerCase();
    document.querySelectorAll('#report-content tr,#report-content pre').forEach(function(element){
        element.hidden=query!==''&&element.textContent.toLowerCase().indexOf(query)===-1;
    });
});
var collator=new Intl.Collator(undefined,{numeric:true,sensitivity:'base'});
document.querySelectorAll('#report-content th').forEach(function(header){
    var headerRow=header.parentElement;
    if(!Array.from(headerRow.cells).every(function(cell){return cell.tagName==='TH';}))return;
    header.title='Click to sort this column';
    header.addEventListener('click',function(){
        var table=header.closest('table');
        var column=Array.prototype.indexOf.call(headerRow.cells,header);
        var rows=Array.from(table.rows).filter(function(row){return row!==headerRow;});
        var direction=header.getAttribute('aria-sort')==='ascending'?-1:1;
        rows.sort(function(a,b){
            return direction*collator.compare(a.cells[column].textContent.trim(),b.cells[column].textContent.trim());
        });
        rows.forEach(function(row){row.parentElement.appendChild(row);});
        table.querySelectorAll('th').forEach(function(cell){cell.removeAttribute('aria-sort');});
        header.setAttribute('aria-sort',direction===1?'ascending':'descending');
    });
});
</script>
</body>
</html>
EOF
}

SYS_MODEL=$(sysctl -n hw.model)
CPU_NAME=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon / Generic CPU")
RAM_BYTES=$(sysctl -n hw.memsize)
RAM_GB=$((RAM_BYTES / 1024 / 1024 / 1024))
OS_VER=$(sw_vers -productVersion)
BUILD_VER=$(sw_vers -buildVersion)
BOOT_TIME=$(sysctl -n kern.boottime | awk '{print $4}' | tr -d ',')
BOOT_DATE=$(date -r "$BOOT_TIME" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "N/A")

SYS_INFO_HTML="<table>
<tr><th>Host Name</th><td>${HOST}</td></tr>
<tr><th>Domain / Network</th><td>$(domainname 2>/dev/null || echo "N/A")</td></tr>
<tr><th>OS Version</th><td>macOS ${OS_VER}</td></tr>
<tr><th>Build Version</th><td>Build ${BUILD_VER}</td></tr>
<tr><th>Model</th><td>Apple Inc. - ${SYS_MODEL}</td></tr>
<tr><th>CPU Architecture</th><td>${CPU_NAME}</td></tr>
<tr><th>Total RAM</th><td>${RAM_GB} GB</td></tr>
<tr><th>Last Boot Time</th><td>${BOOT_DATE}</td></tr>
</table>"
generate_html_report "01_System_Information" "$SYS_INFO_HTML"

generate_html_report "02_Launchd_Services" "<pre>$(run_cmd 5 launchctl list)</pre>"
generate_html_report "03_Active_Processes" "<pre>$(ps aux -r)</pre>"

APPS_LIST=$(ls -laT /Applications /System/Applications /Users/*/Applications 2>/dev/null)
generate_html_report "04_Installed_Applications" "<pre>${APPS_LIST}</pre>"

generate_html_report "05_Active_Network_Connections" "<pre>$(run_cmd 5 netstat -anv)</pre>"
generate_html_report "06_Network_Interfaces" "<pre>$(ifconfig -a)</pre>"

DISK_INFO=$(df -h; echo "\n=== Diskutil Information ==="; run_cmd 5 diskutil list)
generate_html_report "07_Disk_Mounts_Storage" "<pre>${DISK_INFO}</pre>"

SYSEXT_INFO=$(run_cmd 5 systemextensionsctl list)
KEXT_INFO=$(run_cmd 5 kmutil showloaded)
[ "$KEXT_INFO" = "[Command timed out after 5s]" ] && KEXT_INFO=$(run_cmd 5 kextstat)
generate_html_report "08_Kernel_System_Extensions" "<pre>=== System Extensions ===\n${SYSEXT_INFO}\n\n=== Kernel Extensions ===\n${KEXT_INFO}</pre>"

PERSIST_DATA="=== System LaunchDaemons ===\n$(ls -laT /Library/LaunchDaemons /System/Library/LaunchDaemons 2>/dev/null)\n\n=== System & User LaunchAgents ===\n$(ls -laT /Library/LaunchAgents /System/Library/LaunchAgents /Users/*/Library/LaunchAgents 2>/dev/null)"
generate_html_report "09_Persistence_LaunchDaemons_Agents" "<pre>${PERSIST_DATA}</pre>"

CRON_DATA=""
for u in /var/at/tabs/*(N) /etc/crontab(N); do
    [ -f "$u" ] && CRON_DATA+="=== Cron File: $u ===\n$(cat "$u" 2>/dev/null)\n\n"
done
[ -z "$CRON_DATA" ] && CRON_DATA="No active user or system crontabs found."
generate_html_report "10_Scheduled_Cron_Jobs" "<pre>${CRON_DATA}</pre>"

generate_html_report "11_SMB_File_Shares" "<pre>$(run_cmd 5 smbutil statshares -a || run_cmd 5 sharing -l || echo 'No active SMB shares')</pre>"

UPDATE_HIST=$(run_cmd 8 softwareupdate --history)
[ "$UPDATE_HIST" = "[Command timed out after 8s]" ] && UPDATE_HIST=$(pkgutil --pkgs)
generate_html_report "12_Installed_Packages_Updates" "<pre>${UPDATE_HIST}</pre>"

generate_html_report "13_Environment_Variables" "<pre>$(printenv)</pre>"

USB_DATA=$(run_cmd 6 system_profiler SPUSBDataType)
if [ -z "$USB_DATA" ] || [ "$USB_DATA" = "[Command timed out after 6s]" ]; then
    USB_DATA=$(ioreg -p IOUSB -l -w 0 2>/dev/null || ioreg -c IOUSBHostDevice -l 2>/dev/null)
fi
generate_html_report "14_USB_Connected_Devices" "<pre>${USB_DATA}</pre>"

generate_html_report "15_ARP_Cache" "<pre>$(arp -a)</pre>"
generate_html_report "16_Routing_Table" "<pre>$(netstat -rn)</pre>"
generate_html_report "17_DNS_Cache" "<pre>$(scutil --dns)</pre>"

FV_STATUS=$(fdesetup status 2>/dev/null)
SIP_STATUS=$(csrutil status 2>/dev/null)
GK_STATUS=$(spctl --status 2>/dev/null)
generate_html_report "18_DiskEncryption_SecurityPosture" "<pre>FileVault Encryption: ${FV_STATUS}\nSystem Integrity Protection (SIP): ${SIP_STATUS}\nGatekeeper Status: ${GK_STATUS}</pre>"

generate_html_report "19_Power_Management" "<pre>$(pmset -g live 2>/dev/null; echo "\n=== Power Assertions ==="; pmset -g assertions 2>/dev/null)</pre>"

FW_STATUS=$(socketfilterfw --getglobalstate 2>/dev/null || echo "Firewall query unavailable")
generate_html_report "20_Application_Firewall" "<pre>${FW_STATUS}\n\n=== Allowed Application Rules ===\n$(socketfilterfw --listapps 2>/dev/null)</pre>"

generate_html_report "21_Network_Hardware_Adapters" "<pre>$(networksetup -listallhardwareports 2>/dev/null)</pre>"
generate_html_report "22_System_Uptime" "<pre>$(uptime)</pre>"

LOG_SAMPLES=$(run_cmd 10 log show --predicate 'eventMessage contains "error" OR eventMessage contains "fail" OR process == "sudo" OR process == "tccd"' --last 24h)
generate_html_report "23_Unified_System_Logs" "<pre>${LOG_SAMPLES}</pre>"

generate_html_report "24_Hosts_File" "<pre>$(cat /etc/hosts)</pre>"

BTM_DATA=$(plutil -p /var/db/com.apple.backgroundtaskmanagement/ServiceManagement.plist 2>/dev/null || plutil -p /Users/*/Library/Preferences/com.apple.loginitems.plist 2>/dev/null || echo "N/A")
generate_html_report "25_Persistence_LoginItems_BTM" "<pre>${BTM_DATA}</pre>"

HIST_LOG=""
for user_dir in /Users/*(N) /var/root(N); do
    u=$(basename "$user_dir")
    for hfile in "$user_dir/.zsh_history" "$user_dir/.bash_history" "$user_dir/.sh_history"; do
        if [ -f "$hfile" ]; then
            HIST_LOG+="=== User: $u ($hfile) ===\n$(cat "$hfile" 2>/dev/null)\n\n"
        fi
    done
done
generate_html_report "26_User_Shell_Histories" "<pre>${HIST_LOG}</pre>"

RECENT_DATA=$(ls -laT /Users/*/Library/Application\ Support/com.apple.sharedfilelist/* 2>/dev/null || echo "N/A")
generate_html_report "27_Recent_Files_SharedFileList" "<pre>${RECENT_DATA}</pre>"

WIFI_REPORT="=== Preferred Wireless Networks (networksetup) ===\n"
WIFI_INT=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2}')
if [ -n "$WIFI_INT" ]; then
    WIFI_REPORT+=$(networksetup -listpreferredwirelessnetworks "$WIFI_INT" 2>/dev/null)
fi
if [ -f "/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist" ]; then
    WIFI_REPORT+="\n\n=== Airport System Preferences Artifacts ===\n"
    WIFI_REPORT+=$(plutil -p /Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist 2>/dev/null)
fi
if [ -f "/Library/Preferences/SystemConfiguration/com.apple.wifi.message-tracer.plist" ]; then
    WIFI_REPORT+="\n\n=== WiFi Message Tracer Log ===\n"
    WIFI_REPORT+=$(plutil -p /Library/Preferences/SystemConfiguration/com.apple.wifi.message-tracer.plist 2>/dev/null)
fi
generate_html_report "28_WiFi_Saved_Networks" "<pre>${WIFI_REPORT}</pre>"

SYS_EXTS=$(run_cmd 5 systemextensionsctl list)
generate_html_report "29_System_Extensions_Persistence" "<pre>${SYS_EXTS}</pre>"

DL_REPORT=""
QUARANTINE_DIR="$REPORT_DIR/QuarantineDBs"
mkdir -p "$QUARANTINE_DIR"

for user_dir in /Users/*(N); do
    u=$(basename "$user_dir")
    if [ -d "$user_dir/Downloads" ]; then
        for item in "$user_dir/Downloads"/*(N); do
            if [ -e "$item" ]; then
                ctime=$(date -r "$item" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
                DL_REPORT+="$u | $(basename "$item") | $ctime\n"
            fi
        done
    fi
    qdb="$user_dir/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
    if [ -f "$qdb" ]; then
        cp "$qdb" "$QUARANTINE_DIR/${u}_QuarantineEventsV2.db" 2>/dev/null
    fi
done
generate_html_report "30_User_Downloads_Quarantine" "<pre>${DL_REPORT}</pre>"

USERS_LIST=$(dscl . -list /Users | grep -v '^_'; echo "\n=== Home Directories ==="; ls -laT /Users)
generate_html_report "31_User_Accounts_Profiles" "<pre>${USERS_LIST}</pre>"

WEB_HIST_DIR="$REPORT_DIR/WebHist"
mkdir -p "$WEB_HIST_DIR"
BROWSER_SUMMARY=""

extract_chromium_artifacts() {
    local base_path="$1" browser_name="$2" user_name="$3"
    if [ -d "$base_path" ]; then
        BROWSER_SUMMARY+="- Found ${browser_name} for user: ${user_name}\n"
        find "$base_path" -name "History" -exec cp {} "$WEB_HIST_DIR/${user_name}_${browser_name}_History.db" \; 2>/dev/null
        find "$base_path" -name "Cookies" -exec cp {} "$WEB_HIST_DIR/${user_name}_${browser_name}_Cookies.db" \; 2>/dev/null
        find "$base_path" -name "Login Data" -exec cp {} "$WEB_HIST_DIR/${user_name}_${browser_name}_LoginData.db" \; 2>/dev/null
        find "$base_path" -name "Web Data" -exec cp {} "$WEB_HIST_DIR/${user_name}_${browser_name}_WebData.db" \; 2>/dev/null
    fi
}

for user_dir in /Users/*(N) /var/root(N); do
    u=$(basename "$user_dir")
    extract_chromium_artifacts "$user_dir/Library/Application Support/Google/Chrome" "Chrome" "$u"
    extract_chromium_artifacts "$user_dir/Library/Application Support/Microsoft Edge" "Edge" "$u"
    extract_chromium_artifacts "$user_dir/Library/Application Support/BraveSoftware/Brave-Browser" "Brave" "$u"
    extract_chromium_artifacts "$user_dir/Library/Application Support/Arc" "Arc" "$u"
    extract_chromium_artifacts "$user_dir/Library/Application Support/Vivaldi" "Vivaldi" "$u"
    extract_chromium_artifacts "$user_dir/Library/Application Support/com.operasoftware.Opera" "Opera" "$u"

    s_path="$user_dir/Library/Safari"
    if [ -d "$s_path" ]; then
        BROWSER_SUMMARY+="- Found Safari for user: ${u}\n"
        cp "$s_path/History.db" "$WEB_HIST_DIR/${u}_Safari_History.db" 2>/dev/null
        cp "$s_path/Bookmarks.plist" "$WEB_HIST_DIR/${u}_Safari_Bookmarks.plist" 2>/dev/null
        cp "$s_path/Downloads.plist" "$WEB_HIST_DIR/${u}_Safari_Downloads.plist" 2>/dev/null
    fi

    f_path="$user_dir/Library/Application Support/Firefox/Profiles"
    if [ -d "$f_path" ]; then
        BROWSER_SUMMARY+="- Found Firefox for user: ${u}\n"
        find "$f_path" -name "places.sqlite" -exec cp {} "$WEB_HIST_DIR/${u}_Firefox_places.sqlite" \; 2>/dev/null
        find "$f_path" -name "cookies.sqlite" -exec cp {} "$WEB_HIST_DIR/${u}_Firefox_cookies.sqlite" \; 2>/dev/null
        find "$f_path" -name "logins.json" -exec cp {} "$WEB_HIST_DIR/${u}_Firefox_logins.json" \; 2>/dev/null
    fi
done

generate_html_report "32_Browser_Artifacts_Summary" "<pre>Extracted Raw Database Copies to 'WebHist/' Folder:\n\n${BROWSER_SUMMARY}</pre>"

LOG_DIR="$REPORT_DIR/EvtLogs"
mkdir -p "$LOG_DIR"
cp /var/log/system.log* "$LOG_DIR/" 2>/dev/null
cp /var/log/install.log* "$LOG_DIR/" 2>/dev/null
cp /var/log/wifi.log* "$LOG_DIR/" 2>/dev/null

TIMELINE_CSV="$REPORT_DIR/SuperTimeline.csv"
echo '"Timestamp","MACB","Artifact_Type","User","Details"' > "$TIMELINE_CSV"

add_tl_entry() {
    local ts="$1" macb="$2" art="$3" user="$4" det="$5"
    [ -z "$ts" ] || [ "$ts" = "N/A" ] && return
    local clean_det=$(echo "$det" | tr '\r\n' ' ' | sed 's/"/""/g')
    echo "\"$ts\",\"$macb\",\"$art\",\"$user\",\"$clean_det\"" >> "$TIMELINE_CSV"
}

if [ -n "$BOOT_DATE" ] && [ "$BOOT_DATE" != "N/A" ]; then
    add_tl_entry "$BOOT_DATE" "M..." "SystemBoot" "SYSTEM" "System Last Boot Time"
fi

for user_dir in /Users/*(N) /var/root(N); do
    u=$(basename "$user_dir")
    for hfile in "$user_dir/.zsh_history" "$user_dir/.bash_history" "$user_dir/.sh_history"; do
        if [ -f "$hfile" ]; then
            mtime=$(date -r "$hfile" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
            add_tl_entry "$mtime" "M..." "ShellHistoryFile" "$u" "History file last modified: $hfile"
            
            grep -E '^: [0-9]+:[0-9]+;' "$hfile" 2>/dev/null | tail -n 200 | while IFS= read -r line; do
                epoch=$(echo "$line" | sed -E 's/^: ([0-9]+):.*/\1/')
                cmd=$(echo "$line" | sed -E 's/^: [0-9]+:[0-9]+;//')
                if [ -n "$epoch" ]; then
                    formatted_ts=$(date -r "$epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
                    [ -n "$formatted_ts" ] && add_tl_entry "$formatted_ts" "...B" "ShellCommand" "$u" "Executed: $cmd"
                fi
            done
        fi
    done
done

for user_dir in /Users/*(N); do
    u=$(basename "$user_dir")
    if [ -d "$user_dir/Downloads" ]; then
        for item in "$user_dir/Downloads"/*(N); do
            if [ -e "$item" ]; then
                mtime=$(date -r "$item" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
                add_tl_entry "$mtime" "MACB" "UserDownload" "$u" "Downloaded File Present: $(basename "$item")"
            fi
        done
    fi
done

if command -v sqlite3 >/dev/null 2>&1; then
    for qdb in "$QUARANTINE_DIR"/*.db(N); do
        [ -f "$qdb" ] || continue
        u=$(basename "$qdb" | cut -d'_' -f1)
        sqlite3 "$qdb" "SELECT datetime(LSQuarantineTimeStamp + 978307200, 'unixepoch', 'localtime'), LSQuarantineDataURL, LSQuarantineOriginURLHeader, LSQuarantineSenderName FROM LSQuarantineEvent WHERE LSQuarantineTimeStamp IS NOT NULL ORDER BY LSQuarantineTimeStamp DESC LIMIT 300;" 2>/dev/null | while IFS='|' read -r qts qdata qorigin qsender; do
            [ -n "$qts" ] && add_tl_entry "$qts" "...B" "QuarantineDownload" "$u" "DataURL: $qdata | Origin: $qorigin | Sender: $qsender"
        done
    done

    for hdb in "$WEB_HIST_DIR"/*_History.db(N) "$WEB_HIST_DIR"/*_places.sqlite(N); do
        [ -f "$hdb" ] || continue
        fname=$(basename "$hdb")
        u=$(echo "$fname" | cut -d'_' -f1)
        bname=$(echo "$fname" | cut -d'_' -f2)

        if [[ "$fname" == *"Safari"* ]]; then
            sqlite3 "$hdb" "SELECT datetime(v.visit_time + 978307200, 'unixepoch', 'localtime'), i.url, i.title FROM history_visits v JOIN history_items i ON v.history_item = i.id ORDER BY v.visit_time DESC LIMIT 300;" 2>/dev/null | while IFS='|' read -r bts burl btitle; do
                [ -n "$bts" ] && add_tl_entry "$bts" "...B" "WebVisit_Safari" "$u" "URL: $burl | Title: $btitle"
            done
        elif [[ "$fname" == *"Firefox"* ]]; then
            sqlite3 "$hdb" "SELECT datetime(v.visit_date/1000000, 'unixepoch', 'localtime'), p.url, p.title FROM moz_historyvisits v JOIN moz_places p ON v.place_id = p.id ORDER BY v.visit_date DESC LIMIT 300;" 2>/dev/null | while IFS='|' read -r bts burl btitle; do
                [ -n "$bts" ] && add_tl_entry "$bts" "...B" "WebVisit_Firefox" "$u" "URL: $burl | Title: $btitle"
            done
        else
            sqlite3 "$hdb" "SELECT datetime(last_visit_time/1000000 - 11644473600, 'unixepoch', 'localtime'), url, title FROM urls WHERE last_visit_time > 0 ORDER BY last_visit_time DESC LIMIT 300;" 2>/dev/null | while IFS='|' read -r bts burl btitle; do
                [ -n "$bts" ] && add_tl_entry "$bts" "...B" "WebVisit_${bname}" "$u" "URL: $burl | Title: $btitle"
            done
        fi
    done
fi

MANIFEST_CSV="$REPORT_DIR/Manifest.csv"
HASH_DATE=$(date "+%Y-%m-%d %H:%M:%S")

echo '"File_Path","SHA256_Hash","Hash_Date","Artifact_Explanation"' > "$MANIFEST_CSV"

get_explanation() {
    local f="$1"
    case "$f" in
        *01_System_Information.html) echo "System hardware, OS version, boot time, and CPU architecture summary" ;;
        *02_Launchd_Services.html) echo "Active and loaded launchd system services" ;;
        *03_Active_Processes.html) echo "List of running processes ordered by CPU/memory utilization" ;;
        *04_Installed_Applications.html) echo "Enumeration of installed applications across system and user paths" ;;
        *05_Active_Network_Connections.html) echo "Active socket connections and network socket states (netstat)" ;;
        *06_Network_Interfaces.html) echo "Network interface configurations and assigned IP addresses (ifconfig)" ;;
        *07_Disk_Mounts_Storage.html) echo "Mounted filesystems, disk usage, and physical partition layouts" ;;
        *08_Kernel_System_Extensions.html) echo "Loaded kernel extensions (kexts) and system extensions" ;;
        *09_Persistence_LaunchDaemons_Agents.html) echo "System and user persistence mechanisms via LaunchDaemons and LaunchAgents" ;;
        *10_Scheduled_Cron_Jobs.html) echo "Active user and system scheduled cron jobs" ;;
        *11_SMB_File_Shares.html) echo "Active SMB file shares and established remote session details" ;;
        *12_Installed_Packages_Updates.html) echo "Software update history and installed installer package receipts" ;;
        *13_Environment_Variables.html) echo "Global environment variables" ;;
        *14_USB_Connected_Devices.html) echo "Connected USB hardware devices, serial numbers, and controller tree" ;;
        *15_ARP_Cache.html) echo "Address Resolution Protocol (ARP) table mapping IP to MAC addresses" ;;
        *16_Routing_Table.html) echo "Kernel IP network routing table entries" ;;
        *17_DNS_Cache.html) echo "Client DNS resolver cache and active DNS configurations" ;;
        *18_DiskEncryption_SecurityPosture.html) echo "Security state: FileVault disk encryption, SIP status, and Gatekeeper state" ;;
        *19_Power_Management.html) echo "Power profiles, sleep prevention assertions, and battery states" ;;
        *20_Application_Firewall.html) echo "macOS Application Firewall configuration and process exemption rules" ;;
        *21_Network_Hardware_Adapters.html) echo "Physical and virtual network adapter mappings and MAC addresses" ;;
        *22_System_Uptime.html) echo "System uptime and rolling CPU load averages" ;;
        *23_Unified_System_Logs.html) echo "Filtered security events and error entries from macOS Unified Logging" ;;
        *24_Hosts_File.html) echo "Contents of static domain resolution mapping file (/etc/hosts)" ;;
        *25_Persistence_LoginItems_BTM.html) echo "User login items and Background Task Management (BTM) database state" ;;
        *26_User_Shell_Histories.html) echo "Command execution history logs (zsh/bash/sh) across all user accounts" ;;
        *27_Recent_Files_SharedFileList.html) echo "Most Recently Used (MRU) files and com.apple.sharedfilelist artifacts" ;;
        *28_WiFi_Saved_Networks.html) echo "Saved Wi-Fi SSIDs, security profiles, and system airport configuration artifacts" ;;
        *29_System_Extensions_Persistence.html) echo "Registered system extensions and endpoint security agents" ;;
        *30_User_Downloads_Quarantine.html) echo "User Download directory contents and LSQuarantine download origin metadata" ;;
        *31_User_Accounts_Profiles.html) echo "Local user accounts, system groups, and home directory listings" ;;
        *32_Browser_Artifacts_Summary.html) echo "Summary of multi-browser artifact database extractions" ;;
        *SuperTimeline.csv) echo "Unified chronological MACB supertimeline containing system activity" ;;
        *WebHist/*) echo "Extracted raw browser database containing history, cookies, logins, or autofill data" ;;
        *QuarantineDBs/*) echo "Raw LaunchServices QuarantineEventsV2 SQLite database containing downloaded file URLs" ;;
        *EvtLogs/*) echo "Raw system log, installer log, Wi-Fi log, or BSM audit log file" ;;
        *) echo "DFIR triage collected evidence artifact" ;;
    esac
}

find "$REPORT_DIR" -type f ! -name "Manifest.csv" | while IFS= read -r filepath; do
    relpath="${filepath#$REPORT_DIR/}"
    hashval=$(shasum -a 256 "$filepath" | awk '{print $1}')
    expl=$(get_explanation "$relpath")
    clean_expl=$(echo "$expl" | sed 's/"/""/g')
    echo "\"$relpath\",\"$hashval\",\"$HASH_DATE\",\"$clean_expl\"" >> "$MANIFEST_CSV"
done

MANIFEST_ROWS=""
while IFS=, read -r r_path r_hash r_date r_expl; do
    [[ "$r_path" == '"File_Path"' ]] && continue
    c_path=$(echo "$r_path" | sed 's/"//g')
    c_hash=$(echo "$r_hash" | sed 's/"//g')
    c_date=$(echo "$r_date" | sed 's/"//g')
    c_expl=$(echo "$r_expl" | sed 's/"//g')
    MANIFEST_ROWS+="<tr><td>${c_path}</td><td><code>${c_hash}</code></td><td>${c_date}</td><td>${c_expl}</td></tr>\n"
done < "$MANIFEST_CSV"

generate_html_report "34_Forensic_Manifest" "<table><tr><th>File Path</th><th>SHA256 Hash</th><th>Hash Date</th><th>Artifact Explanation</th></tr>${MANIFEST_ROWS}</table>"

MAN_HTML_PATH="$REPORT_DIR/34_Forensic_Manifest.html"
MAN_HTML_HASH=$(shasum -a 256 "$MAN_HTML_PATH" | awk '{print $1}')
echo "\"34_Forensic_Manifest.html\",\"$MAN_HTML_HASH\",\"$HASH_DATE\",\"Cryptographic manifest report containing SHA256 hashes for all collected artifacts\"" >> "$MANIFEST_CSV"

HTML_HASH_FILE="$REPORT_DIR/HTML-SHA256.txt"
{
    printf '%s\n' "SHA256 hashes for generated HTML reports"
    for report in "$REPORT_DIR"/*.html(N); do
        report_hash=$(shasum -a 256 "$report" | awk '{print $1}')
        if [ -z "$report_hash" ]; then
            echo "[!] Failed to hash HTML report: $report" >&2
            exit 1
        fi
        printf '%s  %s\n' "$report_hash" "$(basename "$report")"
    done
} > "$HTML_HASH_FILE"

HTML_HASH=$(shasum -a 256 "$HTML_HASH_FILE" | awk '{print $1}')
if [ -z "$HTML_HASH" ]; then
    echo "[!] Failed to hash HTML-SHA256.txt" >&2
    exit 1
fi
echo "\"HTML-SHA256.txt\",\"$HTML_HASH\",\"$HASH_DATE\",\"SHA256 hashes for all generated HTML reports\"" >> "$MANIFEST_CSV"

ZIP_PATH="/tmp/${HOST}_TREX.zip"
rm -f "$ZIP_PATH"
zip -r "$ZIP_PATH" "$REPORT_DIR" >/dev/null 2>&1
rm -rf "$REPORT_DIR"

echo "[+] macOS DFIR collection completed: ${ZIP_PATH}"