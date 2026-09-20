@{
    # run.ps1 calls Connect-ExchangeOnline -ManagedIdentity, which needs
    # ExchangeOnlineManagement 3.x or later. host.json's managedDependency
    # is enabled, so the Function host installs whatever this file pins
    # automatically on cold start - no manual module install on the
    # Function App needed.
    'ExchangeOnlineManagement' = '3.*'
    'az.accounts' = '5.*'
}
