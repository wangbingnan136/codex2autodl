property appDisplayName : "codex-ssh-remote"
property defaultAliasName : "autodl-codex"
property defaultApiPort : "8080"
property fallbackRepoDir : "/Users/Zhuanz/Documents/codex2autodl"
property setupScriptRelativePath : "/scripts/setup-autodl-codex.sh"

on run
  try
    set repoDir to my resolveRepoDir()
    set setupScript to repoDir & setupScriptRelativePath

    set aliasName to text returned of (display dialog "Connection alias" default answer defaultAliasName buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel")
    set aliasName to my trimText(aliasName)
    if aliasName is "" then error "Connection alias cannot be empty."

    set pastedLogin to text returned of (display dialog "Paste SSH command, optionally followed by password" default answer "ssh -p 24937 root@connect.westd.seetacloud.com" buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel")
    set parsedLogin to my parseLoginInput(pastedLogin)
    set sshCommand to item 1 of parsedLogin
    set autoPassword to item 2 of parsedLogin

    if sshCommand does not start with "ssh " then
      error "The SSH command must start with: ssh"
    end if

    if autoPassword is "" then
      set autoPassword to text returned of (display dialog "SSH password" default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel")
    end if
    if autoPassword is "" then error "SSH password cannot be empty."

    set apiPort to text returned of (display dialog "Local codex2api port" default answer defaultApiPort buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel")
    set apiPort to my trimText(apiPort)
    if apiPort is "" then set apiPort to defaultApiPort

    set apiKey to text returned of (display dialog "codex2api API key. Leave empty to reuse existing remote Codex login." default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel")

    set diagnoseChoice to button returned of (display dialog "Run setup now?" buttons {"Cancel", "Setup Only", "Setup + Diagnose"} default button "Setup + Diagnose" cancel button "Cancel")
    set shouldDiagnose to diagnoseChoice is "Setup + Diagnose"

    set sshPasswordFile to my writeSecretFile(autoPassword)
    set apiKeyFile to ""
    if apiKey is not "" then set apiKeyFile to my writeSecretFile(apiKey)
    set terminalCommand to my buildTerminalCommand(repoDir, setupScript, aliasName, apiPort, apiKeyFile, shouldDiagnose, sshCommand, sshPasswordFile)

    tell application "Terminal"
      activate
      do script terminalCommand
    end tell
  on error errMsg number errNum
    if errNum is not -128 then
      display alert appDisplayName & " failed" message errMsg as warning
    end if
  end try
end run

on resolveRepoDir()
  set candidateDirs to {}

  try
    set appPath to POSIX path of (path to me)
    set guessedRepoDir to do shell script "cd " & quoted form of (appPath & "/../..") & " 2>/dev/null && pwd -P"
    set end of candidateDirs to guessedRepoDir
  end try

  set end of candidateDirs to fallbackRepoDir

  repeat with candidateDir in candidateDirs
    set candidateText to candidateDir as text
    if my setupScriptExists(candidateText) then return candidateText
  end repeat

  set chosenFolder to choose folder with prompt "Choose the codex2autodl repository folder"
  set chosenRepoDir to POSIX path of chosenFolder
  if chosenRepoDir ends with "/" then set chosenRepoDir to text 1 thru -2 of chosenRepoDir
  if my setupScriptExists(chosenRepoDir) then return chosenRepoDir

  error "Could not find executable setup script: scripts/setup-autodl-codex.sh"
end resolveRepoDir

on setupScriptExists(repoDir)
  try
    do shell script "test -x " & quoted form of (repoDir & setupScriptRelativePath)
    return true
  on error
    return false
  end try
end setupScriptExists

on parseLoginInput(rawText)
  set cleanedText to my trimText(rawText)
  if cleanedText is "" then error "SSH login input cannot be empty."

  set lineItems to my nonEmptyLines(cleanedText)
  if (count of lineItems) > 1 then
    return {item 1 of lineItems, item 2 of lineItems}
  end if

  set tokens to my splitWords(cleanedText)
  if (count of tokens) < 2 then return {cleanedText, ""}
  if item 1 of tokens is not "ssh" then return {cleanedText, ""}

  set hostIndex to 0
  set i to 2
  repeat while i <= (count of tokens)
    set tokenValue to item i of tokens
    if tokenValue is "-p" or tokenValue is "-l" or tokenValue is "-o" or tokenValue is "-i" or tokenValue is "-J" then
      set i to i + 2
    else if tokenValue starts with "-p" and (length of tokenValue) > 2 then
      set i to i + 1
    else if tokenValue starts with "-" then
      set i to i + 1
    else
      set hostIndex to i
      exit repeat
    end if
  end repeat

  if hostIndex is 0 then return {cleanedText, ""}

  set sshTokens to items 1 thru hostIndex of tokens
  set passwordTokens to {}
  if hostIndex < (count of tokens) then
    set passwordTokens to items (hostIndex + 1) thru (count of tokens) of tokens
  end if

  return {my joinTokens(sshTokens), my joinTokens(passwordTokens)}
end parseLoginInput

on writeSecretFile(secretValue)
  set inputFile to do shell script "mktemp /tmp/codex2autodl-app-input.XXXXXX"
  set fileRef to open for access (POSIX file inputFile) with write permission
  try
    set eof fileRef to 0
    write (secretValue & linefeed) to fileRef as «class utf8»
    close access fileRef
  on error errMsg number errNum
    try
      close access fileRef
    end try
    try
      do shell script "rm -f " & quoted form of inputFile
    end try
    error errMsg number errNum
  end try

  do shell script "chmod 600 " & quoted form of inputFile
  return inputFile
end writeSecretFile

on buildTerminalCommand(repoDir, setupScript, aliasName, apiPort, apiKeyFile, shouldDiagnose, sshCommand, sshPasswordFile)
  set setupCommand to quoted form of setupScript
  set setupCommand to setupCommand & " --alias " & quoted form of aliasName
  set setupCommand to setupCommand & " --ssh-password-file \"$ssh_password_file\""
  set setupCommand to setupCommand & " --local-api-port " & quoted form of apiPort
  if apiKeyFile is not "" then set setupCommand to setupCommand & " --api-key-file \"$api_key_file\""
  if shouldDiagnose then set setupCommand to setupCommand & " --diagnose"
  set setupCommand to setupCommand & " " & quoted form of sshCommand

  set terminalCommand to "set -o pipefail; "
  set terminalCommand to terminalCommand & "ssh_password_file=" & quoted form of sshPasswordFile & "; "
  if apiKeyFile is not "" then
    set terminalCommand to terminalCommand & "api_key_file=" & quoted form of apiKeyFile & "; "
  else
    set terminalCommand to terminalCommand & "api_key_file=''; "
  end if
  set terminalCommand to terminalCommand & "trap 'rm -f \"$ssh_password_file\" \"$api_key_file\"' EXIT INT TERM; "
  set terminalCommand to terminalCommand & "cd " & quoted form of repoDir & " || exit 1; "
  set terminalCommand to terminalCommand & "echo 'codex-ssh-remote'; "
  set terminalCommand to terminalCommand & "echo 'Alias: " & my shellSingleQuoteSafe(aliasName) & "'; "
  set terminalCommand to terminalCommand & "echo 'SSH: " & my shellSingleQuoteSafe(sshCommand) & "'; "
  set terminalCommand to terminalCommand & setupCommand & "; "
  set terminalCommand to terminalCommand & "codex2autodl_status=$?; rm -f \"$ssh_password_file\" \"$api_key_file\"; trap - EXIT INT TERM; echo; "
  set terminalCommand to terminalCommand & "if [ \"$codex2autodl_status\" -eq 0 ]; then echo 'Done. You can now select this SSH host in Codex App.'; else echo \"Failed with exit code $codex2autodl_status\"; fi; "
  set terminalCommand to terminalCommand & "echo; echo 'Window left open for logs.'"
  return terminalCommand
end buildTerminalCommand

on splitWords(rawText)
  set oldDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to {" ", tab}
  set rawItems to text items of rawText
  set AppleScript's text item delimiters to oldDelimiters

  set cleanItems to {}
  repeat with rawItem in rawItems
    set itemText to my trimText(rawItem as text)
    if itemText is not "" then set end of cleanItems to itemText
  end repeat
  return cleanItems
end splitWords

on nonEmptyLines(rawText)
  set oldDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to {return, linefeed}
  set rawLines to text items of rawText
  set AppleScript's text item delimiters to oldDelimiters

  set cleanLines to {}
  repeat with rawLine in rawLines
    set lineText to my trimText(rawLine as text)
    if lineText is not "" then set end of cleanLines to lineText
  end repeat
  return cleanLines
end nonEmptyLines

on joinTokens(tokenList)
  if tokenList is {} then return ""
  set oldDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to " "
  set joinedText to tokenList as text
  set AppleScript's text item delimiters to oldDelimiters
  return joinedText
end joinTokens

on trimText(rawText)
  set textValue to rawText as text
  repeat while textValue starts with " " or textValue starts with tab or textValue starts with return or textValue starts with linefeed
    if (length of textValue) is 1 then return ""
    set textValue to text 2 thru -1 of textValue
  end repeat
  repeat while textValue ends with " " or textValue ends with tab or textValue ends with return or textValue ends with linefeed
    if (length of textValue) is 1 then return ""
    set textValue to text 1 thru -2 of textValue
  end repeat
  return textValue
end trimText

on shellSingleQuoteSafe(rawText)
  return do shell script "printf %s " & quoted form of rawText & " | sed " & quoted form of "s/'/'\\\\''/g"
end shellSingleQuoteSafe
