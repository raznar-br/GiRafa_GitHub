@echo off
cd /d %~dp0
"C:\Users\Usuario\AppData\Local\Programs\Python\Python312\python.exe" sync_ecletica.py
if errorlevel 1 (
    echo ERRO no sync - ver sync_ecletica.log
    exit /b 1
)
"C:\Users\Usuario\AppData\Local\Programs\Python\Python312\python.exe" placar_premio.py --enviar >> placar_premio.log 2>&1
