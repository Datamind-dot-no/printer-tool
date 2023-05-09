# printer-tool
script for maintenance on macOS CUPS print queues, fetch settings from AD  using LDAP

Uses logged-in users Kerberos SSO credentials to query AD for printer settings

Logged-in user is added to _lpadmin user group so they can administrate printer queues