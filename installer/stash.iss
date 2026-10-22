; Stash Stable Windows installer
; IMPORTANT: DO NOT CHANGE APPID AFTER FIRST RELEASE.
; Reusing this AppId lets future installers upgrade the existing installation.

#ifndef StableBundleDir
  #define StableBundleDir "..\dist\stable"
#endif

#ifndef InstallerOutputDir
  #define InstallerOutputDir "..\dist\installer"
#endif

#ifndef InstallerBaseName
  #define InstallerBaseName "StashSetup-0.6.0-alpha"
#endif

[Setup]
; IMPORTANT: DO NOT CHANGE APPID AFTER FIRST RELEASE.
AppId={{5886F905-BBB2-4623-9FA4-FFD70EA29AAE}
AppName=Stash
AppVersion=0.6.0 Alpha
AppVerName=Stash 0.6.0 Alpha
AppPublisher=Stash Project
VersionInfoVersion=0.6.0.2
DefaultDirName={localappdata}\Programs\Stash
DefaultGroupName=Stash
DisableDirPage=no
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#InstallerOutputDir}
OutputBaseFilename={#InstallerBaseName}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\stash.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
CloseApplicationsFilter=stash.exe
RestartApplications=no
RestartIfNeededByRun=no
SetupLogging=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[InstallDelete]
; Remove replaceable program artifacts from older versions without touching AppData.
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\*.dll"
Type: files; Name: "{app}\stash.exe"
Type: files; Name: "{app}\BUILD_INFO.txt"

[Files]
; The full Stable Flutter bundle is packaged recursively. Dev is never an input.
Source: "{#StableBundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Stash"; Filename: "{app}\stash.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Stash"; Filename: "{app}\stash.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\stash.exe"; Description: "Launch Stash"; Flags: nowait postinstall skipifsilent
