@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Scripts are meant to be run interactively and print a summary.
        'PSAvoidUsingWriteHost'
    )
}
