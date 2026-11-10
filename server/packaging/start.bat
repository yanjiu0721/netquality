@echo off
cd /d "%~dp0"
echo 正在启动网络质量探测节点。端口和口令请改同目录下的 .env
netquality-reflector.exe
echo.
echo 程序已退出。如果上面有报错，请检查 .env 后重新双击本文件。
pause
