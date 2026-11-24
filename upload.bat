@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
cd /d "%~dp0"

call :need git Git.Git "C:\Program Files\Git\cmd"
call :need gh GitHub.cli "C:\Program Files\GitHub CLI"
gh auth status >nul 2>&1
if errorlevel 1 gh auth login
gh auth setup-git >nul 2>&1

if not exist .repo_url (
  set /p URL=GitHubリポジトリのURLを入れて: 
  >.repo_url echo !URL!
)
set /p URL=<.repo_url
if "%URL%"=="" (
  echo URLが空。.repo_url を消してもう一回
  pause
  exit /b 1
)

if not exist .gitignore (
  >.gitignore echo .repo_url
  >>.gitignore echo downloads/
  >>.gitignore echo build_error.txt
)

rem .git が無ければ作る。有ればそのまま使う
if not exist .git git init -b main
git config user.name >nul 2>&1 || git config user.name "vros"
git config user.email >nul 2>&1 || git config user.email "vros@users.noreply.github.com"
git remote get-url origin >nul 2>&1
if errorlevel 1 (
  git remote add origin "%URL%"
) else (
  git remote set-url origin "%URL%"
)
git branch -M main

git add -A
git commit -m "upload %date% %time%" >nul 2>&1

echo アップロード中...
git push -u origin main
if errorlevel 1 (
  echo.
  echo pushに失敗。リモートに別の履歴がある可能性がある
  choice /c YN /m "上書きしてpushする"
  if errorlevel 2 (
    pause
    exit /b 1
  )
  git push -u origin main --force
  if errorlevel 1 (
    echo pushに失敗
    pause
    exit /b 1
  )
)

for /f %%i in ('git rev-parse HEAD') do set SHA=%%i
echo ビルド開始を待ってる...
set /a N=0
:findrun
set RID=
for /f %%i in ('gh run list --commit %SHA% --limit 1 --json databaseId --jq ".[0].databaseId // empty" 2^>nul') do set RID=%%i
if defined RID goto found
set /a N+=1
if %N% geq 30 goto nofound
timeout /t 3 /nobreak >nul
goto findrun

:nofound
echo ビルドが見つからない。GitHubのActionsタブを見て
pause
exit /b 1

:found
echo ビルド中 run %RID%
gh run watch %RID% --exit-status
if errorlevel 1 goto failed

echo.
echo ダウンロード中...
if exist downloads rmdir /s /q downloads
gh run download %RID% -D downloads
if errorlevel 1 (
  echo ダウンロードに失敗
  pause
  exit /b 1
)
echo.
echo 完了。downloads フォルダに ipa と exe がある
explorer downloads
pause
exit /b 0

:failed
echo.
echo ビルド失敗。ログを build_error.txt に保存した。中身をClaudeに貼って
gh run view %RID% --log-failed > build_error.txt 2>&1
if exist downloads rmdir /s /q downloads
gh run download %RID% -D downloads >nul 2>&1
start notepad build_error.txt
pause
exit /b 1

:need
where %1 >nul 2>&1 && exit /b 0
echo %1 が無いので入れる...
winget install -e --id %2 --accept-package-agreements --accept-source-agreements
set "PATH=%PATH%;%~3"
where %1 >nul 2>&1 && exit /b 0
echo %1 が使えない。ターミナルを開き直してもう一回
pause
exit
