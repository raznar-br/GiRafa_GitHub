@echo off
chcp 65001 >nul
cd /d %~dp0
echo ================================================
echo   ATUALIZAR DADOS DO GREENJOY
echo ================================================
echo.

echo [1/3] Vendas (Ecletica) - reprocessando ultimos 30 dias...
set SYNC_LOOKBACK_DAYS=30
python sync_ecletica.py
if errorlevel 1 (echo    ^>^> ERRO nas vendas - ver sync_ecletica.log) else (echo    ^>^> OK)
echo.

echo [2/3] Compras (Everest)...
python importar_everest_compras.py
if errorlevel 1 (echo    ^>^> ERRO nas compras) else (echo    ^>^> OK)
echo.

echo [3/3] DRE (JAFEB)...
python importar_jafeb.py
if errorlevel 1 (echo    ^>^> ERRO no DRE) else (echo    ^>^> OK)
echo.

echo ================================================
echo   Pronto! Abra o dashboard e confira o
echo   card "Status das bases".
echo   (O extrato BTG atualiza sozinho pelo Google.)
echo ================================================
echo.
pause
