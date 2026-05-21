@echo off
setlocal EnableDelayedExpansion
chcp 65001 > nul
:: 65001 - UTF-8

cd /d "%~dp0"
call service.bat status_zapret
call service.bat check_updates
call service.bat load_game_filter
call service.bat load_user_lists
call service.bat load_realtime_profile
set "PolicyLayerEnabledFile=%~dp0utils\policy.enabled"

set "GameFilterUDPVoice=50000-50100"
set "GameFilterUDPGame=%GameFilterUDP%"
if "%GameFilterUDP%"=="12" (
    set "GameFilterUDPVoice=12"
    set "GameFilterUDPGame=12"
)
set "UDPVoiceRepeats=4"
set "UDPVoiceCutoff=n2"
set "UDPGameRepeats=6"
set "UDPGameCutoff=n2"
set "UDPGameFakeLimit=8/s"
if /I "%RealtimeUDPProfile%"=="realtime-safe" (
    set "UDPVoiceRepeats=2"
    set "UDPGameRepeats=3"
    set "UDPGameCutoff=n1"
    set "UDPGameFakeLimit=3/s"
)
echo:

set "BIN=%~dp0bin\"
set "LISTS=%~dp0lists\"
netsh interface tcp show global | findstr /i "timestamps" | findstr /i "enabled" > nul || (
    echo [WARNING] TCP timestamps are disabled. Enabling...
    netsh interface tcp set global timestamps=enabled > nul 2>&1
)
cd /d %BIN%

:: Check required .bin files exist
for %%F in ("%BIN%quic_initial_www_google_com.bin" "%BIN%quic_initial_dbankcloud_ru.bin" "%BIN%tls_clienthello_www_google_com.bin" "%BIN%tls_clienthello_4pda_to.bin") do (
    if not exist "%%F" (
        echo [ERROR] Required file not found: %%F
        pause
        exit /b 1
    )
)

start "zapret: %~n0" /min "%BIN%winws.exe" --wf-tcp=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp=443,19294-19344,50000-50100,%GameFilterUDP% ^
--filter-udp=443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-autottl --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin" --new ^
--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --dpi-desync=fake --dpi-desync-fake-discord="%BIN%quic_initial_dbankcloud_ru.bin" --dpi-desync-fake-stun="%BIN%quic_initial_dbankcloud_ru.bin" --dpi-desync-repeats=6 --new ^
--filter-tcp=2053,2083,2087,2096,8443 --hostlist-domains=discord.media --dpi-desync=fake,multisplit --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-badseq-increment=10000000 --dpi-desync-split-pos=2,sniext+1 --dpi-desync-split-seqovl=679 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_www_google_com.bin" --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --new ^
--filter-tcp=443 --hostlist="%LISTS%list-google.txt" --ip-id=zero --dpi-desync=fake,multisplit --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-badseq-increment=10000000 --dpi-desync-split-pos=1,midsld --dpi-desync-split-seqovl=681 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_www_google_com.bin" --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --new ^
--filter-tcp=80,443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=multisplit --dpi-desync-split-pos=2,sniext+1 --dpi-desync-split-seqovl=679 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_www_google_com.bin" --new ^
--filter-udp=443 --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-autottl --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin" --new ^
--filter-tcp=80,443,8443 --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=multisplit --dpi-desync-split-seqovl=568 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_4pda_to.bin" --new ^
--filter-tcp=%GameFilterTCP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=multisplit --dpi-desync-any-protocol=1 --dpi-desync-cutoff=n3 --dpi-desync-split-seqovl=568 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_4pda_to.bin" --new ^
--filter-udp=%GameFilterUDPVoice% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=%UDPVoiceRepeats% --dpi-desync-any-protocol=1 --dpi-desync-fake-unknown-udp="%BIN%quic_initial_dbankcloud_ru.bin" --dpi-desync-cutoff=%UDPVoiceCutoff% --new ^
--filter-udp=%GameFilterUDPGame% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=%UDPGameRepeats% --dpi-desync-any-protocol=1 --dpi-desync-fake-unknown-udp="%BIN%quic_initial_dbankcloud_ru.bin" --dpi-desync-fake-udp-limit=%UDPGameFakeLimit% --dpi-desync-cutoff=%UDPGameCutoff%

if exist "%PolicyLayerEnabledFile%" (
    call service.bat build_policy_args
    if defined POLICY_ARGS (
        echo %POLICY_ARGS% | findstr /I /C:"--wf-tcp" /C:"--wf-udp" >nul
        if errorlevel 1 (
            start "zapret: policy" /min "%BIN%winws.exe" %POLICY_ARGS%
        ) else (
            echo [policy-layer] POLICY_ARGS contains --wf-tcp/--wf-udp, policy process skipped. See utils\policy-last.log
        )
    ) else (
        echo [policy-layer] POLICY_ARGS invalid or empty, policy process skipped. See utils\policy-last.log
    )
) else (
    echo [policy-layer] disabled via utils\policy.enabled ^(base strategy only^)
)


echo [INFO] For best results, configure encrypted DNS (DoH/DoT) in your browser or Windows settings.
