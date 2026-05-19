@echo off
chcp 65001 > nul
:: 65001 - UTF-8

cd /d "%~dp0"
call service.bat status_zapret
call service.bat check_updates
call service.bat load_game_filter
call service.bat load_user_lists
call service.bat load_realtime_profile

set "GameFilterUDPVoice=%GameFilterUDP%"
set "GameFilterUDPGame=%GameFilterUDP%"
set "GameFilterUDPVideo=%GameFilterUDP%"
set "UDPVoiceRepeats=4"
set "UDPVoiceCutoff=n2"
set "UDPGameRepeats=6"
set "UDPGameCutoff=n2"
set "UDPGameFakeLimit=8/s"
set "UDPVideoRepeats=5"
set "UDPVideoCutoff=n2"
if /I "%RealtimeUDPProfile%"=="realtime-safe" (
    set "UDPVoiceRepeats=2"
    set "UDPGameRepeats=3"
    set "UDPGameCutoff=n1"
    set "UDPGameFakeLimit=3/s"
    set "UDPVideoRepeats=2"
)
echo:

set "BIN=%~dp0bin\"
set "LISTS=%~dp0lists\"
cd /d %BIN%

start "zapret: %~n0" /min "%BIN%winws.exe" --wf-tcp=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp=443,19294-19344,50000-50100,%GameFilterUDP% --filter-tcp=80,443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt"

call service.bat build_policy_args
if defined POLICY_ARGS (
    start "zapret: policy" /min "%BIN%winws.exe" --wf-tcp=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp=443,19294-19344,50000-50100,%GameFilterUDP% %POLICY_ARGS%
)
