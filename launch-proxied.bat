@echo off
REM ZCode 抓包发射器：代理+CA 注入启动，配合 mitmdump 捕获官方请求
set HTTPS_PROXY=http://127.0.0.1:8888
set HTTP_PROXY=http://127.0.0.1:8888
set NODE_EXTRA_CA_CERTS=%USERPROFILE%\.mitmproxy\mitmproxy-ca-cert.pem
set NO_PROXY=localhost,127.0.0.1
start "" "C:\Program Files\ZCode\ZCode.exe"
echo ZCode 已带代理启动。发一条消息后回 ZCode 汇报。
