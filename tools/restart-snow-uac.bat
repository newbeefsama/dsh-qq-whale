@echo off
REM 由 explorer 以「中完整性」启动本 bat，再由它去请求 UAC。
REM
REM 为什么绕这一圈：如果从一个「已经提权」的进程里执行
REM   Start-Process -Verb RunAs
REM Windows 不会再弹 UAC，而是直接继承当前的高完整性令牌。
REM 实测那个令牌下 SnowLuma 的注入器扫不到 QQ（/api/processes 返回空），
REM 只有 consent.exe 现场创建的新令牌才能注入。
REM
REM 所以必须：中权限进程 -> 请求提权 -> consent.exe 出新令牌 -> 能 hook。
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process PowerShell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0snow-elevated.ps1' -Verb RunAs"
