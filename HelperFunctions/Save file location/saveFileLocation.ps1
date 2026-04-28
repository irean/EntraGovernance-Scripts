
  #save file location
  Add-Type -AssemblyName System.Windows.Forms
  $FileBrowser = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{ 
      InitialDirectory = [Environment]::GetFolderPath('Desktop') 
  }
  if ($FileBrowser.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
      Write-Host "No folder selected"
      return
  }
  $folder = $FileBrowser.SelectedPath