' Opens the Clumsy Sloth without a console window, or closes it when it already runs
' (used by the Start menu shortcut "Clumsy Sloth": one click opens, the next click closes).
Set fso = CreateObject("Scripting.FileSystemObject")
ps1 = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "panel.ps1")
Set running = GetObject("winmgmts:\\.\root\cimv2").ExecQuery( _
  "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'powershell.exe'")
found = False
For Each p In running
  If Not IsNull(p.CommandLine) Then
    If InStr(1, p.CommandLine, ps1, vbTextCompare) > 0 Then p.Terminate : found = True
  End If
Next
If Not found Then
  CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
End If
