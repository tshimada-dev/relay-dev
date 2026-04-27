function Get-FakeProviderInvocationSpec {
    param([Parameter(Mandatory)]$JobSpec)

    $spec = ConvertTo-RelayHashtable -InputObject $JobSpec
    $pwshPath = [System.Diagnostics.Process]::GetCurrentProcess().Path
    $stdoutText = [string]$spec["fake_stdout"]
    $stderrText = [string]$spec["fake_stderr"]
    $exitCode = if ($spec["fake_exit_code"]) { [int]$spec["fake_exit_code"] } else { 0 }
    $fakeMode = [string]$spec["fake_mode"]

    if ($fakeMode -eq "failure" -and -not $spec.ContainsKey("fake_exit_code")) {
        $exitCode = 1
    }

    $scriptLines = @()
    if ($fakeMode -eq "echo_prompt") {
        $scriptLines += '[Console]::InputEncoding = [System.Text.Encoding]::UTF8'
        $scriptLines += '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8'
        $scriptLines += '$OutputEncoding = [System.Text.Encoding]::UTF8'
        $scriptLines += '$inputText = [Console]::In.ReadToEnd()'
        $scriptLines += "Write-Output ('PROMPT:' + " + '$inputText.Trim())'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
        $escapedStdout = $stdoutText.Replace("'", "''")
        $scriptLines += "Write-Output '$escapedStdout'"
    }

    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        $escapedStderr = $stderrText.Replace("'", "''")
        $scriptLines += "[Console]::Error.WriteLine('$escapedStderr')"
    }
    $scriptLines += "exit $exitCode"
    $scriptText = $scriptLines -join "; "

    return [ordered]@{
        provider = "fake-provider"
        command = $pwshPath
        arguments = "-NoProfile -Command `"$scriptText`""
    }
}
