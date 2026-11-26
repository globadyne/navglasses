; Inno Setup script for the TZ Glasses Bridge installer.
; Built by .github/workflows/bridge-installer.yml; to build by hand on Windows:
;   pyinstaller bridge\installer\tz-bridge.spec  (from the repo root, gives dist\tz-bridge)
;   put WinSW-x64.exe at bridge\installer\tz-bridge-service.exe
;   iscc /DAppVersion=0.1.0 bridge\installer\TZGlassesBridge.iss

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#define ServiceExe "tz-bridge-service.exe"
; com0com's signed installer, fetched by the build (see bridge-installer.yml). Without it the
; installer is built without the Virtual COM ports option.
#define Com0com AddBackslash(SourcePath) + "com0com-setup.exe"
#if FileExists(Com0com)
  #define HaveCom0com
#endif

[Setup]
AppId={{6E4C2F0A-8B1D-4C55-9E3A-2B7D9A1C4E60}
AppName=TZ Glasses Bridge
AppVersion={#AppVersion}
AppPublisher=TZ Glasses
DefaultDirName={autopf}\TZ Glasses Bridge
DefaultGroupName=TZ Glasses Bridge
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist
OutputBaseFilename=TZ-Glasses-Bridge-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Branding: the same mark as the bridge's web pages. 100% and 200% sizes for high-DPI screens.
SetupIconFile=tz-bridge.ico
WizardImageFile=wizard-100.bmp,wizard-200.bmp
WizardSmallImageFile=small-100.bmp,small-200.bmp
UninstallDisplayIcon={app}\tz-bridge.ico
UninstallDisplayName=TZ Glasses Bridge
CloseApplications=no
MinVersion=10.0

[Messages]
WelcomeLabel1=Set up the TZ Glasses Bridge
WelcomeLabel2=The bridge runs quietly in the background on this nav PC. It reads the boat's NMEA data and TimeZero's marks, routes and tracks, and passes them to the TZ Glasses app on the phone over the boat's WiFi.%n%nIt starts by itself with Windows. TimeZero's files are only ever read, never changed.
FinishedHeadingLabel=The bridge is running
FinishedLabel=Next, open the bridge settings and add where the boat's data comes from (a COM port, TCP or UDP). Then type the address shown on the bridge's Status page into the phone app.%n%nYou can reopen both from the Start menu under TZ Glasses Bridge.

#ifdef HaveCom0com
[Tasks]
Name: "vcom"; Description: "Virtual COM ports (com0com), to link the bridge and TimeZero on this PC"; Check: not Com0comInstalled
#endif

[Files]
Source: "..\..\dist\tz-bridge\*"; DestDir: "{app}\tz-bridge"; Flags: recursesubdirs ignoreversion
Source: "tz-bridge-service.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "tz-bridge-service.xml"; DestDir: "{app}"; Flags: ignoreversion
Source: "tz-bridge.ico"; DestDir: "{app}"; Flags: ignoreversion
#ifdef HaveCom0com
Source: "com0com-setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall; Tasks: vcom
Source: "com0com-NOTICE.txt"; DestDir: "{app}"; Flags: ignoreversion; Tasks: vcom
#endif
Source: "trust-com0com.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Dirs]
Name: "{commonappdata}\TZ Glasses Bridge"

[INI]
Filename: "{app}\TZ Glasses Bridge.url"; Section: "InternetShortcut"; Key: "URL"; String: "http://localhost:8080/"
Filename: "{app}\TZ Glasses Bridge.url"; Section: "InternetShortcut"; Key: "IconFile"; String: "{app}\tz-bridge.ico"
Filename: "{app}\TZ Glasses Bridge.url"; Section: "InternetShortcut"; Key: "IconIndex"; String: "0"
Filename: "{app}\TZ Glasses Bridge Settings.url"; Section: "InternetShortcut"; Key: "URL"; String: "http://localhost:8080/settings"
Filename: "{app}\TZ Glasses Bridge Settings.url"; Section: "InternetShortcut"; Key: "IconFile"; String: "{app}\tz-bridge.ico"
Filename: "{app}\TZ Glasses Bridge Settings.url"; Section: "InternetShortcut"; Key: "IconIndex"; String: "0"

[Icons]
Name: "{group}\TZ Glasses Bridge"; Filename: "{app}\TZ Glasses Bridge.url"; IconFilename: "{app}\tz-bridge.ico"
Name: "{group}\TZ Glasses Bridge Settings"; Filename: "{app}\TZ Glasses Bridge Settings.url"; IconFilename: "{app}\tz-bridge.ico"
Name: "{group}\Uninstall TZ Glasses Bridge"; Filename: "{uninstallexe}"

[Run]
; Let phones on the boat's WiFi reach the bridge. Boat networks are often marked "Public", so all profiles.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""TZ Glasses Bridge"""; Flags: runhidden; StatusMsg: "Setting up the firewall..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""TZ Glasses Bridge"" dir=in action=allow program=""{app}\tz-bridge\tz-bridge.exe"" enable=yes profile=any"; Flags: runhidden
#ifdef HaveCom0com
Filename: "{tmp}\com0com-setup.exe"; Parameters: "/S"; Tasks: vcom; Flags: waituntilterminated; StatusMsg: "Installing virtual COM ports (com0com)..."
#endif
; Whenever com0com is here (just installed, or installed by hand before), trust its driver publisher so
; the bridge service can make pairs without a prompt it couldn't show.
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\trust-com0com.ps1"""; Flags: runhidden waituntilterminated; Check: Com0comInstalled; StatusMsg: "Setting up virtual COM ports..."
Filename: "{app}\{#ServiceExe}"; Parameters: "install"; Flags: runhidden; StatusMsg: "Installing the service..."
Filename: "{app}\{#ServiceExe}"; Parameters: "start"; Flags: runhidden; StatusMsg: "Starting the bridge..."
Filename: "http://localhost:8080/settings"; Description: "Open the bridge settings"; Flags: postinstall shellexec nowait skipifsilent

[UninstallRun]
Filename: "{app}\{#ServiceExe}"; Parameters: "stop"; Flags: runhidden; RunOnceId: "StopService"
Filename: "{app}\{#ServiceExe}"; Parameters: "uninstall"; Flags: runhidden; RunOnceId: "RemoveService"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""TZ Glasses Bridge"""; Flags: runhidden; RunOnceId: "RemoveFirewall"

[UninstallDelete]
Type: files; Name: "{app}\TZ Glasses Bridge.url"
Type: files; Name: "{app}\TZ Glasses Bridge Settings.url"

[Code]
// com0com already on this PC (installed earlier, by us or by hand): don't offer it again.
function Com0comInstalled: Boolean;
begin
  Result := FileExists(ExpandConstant('{commonpf32}\com0com\setupc.exe')) or
            FileExists(ExpandConstant('{commonpf64}\com0com\setupc.exe'));
end;

// On an upgrade, stop and remove the old service first so its files can be replaced.
// Settings in C:\ProgramData\TZ Glasses Bridge are kept.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
  OldService: String;
begin
  Result := '';
  OldService := ExpandConstant('{app}\{#ServiceExe}');
  if FileExists(OldService) then
  begin
    Exec(OldService, 'stop', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec(OldService, 'uninstall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Sleep(1500);
  end;
end;
