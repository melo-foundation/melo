; Inno Setup script for melo — LZMA2/max compression installer.
; Built in CI: iscc /O<outdir> scripts/melo.iss (dist/ prepared by the deploy step)
[Setup]
AppName=melo
AppVersion=0.1.0
AppPublisher=melo
DefaultDirName={autopf}\melo
DisableProgramGroupPage=yes
Compression=lzma2/max
SolidCompression=yes
OutputBaseFilename=melo-setup
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\melo.exe
; GPL-3.0 s4/s5: the licence is conveyed with the work. The installer showed
; none, and no file in dist\ carried one either.
LicenseFile=..\LICENSE

[Files]
Source: "..\dist\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\melo"; Filename: "{app}\melo.exe"
Name: "{autodesktop}\melo"; Filename: "{app}\melo.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; Flags: unchecked

[Run]
Filename: "{app}\melo.exe"; Description: "Launch melo"; Flags: nowait postinstall skipifsilent
