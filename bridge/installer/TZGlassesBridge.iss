; Inno Setup script for the TZ Glasses Bridge installer.
; Built by .github/workflows/bridge-installer.yml; to build by hand on Windows:
;   pyinstaller bridge\installer\tz-bridge.spec  (from the repo root, gives dist\tz-bridge)
;   put WinSW-x64.exe at bridge\installer\tz-bridge-service.exe
;   iscc /DAppVersion=0.1.0 bridge\installer\TZGlassesBridge.iss

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#define ServiceExe "tz-bridge-service.exe"

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
UninstallDisplayName=TZ Glasses Bridge
CloseApplications=no
MinVersion=10.0

[Files]
Source: "..\..\dist\tz-bridge\*"; DestDir: "{app}\tz-bridge"; Flags: recursesubdirs ignoreversion
Source: "tz-bridge-service.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "tz-bridge-service.xml"; DestDir: "{app}"; Flags: ignoreversion

[Dirs]
Name: "{commonappdata}\TZ Glasses Bridge"

[INI]
Filename: "{app}\TZ Glasses Bridge.url"; Section: "InternetShortcut"; Key: "URL"; String: "http://localhost:8080/"
Filename: "{app}\TZ Glasses Bridge Settings.url"; Section: "InternetShortcut"; Key: "URL"; String: "http://localhost:8080/settings"

[Icons]
Name: "{group}\TZ Glasses Bridge"; Filename: "{app}\TZ Glasses Bridge.url"
Name: "{group}\TZ Glasses Bridge Settings"; Filename: "{app}\TZ Glasses Bridge Settings.url"
Name: "{group}\Uninstall TZ Glasses Bridge"; Filename: "{uninstallexe}"

[Run]
; Let phones on the boat's WiFi reach the bridge. Boat networks are often marked "Public", so all profiles.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""TZ Glasses Bridge"""; Flags: runhidden; StatusMsg: "Setting up the firewall..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""TZ Glasses Bridge"" dir=in action=allow program=""{app}\tz-bridge\tz-bridge.exe"" enable=yes profile=any"; Flags: runhidden
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
